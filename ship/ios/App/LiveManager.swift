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
    /// Each countdown's own token, by countdown id, so the right one can be sent again.
    private var tokens = [String: String]()
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
                let token = hex(data)
                self.lock.lock()
                self.tokens[activity.id] = token
                self.lock.unlock()
                await self.post(path: "/api/live/token", body: ["device": self.deviceToken ?? "", "key": key, "token": token])
            }
        }
    }

    /// One countdown at a time: the block that started last. Anything long over goes.
    func tidy() {
        let now = Date().timeIntervalSince1970
        // Newest block first. If the app and the server both put up the same block, one stays.
        let all = Activity<SederAttributes>.activities.sorted { $0.content.state.startAt > $1.content.state.startAt }
        guard let keep = all.first else { return }
        var ended = false
        for activity in all.dropFirst() {
            ended = true
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        if keep.content.state.endAt < now - 600 {
            Task { await keep.end(nil, dismissalPolicy: .immediate) }
            return
        }
        if ended {
            // The server must hold the token of the one that stayed.
            lock.lock()
            let token = tokens[keep.id]
            lock.unlock()
            if let token = token {
                let key = keep.attributes.key
                Task { await self.post(path: "/api/live/token", body: ["device": self.deviceToken ?? "", "key": key, "token": token]) }
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
        let now = Date().timeIntervalSince1970
        guard endAt > now + 20 else { return }
        // In a block's first minute the server is about to put the countdown up itself: let it.
        if startToken != nil && now - startAt < 50 && now >= startAt { return }
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
