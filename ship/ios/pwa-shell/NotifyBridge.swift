import UIKit
import UserNotifications
import WebKit

/// THE NOTIFY BRIDGE (2026-09-25) — the web app's `notify` message handler, and the three events
/// it dispatches back (app/src/lib/nativeNotify.ts is the other side of this contract):
///
///   JS → shell   { action: "getPermissionState" }
///                { action: "requestPermission" }             the system prompt, once ever; on a
///                                                            grant the shell registers with APNs
///                { action: "replacePlan", items: [...] }     the next seven days of local
///                                                            notifications, replacing ours
///                { action: "cancelAll" }
///                { action: "registerForPush" }
///                { action: "test", seconds, title, body, url }
///   shell → JS   sa-notify-permission   detail "granted" | "denied" | "default"
///                sa-notify-token        detail the APNs device token, lowercase hex
///                sa-notify-click        detail { url }: the deep link of a tapped notification
///
/// Local notifications are ours by identifier prefix, so replacing the plan never touches
/// anything else. A tap that launches the app cold arrives before the page exists; it is kept
/// and delivered when the page posts "painted" (ViewController → flushPending).
enum NotifyBridge {
    static let idPrefix = "sa-"
    private static var pendingClickUrl: String?

    static func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "getPermissionState":
            permissionState()
        case "requestPermission":
            requestPermission()
        case "replacePlan":
            replacePlan(body["items"] as? [[String: Any]] ?? [])
        case "cancelAll":
            cancelAll()
        case "registerForPush":
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        case "test":
            test(seconds: body["seconds"] as? Double ?? 5,
                 title: body["title"] as? String ?? "Scroll Anytime",
                 text: body["body"] as? String ?? "",
                 url: body["url"] as? String ?? "/")
        default:
            break
        }
    }

    // MARK: events to the page

    static func emit(_ event: String, _ detail: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: detail, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            PWAShell.webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('\(event)', { detail: \(json) }))", completionHandler: nil)
        }
    }

    static func deviceToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        emit("sa-notify-token", hex)
    }

    /// A tapped notification: to the page now, or kept until the page is up.
    static func clicked(userInfo: [AnyHashable: Any]) {
        let url = (userInfo["url"] as? String) ?? "/"
        DispatchQueue.main.async {
            if let web = PWAShell.webView, !web.isLoading, web.url != nil {
                emit("sa-notify-click", ["url": url])
            } else {
                pendingClickUrl = url
            }
        }
    }

    static func flushPending() {
        if let url = pendingClickUrl {
            pendingClickUrl = nil
            emit("sa-notify-click", ["url": url])
        }
    }

    // MARK: permission

    private static func stateName(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .authorized, .provisional, .ephemeral: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "default"
        @unknown default: return "default"
        }
    }

    static func permissionState() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            emit("sa-notify-permission", stateName(settings.authorizationStatus))
        }
    }

    static func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                    emit("sa-notify-permission", granted ? "granted" : "denied")
                    if granted {
                        DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
                    }
                }
            case .denied:
                emit("sa-notify-permission", "denied")
            default:
                emit("sa-notify-permission", "granted")
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            }
        }
    }

    // MARK: local notifications

    private static func content(title: String, text: String, url: String) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = text
        c.sound = .default
        c.threadIdentifier = "scroll-anytime"
        c.userInfo = ["url": url, "sa": true]
        return c
    }

    static func replacePlan(_ items: [[String: Any]]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let ours = pending.map { $0.identifier }.filter { $0.hasPrefix(idPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            let now = Date()
            for item in items {
                guard let id = item["id"] as? String, let fireAt = item["fireAt"] as? Double else { continue }
                let date = Date(timeIntervalSince1970: fireAt / 1000)
                if date <= now { continue }
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let c = content(title: item["title"] as? String ?? "Scroll Anytime",
                                text: item["body"] as? String ?? "",
                                url: item["url"] as? String ?? "/")
                center.add(UNNotificationRequest(identifier: idPrefix + id, content: c, trigger: trigger), withCompletionHandler: nil)
            }
        }
    }

    static func cancelAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let ours = pending.map { $0.identifier }.filter { $0.hasPrefix(idPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }
    }

    static func test(seconds: Double, title: String, text: String, url: String) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let req = UNNotificationRequest(identifier: idPrefix + "test", content: content(title: title, text: text, url: url), trigger: trigger)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
