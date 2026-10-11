import UIKit
import UserNotifications
import WebKit
import Network

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
///                { action: "openSettings" }                  this app's page in iOS Settings, on
///                                                            its Notifications switches (2026-10-05)
///   shell → JS   sa-notify-permission   detail "granted" | "denied" | "default"
///                sa-notify-token        detail the APNs device token, lowercase hex
///                sa-notify-click        detail { url }: the deep link of a tapped notification
///
/// The shell says what it can do before the page's first script runs: `window.__saShell.notify` is 2
/// in a build that has openSettings (WebView.swift), absent in one that does not. It also reports the
/// permission each time the app comes to the foreground (SceneDelegate), so a switch turned on in
/// Settings reaches the page without anyone asking.
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
        case "openSettings":
            openSettings()
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

    /// "Open Settings": once someone has answered the system prompt with Don't Allow, iOS never shows
    /// it again — the switch lives in Settings → Scroll Anytime → Notifications, and this opens
    /// exactly that page.
    static func openSettings() {
        DispatchQueue.main.async {
            guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
            UIApplication.shared.open(url)
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

/// THE POWER BRIDGE (B-013 of the full inspection, 2026-10-08): iOS tells the page about Low Power
/// Mode, thermal pressure and memory warnings — the web platform exposes none of the three — as one
/// event the Rabbis page's living wall reads (app/src/screens/wall/living.ts):
///   shell → JS   sa:pressure   detail { pressure: "lowpower" | "thermal" | "memory" | null }
/// Low Power keeps the wall as portraits, thermal pressure caps the previews at two, a memory
/// warning at one with the off-screen clips released. `window.__saPressure` carries the same value
/// for a wall created between two events. Posted at start, on every foreground, after the page's
/// first paint, and whenever iOS changes its mind.
enum PowerBridge {
    private static var started = false
    private static var memoryWarningUntil: Date = .distantPast

    static func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in post() }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in post() }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            memoryWarningUntil = Date().addingTimeInterval(60)
            post()
        }
        post()
    }

    /// what the page should know right now
    static func current() -> String? {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return "lowpower" }
        if Date() < memoryWarningUntil { return "memory" }
        switch info.thermalState {
        case .serious, .critical: return "thermal"
        default: return nil
        }
    }

    static func post() {
        DispatchQueue.main.async {
            let value = current().map { "\"\($0)\"" } ?? "null"
            PWAShell.webView?.evaluateJavaScript("window.__saPressure = \(value); window.dispatchEvent(new CustomEvent('sa:pressure', { detail: { pressure: \(value) } }))", completionHandler: nil)
        }
    }
}

/// REPORT A PROBLEM (2026-10-10, the owner's spec Part 3) — what a report needs from the phone itself,
/// and nothing it does not (app/src/lib/report.ts is the other side of this contract):
///
///   at document start   window.__saShell gains { shake: 1, model, os, version, network }: the model
///                       ("iPhone16,1"), "iOS 18.6", this build ("1.1.0 (33)") and the network
///                       ("wifi" | "cellular" | "wired" | "offline" | "other", "(low data)" when iOS
///                       says so) — kept current as the path changes and on every page start
///   JS → shell          `snap` { width, quality }: a picture of the screen as it is now, taken
///                       before the report sheet comes up
///   shell → JS          snap-result  { ok, data: "data:image/jpeg;base64,…" }
///                       sa-shake     a shake, anywhere: the page decides (on by default for the
///                                    curators, off for everyone else, a switch in Profile)
/// Nothing is sent from here: the page shows the person what goes with the report and sends it.
enum ReportBridge {
    private static let monitor = NWPathMonitor()
    private static var started = false
    private(set) static var network = "unknown"

