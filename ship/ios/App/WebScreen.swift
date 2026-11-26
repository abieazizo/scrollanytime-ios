import SwiftUI
import UIKit
import UserNotifications
import WebKit

private let home = URL(string: "https://seder.abieazizo.workers.dev/?app=ios")!
private let paper = UIColor(red: 0.961, green: 0.973, blue: 1.0, alpha: 1)

/// The web app, and the bridge it uses to reach the phone:
///   window.webkit.messageHandlers.seder.postMessage({ t: ... })   web → app
///   window.__sederNative({ t: ... })                              app → web
struct WebScreen: UIViewRepresentable {
    func makeCoordinator() -> Bridge { Bridge() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // App-bound: the site's service worker runs here, so the app opens with no connection.
        config.limitsNavigationsToAppBoundDomains = true
        config.allowsInlineMediaPlayback = true
        config.userContentController.add(context.coordinator, name: "seder")

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = paper
        web.scrollView.backgroundColor = paper
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.allowsBackForwardNavigationGestures = false
        web.allowsLinkPreview = false
        context.coordinator.attach(web)
        web.load(URLRequest(url: home))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private weak var web: WKWebView?
    private var loaded = false
    private var pendingScreen: String?

    func attach(_ web: WKWebView) {
        self.web = web
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(tokensChanged), name: .sederTokens, object: nil)
        center.addObserver(self, selector: #selector(openScreen(_:)), name: .sederOpen, object: nil)
        center.addObserver(self, selector: #selector(cameForward), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: app → web

    private func send(_ payload: [String: Any]) {
        guard loaded, let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            self.web?.evaluateJavaScript("window.__sederNative && window.__sederNative(\(json))", completionHandler: nil)
        }
    }

    @objc private func tokensChanged() { sendTokens() }

    @objc private func cameForward() {
        LiveManager.shared.tidy()
        send(["t": "active"])
    }

    @objc private func openScreen(_ note: Notification) {
        guard let screen = note.object as? String else { return }
        if loaded { send(["t": "open", "screen": screen]) } else { pendingScreen = screen }
    }

    private func sendTokens() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let live = LiveManager.shared
            var payload: [String: Any] = [
                "t": "tokens",
                "granted": settings.authorizationStatus == .authorized,
                "denied": settings.authorizationStatus == .denied,
                "live": live.allowed,
                "env": (Bundle.main.object(forInfoDictionaryKey: "SederPushEnv") as? String) ?? "development",
            ]
            if let device = live.deviceToken { payload["device"] = device }
            if let start = live.startToken { payload["start"] = start }
            self.send(payload)
        }
    }

    // MARK: web → app

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["t"] as? String else { return }
        switch type {
        case "enable":
            // Asked from a tap in Settings: the phone shows its "allow notifications" question once.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async {
                    if granted { UIApplication.shared.registerForRemoteNotifications() }
                    self.sendTokens()
                }
            }
        case "tokens":
            sendTokens()
        case "live":
            if let b = body["block"] as? [String: Any],
               let key = b["key"] as? String, let title = b["title"] as? String,
               let startAt = (b["startAt"] as? NSNumber)?.doubleValue, let endAt = (b["endAt"] as? NSNumber)?.doubleValue {
                LiveManager.shared.show(key: key, title: title, sub: b["sub"] as? String, startAt: startAt, endAt: endAt, next: b["next"] as? String)
            } else {
                LiveManager.shared.clear()
            }
        case "share":
            if let name = body["name"] as? String, let text = body["text"] as? String { share(name: name, text: text) }
        default:
            break
        }
    }

    /// Saving a backup: a web view cannot download a file, so the app hands it to the share sheet.
    private func share(name: String, text: String) {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        do { try text.write(to: file, atomically: true, encoding: .utf8) } catch { return }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        guard let web = web, let host = web.window?.rootViewController else { return }
        sheet.popoverPresentationController?.sourceView = web
        host.present(sheet, animated: true)
    }

    // MARK: loading

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        sendTokens()
        if let screen = pendingScreen {
            pendingScreen = nil
            send(["t": "open", "screen": screen])
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        retry(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        retry(webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        webView.load(URLRequest(url: home))
    }

    /// The very first launch with no connection: keep trying quietly.
    private func retry(_ webView: WKWebView) {
        guard !loaded else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if !self.loaded { webView.load(URLRequest(url: home)) }
        }
    }

    /// Anything that is not the app itself opens in Safari.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        let inApp = url.host == home.host || scheme == "about" || scheme == "blob" || scheme == "data"
        if inApp || navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
        } else {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { UIApplication.shared.open(url) }
        return nil
    }
}
