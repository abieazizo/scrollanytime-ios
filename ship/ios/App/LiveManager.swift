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

    private func adopt(_ activity: Activity<SederAttributes>, keep: Bool = false) {
        lock.lock()
        let fresh = watching.insert(activity.id).inserted
        lock.unlock()
        tidy(keeping: keep ? activity.id : nil)
        guard fresh else { return }
        let key = activity.attributes.key
        note("adopt \(key) state=\(activity.activityState) all=\(Activity<SederAttributes>.activities.count)")
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

    /// One countdown at a time: the running block that started last. Finished ones go.
    func tidy(keeping: String? = nil) {
        let now = Date().timeIntervalSince1970
        let all = Activity<SederAttributes>.activities
        let running = all
            .filter { $0.activityState == .active && $0.content.state.endAt > now - 30 }
            .sorted { $0.content.state.startAt > $1.content.state.startAt }
        let keepId = keeping ?? running.first?.id
        var ended = 0
        for activity in all where activity.id != keepId {
            ended += 1
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        guard ended > 0, let keep = all.first(where: { $0.id == keepId }) else { return }
        // The server must hold the token of the one that stayed.
        lock.lock()
        let token = tokens[keep.id]
        lock.unlock()
        if let token = token {
            let key = keep.attributes.key
            Task { await self.post(path: "/api/live/token", body: ["device": self.deviceToken ?? "", "key": key, "token": token]) }
        }
    }

    /// A line for the server's notes, so a problem on the phone can be seen from outside.
    func note(_ text: String) {
        Task { await self.post(path: "/api/live/note", body: ["device": self.deviceToken ?? "", "note": text]) }
    }

    /// The app is open and says which block is running now (or none).
    func show(key: String, title: String, sub: String?, startAt: Double, endAt: Double, next: String?) {
        guard allowed else { note("show \(key): live activities are off"); return }
        let state = SederAttributes.ContentState(title: title, sub: sub, startAt: startAt, endAt: endAt, next: next)
        let stale = Date(timeIntervalSince1970: endAt)
        let all = Activity<SederAttributes>.activities
        for other in all where other.attributes.key != key || other.activityState != .active {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
        if let have = all.first(where: { $0.attributes.key == key && $0.activityState == .active }) {
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
            adopt(activity, keep: true)
            note("show \(key): started")
        } catch {
            note("show \(key): failed: \(error)")
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