    static func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let kind: String
            if path.status != .satisfied { kind = "offline" }
            else if path.usesInterfaceType(.wifi) { kind = "wifi" }
            else if path.usesInterfaceType(.cellular) { kind = "cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { kind = "wired" }
            else { kind = "other" }
            let label = kind + (path.isConstrained ? " (low data)" : "")
            DispatchQueue.main.async {
                network = label
                postNetwork()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.scrollanytime.network"))
    }

    static func postNetwork() {
        let value = jsonString(network)
        PWAShell.webView?.evaluateJavaScript("window.__saShell = Object.assign(window.__saShell || {}, { network: \(value) })", completionHandler: nil)
    }

    /// "iPhone16,1"; in the Simulator, the model it stands in for
    static var model: String {
        var u = utsname()
        uname(&u)
        let machine = withUnsafePointer(to: &u.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        if machine == "x86_64" || machine == "arm64", let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return sim + " (Simulator)"
        }
        return machine
    }

    static var os: String { "iOS " + UIDevice.current.systemVersion }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// the fields the page reads, as a JavaScript object literal (JSON, so nothing needs escaping)
    static func shellFields() -> String {
        let fields: [String: Any] = ["shake": 1, "model": model, "os": os, "version": version, "network": network]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private static func jsonString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return json
    }

    /// `snap`: the window as it is on screen, `width` pixels wide, a JPEG — the web view and anything
    /// native over it, drawn from what the screen shows rather than re-rendered
    static func snapshot(_ message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        let width = CGFloat(min(1080, max(240, (body?["width"] as? Double) ?? 720)))
        let quality = CGFloat(min(0.9, max(0.3, (body?["quality"] as? Double) ?? 0.6)))
        DispatchQueue.main.async {
            guard let web = PWAShell.webView, let target = web.window ?? Optional(web) as UIView? else {
                NotifyBridge.emit("snap-result", ["ok": false])
                return
            }
            let size = target.bounds.size
            guard size.width > 0, size.height > 0 else {
                NotifyBridge.emit("snap-result", ["ok": false])
                return
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = min(UIScreen.main.scale, width / size.width)
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                _ = target.drawHierarchy(in: target.bounds, afterScreenUpdates: false)
            }
            guard let jpeg = image.jpegData(compressionQuality: quality) else {
                NotifyBridge.emit("snap-result", ["ok": false])
                return
            }
            NotifyBridge.emit("snap-result", ["ok": true, "data": "data:image/jpeg;base64," + jpeg.base64EncodedString()])
        }
    }

    /// a shake anywhere in the app
    static func shook() {
        NotifyBridge.emit("sa-shake", [String: Any]())
        if selfTest { NSLog("SA-SELFTEST shake: the shell emitted sa-shake") }
    }

    // ── THE SELF-TEST (2026-10-10) ──────────────────────────────────────────────────────────────
    // Dormant unless the app is launched with the argument -saSelfTest, which only a developer's
    // `xcrun simctl launch … -saSelfTest` can pass (an App Store install never receives launch
    // arguments). The Simulator walk (ship/demo/walk-signin.sh) uses it to prove this bridge inside
    // the real web view against whatever page the shell loads: it reads __saShell, asks `snap` for a
    // picture, keeps the JPEG in the app's tmp folder for the walk to pull, and reports a shake the
    // page heard. Every line goes to the unified log as "SA-SELFTEST …".
    static var selfTest: Bool { ProcessInfo.processInfo.arguments.contains("-saSelfTest") }

    static func runSelfTest() {
        guard selfTest, let web = PWAShell.webView else { return }
        let script = """
        const fields = window.__saShell || {};
        const snap = await new Promise((resolve) => {
          const t = setTimeout(() => resolve({ ok: false, error: 'timeout' }), 6000);
          window.addEventListener('snap-result', (e) => { clearTimeout(t); resolve(e.detail || { ok: false }); }, { once: true });
          window.webkit.messageHandlers.snap.postMessage({ width: 720, quality: 0.6 });
        });
        window.addEventListener('sa-shake', () => window.webkit.messageHandlers.sa.postMessage('selftest-shake'));
        return JSON.stringify({ fields, snap: { ok: !!snap.ok, data: snap.data || null } });
        """
        web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                guard let text = value as? String, let data = text.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    NSLog("SA-SELFTEST result unreadable")
                    return
                }
                let fields = obj["fields"] as? [String: Any] ?? [:]
                let shown = fields.filter { $0.key != "deviceId" }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
                NSLog("SA-SELFTEST fields: %@", shown)
                let snap = obj["snap"] as? [String: Any] ?? [:]
                if let url = snap["data"] as? String, let comma = url.firstIndex(of: ","),
                   let jpeg = Data(base64Encoded: String(url[url.index(after: comma)...])) {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("sa-selftest-snap.jpg")
                    try? jpeg.write(to: file)
                    let size = UIImage(data: jpeg).map { "\(Int($0.size.width * $0.scale))x\(Int($0.size.height * $0.scale))" } ?? "?"
                    NSLog("SA-SELFTEST snap: ok %ld bytes %@ -> %@", jpeg.count, size, file.path)
                } else {
                    NSLog("SA-SELFTEST snap: FAILED %@", String(describing: snap))
                }
            case .failure(let error):
                NSLog("SA-SELFTEST script failed: %@", error.localizedDescription)
            }
        }
    }
}
