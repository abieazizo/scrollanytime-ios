import ActivityKit
import Foundation
import UIKit

extension Notification.Name {
    /// A push token changed: the web app should hear about it.
    static let sederTokens = Notification.Name("sederTokens")
    /// An alert was tapped: the web app should go to a screen.
    static let sederOpen = Notification.Name("sederOpen")
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// Keeps the Lock Screen countdown in step: the tokens the server needs to start one,
/// one countdown at a time, and no countdown left over from an earlier block.
final class LiveManager {
    static let shared = LiveManager()
    static let server = URL(string: "https://seder.abieazizo.workers.dev")!

    private let defaults = UserDefaults.standard
    private var watching = Set<String>()
    private let lock = NSLock()

    /// The token for ordinary alerts.
    var deviceToken: String? {
        get { defaults.string(forKey: "apnsDevice") }
        set { defaults.set(newValue, forKey: "apnsDevice") }
    }

    /// The token that lets the server start a countdown while the app is closed.
    var startToken: String? {
        get { defaults.string(forKey: "liveStart") }
        set { defaults.set(newValue, forKey: "liveStart") }
    }

    var allowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func begin() {
        if let data = Activity<SederAttributes>.pushToStartToken {
            saveStart(hex(data))
        }
        Task {
            for await data in Activity<SederAttributes>.pushToStartTokenUpdates {
                self.saveStart(hex(data))
            }
        }
        Task {
            // The server started one while the app was closed: the phone wakes the app for it.
            for await activity in Activity<SederAttributes>.activityUpdates {
                self.adopt(activity)
            }
        }
        for activity in Activity<SederAttributes>.activities {
            adopt(activity)
        }
    }

    private func saveStart(_ token: String) {
        guard token != startToken else { return }
        startToken = token
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .sederTokens, object: nil)
        }
    }

    private func adopt(_ activity: Activity<SederAttributes>) {
        lock.lock()
        let fresh = watching.insert(activity.id).inserted
        lock.unlock()
        tidy()
        guard fresh else { return }
        let key = activity.attributes.key
        Task {
            // With this token the server can take the countdown down when the block ends.
            for await data in activity.pushTokenUpdates {
                await self.post(path: "/api/live/token", body: ["device": self.deviceToken ?? "", "key": key, "token": hex(data)])
            }
        }
    }

    /// One countdown at a time: the block that started last. Anything long over goes.
    func tidy() {
        let all = Activity<SederAttributes>.activities
        let now = Date().timeIntervalSince1970
        let newest = all.map { $0.content.state.startAt }.max() ?? 0
        for activity in all {
            let s = activity.content.state
            if s.startAt < newest || s.endAt < now - 600 {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }

    /// The app is open and says which block is running now (or none).
    func show(key: String, title: String, sub: String?, startAt: Double, endAt: Double, next: String?) {
        guard allowed else { return }
        let state = SederAttributes.ContentState(title: title, sub: sub, startAt: startAt, endAt: endAt, next: next)
        let stale = Date(timeIntervalSince1970: endAt)
        let all = Activity<SederAttributes>.activities
        for other in all where other.attributes.key != key {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
        if let have = all.first(where: { $0.attributes.key == key }) {
            if have.content.state != state {
                Task { await have.update(ActivityContent(state: state, staleDate: stale)) }
            }
            return
        }
        guard endAt > Date().timeIntervalSince1970 + 20 else { return }
        do {
            let activity = try Activity.request(
                attributes: SederAttributes(key: key),
                content: ActivityContent(state: state, staleDate: stale),
                pushType: .token
            )
            adopt(activity)
        } catch {
            print("[seder] could not start the countdown: \(error.localizedDescription)")
        }
    }

    /// No block is running (or it was just marked): take every countdown down.
    func clear() {
        for activity in Activity<SederAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func post(path: String, body: [String: Any]) async {
        guard let url = URL(string: path, relativeTo: LiveManager.server),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        req.timeoutInterval = 20
        _ = try? await URLSession.shared.data(for: req)
    }
}
