import UIKit
import WebKit
import AVFoundation
import Network

var webView: WKWebView! = nil

/// THE FIRST OPEN'S NETWORK (incident 2026-11-02). Whether the phone has a usable path at all, known from
/// launch — the offline page may show only when it has none (see didFailProvisionalNavigation). Started in
/// viewDidLoad, before the first navigation; `unknown` until NWPathMonitor answers (a few milliseconds),
/// and unknown never counts as offline.
enum FirstOpenNet {
    private static let monitor = NWPathMonitor()
    private static var started = false
    private(set) static var status: NWPath.Status? = nil
    /// called on the main queue when a path appears after there was none
    static var onSatisfied: (() -> Void)?

    static func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                let was = status
                status = path.status
                if path.status == .satisfied && was != .satisfied { onSatisfied?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.scrollanytime.firstopen"))
    }

    /// true only when iOS says there is no path — never on "not known yet"
    static var offline: Bool { status != nil && status != .satisfied }
}

class ViewController: UIViewController, WKNavigationDelegate, UIDocumentInteractionControllerDelegate {
    enum LoadingMode {
        case defaultCachePolicy
        case forceCache
    }

    var documentController: UIDocumentInteractionController?
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        return self
    }
    
    @IBOutlet weak var loadingView: UIView!
    @IBOutlet weak var launchIconView: UIImageView!
    @IBOutlet weak var progressView: UIProgressView!
    @IBOutlet weak var connectionProblemView: UIImageView!
    @IBOutlet weak var webviewView: UIView!
    var toolbarView: UIToolbar!

    // THE LOADING PAGE. The loading view is the launch storyboard's still — the closed, unlit
    // scroll — so that the page's frame zero replaces it invisibly. That still is right for the
    // half-second a good connection takes. It is wrong for the thirty seconds a bad one can take:
    // the owner's phone sat on the closed scroll and it read as frozen (2026-09-15). So after
    // SLOW_AFTER seconds with no page, the still becomes the film's own lit state — the open,
    // glowing scroll with the name (LaunchArt) and a moving hairline — and when the page finally
    // paints, it joins at that lit state (html.sa-late) and the native art crossfades into it.
    // 0.8 s: a cached page paints frame zero in well under that, so a normal launch never sees
    // the lit page; a page still on its way lights up before the still can read as frozen.
    private let SLOW_AFTER: TimeInterval = 0.8
    private var loadingArt: UIImageView?
    private var slowTimer: Timer?
    private var loadingPageShown = false
    
    var htmlIsLoaded = false;
    // PART 3.1: has the app EVER completed a navigation on this launch? A reviewer opening the
    // build cold in airplane mode has not, and that is the case the bundled fallback exists for.
    var hasEverLoaded = false;
    var showingOfflineFallback = false;
    /// the first navigation's failures in a row on this launch, and the last one's error (incident 2026-11-02)
    private var firstOpenFailures = 0
    private var firstOpenLastError = ""
    private var firstOpenRetry: DispatchWorkItem?
    /// The page the web view last COMMITTED to. A navigation that fails provisionally leaves this
    /// page on screen, whole and working — so when it is ours, a failed extra navigation is no
    /// reason to tear the app down (see didFailProvisionalNavigation).
    private var lastCommittedURL: URL?
    private var loadingMode = LoadingMode.defaultCachePolicy
    
    private var themeObservation: NSKeyValueObservation?
    var currentWebViewTheme: UIUserInterfaceStyle = .unspecified
    override var preferredStatusBarStyle : UIStatusBarStyle {
        if #available(iOS 13, *), overrideStatusBar{
            if #available(iOS 15, *) {
                return .default
            } else {
                return statusBarTheme == "dark" ? .lightContent : .darkContent
            }
        }
        return .default
    }

    // A SHAKE, ANYWHERE (2026-10-10): the page decides whether it opens Report a problem (on by default
    // for the curators, a switch in Profile for everyone). The controller takes first responder so a
    // shake reaches it even before anything in the page was touched; a shake while the page has focus
    // climbs the responder chain to here.
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { ReportBridge.shook() }
        super.motionEnded(motion, with: event)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        initWebView()
        initToolbarView()
        // the path is known before the first navigation can fail; a path that comes back while the
        // offline page is up takes the person in without a tap (the page's own 'online' listener is a
        // synthetic document's and is not to be trusted)
        FirstOpenNet.onSatisfied = { [weak self] in
            guard let self = self, self.showingOfflineFallback, !self.hasEverLoaded else { return }
            self.retryFirstOpen(after: 0.3)
        }
        FirstOpenNet.start()
        loadRootUrl()
    
        NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification , object: nil)
        // CARPLAY, CALLS, SIRI (2026-09-28): the page is told what the audio session is doing, so
        // a clip resumes when iOS says "resume" and stops when the car or the headphones go away.
        // WebKit owns the session (it sets the playback category when a clip plays); the shell only
        // listens and never activates anything of its own — that would cut off the viewer's music
        // the moment the app opened.
        let audio = AVAudioSession.sharedInstance()
        NotificationCenter.default.addObserver(self, selector: #selector(self.audioInterruption(_:)), name: AVAudioSession.interruptionNotification, object: audio)
        NotificationCenter.default.addObserver(self, selector: #selector(self.audioRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: audio)
    }

    @objc func audioInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            emitAudio(["kind": "interruption", "phase": "began"])
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            emitAudio(["kind": "interruption", "phase": "ended", "resume": opts.contains(.shouldResume)])
        @unknown default:
            return
        }
    }

    @objc func audioRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            emitAudio(["kind": "route", "reason": "gone"])
        case .newDeviceAvailable:
            emitAudio(["kind": "route", "reason": "new"])
        default:
            return
        }
    }

    /// `sa-audio` on the page (FeedController.onNativeAudio). JSON-built, main thread, never before
    /// there is a web view to hear it.
    private func emitAudio(_ detail: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            PWAShell.webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('sa-audio', { detail: \(json) }))", completionHandler: nil)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        PWAShell.webView.frame = calcWebviewFrame(webviewView: webviewView, toolbarView: nil)
    }
    
    @objc func keyboardWillHide(_ notification: NSNotification) {
        PWAShell.webView.setNeedsLayout()
    }
    
    func initWebView() {
        PWAShell.webView = createWebView(container: webviewView, WKSMH: self, WKND: self, NSO: self, VC: self)
        // Directly BELOW the loading view and nothing else: the page paints frame zero (the very
        // still the loading view shows) underneath, posts "painted", and the loading view lifts to
        // reveal it. (Build 25 put the web view under an extra ground-coloured wrapper, so lifting
        // the loading view showed that wrapper forever — the page was never seen.)
        webviewView.insertSubview(PWAShell.webView, belowSubview: loadingView);
        
        PWAShell.webView.uiDelegate = self;
        
        PWAShell.webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)

        if(pullToRefresh){
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(self, action: #selector(refreshWebView(_:)), for: UIControl.Event.valueChanged)
            PWAShell.webView.scrollView.addSubview(refreshControl)
            PWAShell.webView.scrollView.bounces = true
        }

        if #available(iOS 15.0, *), adaptiveUIStyle {
            themeObservation = PWAShell.webView.observe(\.themeColor) { [unowned self] webView, _ in
                let backgroundColor = PWAShell.webView.underPageBackgroundColor;
                let themeColor = PWAShell.webView.themeColor;
                currentWebViewTheme = themeColor?.isLight() ?? backgroundColor?.isLight() ?? true ? .light : .dark
                self.overrideUIStyle()
                view.backgroundColor = themeColor ?? backgroundColor;
            }
        }
    }

    @objc func refreshWebView(_ sender: UIRefreshControl) {
        PWAShell.webView?.reload()
        sender.endRefreshing()
    }

    func createToolbarView() -> UIToolbar{
        // never a force cast: connectedScenes is a Set, and not every scene is a window scene
        let windowScene = webviewView.window?.windowScene
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        var statusBarHeight = windowScene?.statusBarManager?.statusBarFrame.height ?? 60
        
        #if targetEnvironment(macCatalyst)
        if (statusBarHeight == 0){
            statusBarHeight = 30
        }
        #endif
        
        let toolbarView = UIToolbar(frame: CGRect(x: 0, y: 0, width: webviewView.frame.width, height: 0))
        toolbarView.sizeToFit()
        toolbarView.frame = CGRect(x: 0, y: 0, width: webviewView.frame.width, height: toolbarView.frame.height + statusBarHeight)
//        toolbarView.autoresizingMask = [.flexibleTopMargin, .flexibleRightMargin, .flexibleWidth]
        
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let close = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(loadRootUrl))
        toolbarView.setItems([close,flex], animated: true)
        
        toolbarView.isHidden = true
        
        return toolbarView
    }
    
    func overrideUIStyle(toDefault: Bool = false) {
        if #available(iOS 15.0, *), adaptiveUIStyle {
            if (((htmlIsLoaded && !PWAShell.webView.isHidden) || toDefault) && self.currentWebViewTheme != .unspecified) {
                UIApplication
                    .shared
                    .connectedScenes
                    .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
                    .first { $0.isKeyWindow }?.overrideUserInterfaceStyle = toDefault ? .unspecified : self.currentWebViewTheme;
            }
        }
    }
    
    func initToolbarView() {
        toolbarView =  createToolbarView()
        
        webviewView.addSubview(toolbarView)
    }
    
    @objc func loadRootUrl(cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy) {
        // under its XCUITest only (-saUITestWipeWebData): the whole web data store goes first — storage and
        // cookies, as an evicted store would — and the page loads after (SaveToPhotos.swift UITestHooks)
        if UITestHooks.wipeWebDataOnce({ [weak self] in self?.loadRootUrl(cachePolicy: cachePolicy) }) { return }
        armLoadingPage()
        PWAShell.webView.load(URLRequest(url: SceneDelegate.universalLinkToLaunch ?? SceneDelegate.shortcutLinkToLaunch ?? UITestHooks.startURL ?? rootUrl, cachePolicy: cachePolicy))
    }

    /// The first navigation failed with a path, or before two retries: try it again behind the loading
    /// still (its 0.8 s light-up and the breathing hairline are the "quiet retry"), never the offline page.
    func retryFirstOpen(after delay: TimeInterval) {
        firstOpenRetry?.cancel()
        htmlIsLoaded = false
        if showingOfflineFallback {
            showingOfflineFallback = false
        }
        resetLoadingPage()
        loadingView.isHidden = false
        animateConnectionProblem(false)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.hasEverLoaded else { return }
            self.loadRootUrl()
        }
        firstOpenRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// "Still connecting…" under the loading art while the first open keeps retrying with a path (2026-11-02):
    /// never a question, nothing to tap; it goes when the page paints or the offline page takes over
    private var stillConnecting: UILabel?
    func showStillConnecting() {
        guard stillConnecting == nil, let host = loadingView else { return }
        UITestHooks.gateNote("still-connecting", ["failures": firstOpenFailures])
        let l = UILabel()
        l.text = "Still connecting…"
        l.textColor = UIColor(red: 0.961, green: 0.949, blue: 0.918, alpha: 0.72)
        l.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        l.adjustsFontForContentSizeCategory = true
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        l.alpha = 0
        host.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            l.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -72),
        ])
        stillConnecting = l
        UIView.animate(withDuration: 0.4) { l.alpha = 1 }
    }
    func hideStillConnecting() {
        stillConnecting?.removeFromSuperview()
        stillConnecting = nil
    }

    // MARK: - the loading page

    /// A load is starting: give the page SLOW_AFTER seconds to paint before the still lights up.
    func armLoadingPage() {
        slowTimer?.invalidate()
        slowTimer = Timer.scheduledTimer(withTimeInterval: SLOW_AFTER, repeats: false) { [weak self] _ in
            self?.showLoadingPage()
        }
    }

    /// The closed scroll lights up into the film's held state: LaunchArt (the open scroll, its
    /// bloom, the name) placed so its scroll sits exactly where the closed one is, and the
    /// hairline below it, alive.
    func showLoadingPage() {
        guard !loadingPageShown, !loadingView.isHidden, let icon = launchIconView else { return }
        loadingPageShown = true
        let art = UIImageView(image: UIImage(named: "LaunchArt"))
        art.contentMode = .scaleAspectFit
        art.isUserInteractionEnabled = false
        // LaunchArt is 320x360pt with the scroll's centre at (160, 151.7): line that centre up
        // with the closed scroll's centre
        let c = icon.center
        art.bounds = CGRect(x: 0, y: 0, width: 320, height: 360)
        art.center = CGPoint(x: c.x, y: c.y + (180.0 - 151.7))
        art.alpha = 0
        loadingView.insertSubview(art, aboveSubview: icon)
        loadingArt = art
        progressView.isHidden = false
        progressView.alpha = 0
        if progressView.progress < 0.08 { progressView.setProgress(0.08, animated: false) }
        UIView.animate(withDuration: 0.45, delay: 0, options: [.curveEaseOut], animations: {
            art.alpha = 1
            icon.alpha = 0
            self.progressView.alpha = 1
        }, completion: { _ in
            // the hairline breathes while the bytes come, so a stalled percentage never looks dead
            UIView.animate(withDuration: 0.9, delay: 0, options: [.repeat, .autoreverse, .curveEaseInOut, .allowUserInteraction], animations: {
                self.progressView.alpha = 0.45
            })
        })
    }

    /// Back to the plain still, instantly (a reveal is about to happen, or a retry restarts).
    func resetLoadingPage() {
        slowTimer?.invalidate()
        slowTimer = nil
        loadingPageShown = false
        loadingArt?.removeFromSuperview()
        loadingArt = nil
        launchIconView?.alpha = 1
        progressView.layer.removeAllAnimations()
        progressView.alpha = 1
        progressView.isHidden = true
        loadingView.alpha = 1
    }
    
    func reloadWebview(
        loadingMode: LoadingMode = LoadingMode.defaultCachePolicy
    ) {
        switch loadingMode {
        case LoadingMode.defaultCachePolicy:
            loadRootUrl(cachePolicy: .useProtocolCachePolicy);

        case LoadingMode.forceCache:
            loadRootUrl(cachePolicy: .useProtocolCachePolicy);
        }

        self.loadingMode = loadingMode
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!){
        htmlIsLoaded = true
        // Only a real page counts. Finishing the fallback itself must not mark the app as loaded,
        // or a second failure would fall through to the grey WKWebView error page.
        if !showingOfflineFallback { hasEverLoaded = true }
        
        self.setProgress(1.0, true)
        self.animateConnectionProblem(false)

        // The page normally lifted the loading view itself already (the "painted" message, at its
        // first paint). This is the fallback for a page that never posts — the bundled offline
        // page, or a document whose script failed — 0.1s after load, not the template's 0.8s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.revealWeb()
            self.overrideUIStyle()
        }
    }

    // THE HANDOFF. The loading view and the page's frame zero are the same still image (ground,
    // closed scroll at 40% of the safe area), so lifting the loading view over a painted page is
    // invisible. What is NOT invisible is lifting it late: the film's first act runs behind it.
    func revealWeb() {
        PWAShell.webView.isHidden = false
        slowTimer?.invalidate()
        slowTimer = nil
        if loadingPageShown && !loadingView.isHidden {
            // The page JOINS the lit state rather than starting its own introduction over: the
            // viewer has already watched the scroll light up natively, and a second unlit scroll,
            // a second lighting and a second writing of the name read as three launches (the
            // owner, 2026-09-15). `sa-join` puts the film straight into its held state — scroll
            // open and lit, the name written, the hairline drawn — and the native art crossfades
            // into that same still.
            PWAShell.webView.evaluateJavaScript("document.documentElement.classList.add('sa-late','sa-join');window.__saJoin&&window.__saJoin();", completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut], animations: {
                    self.loadingView.alpha = 0
                }, completion: { _ in
                    self.loadingView.isHidden = true
                    self.resetLoadingPage()
                })
            }
        } else {
            self.loadingView.isHidden = true
            resetLoadingPage()
        }
        self.setProgress(0.0, false)
        self.animateConnectionProblem(false)
    }
    
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        lastCommittedURL = webView.url
    }

    // THE WEB CONTENT PROCESS DIED — memory pressure (a long video session; CarPlay drawing the
    // car's screen on the same phone) or a WebKit crash. WKWebView does not recover by itself: the
    // view stays blank until the app is force-quit, which is exactly "the app fails". Reload the
    // page it was on (its route survives: the Worker serves the app for any path), behind the
    // loading still, and let the page's "painted" lift it as on any launch.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        UITestHooks.gateNote("webcontent-died", ["url": webView.url?.absoluteString ?? ""])
        htmlIsLoaded = false
        let wasOurs = lastCommittedURL?.host.map { allowedOrigins.contains($0.lowercased()) } ?? false
        let resumeAt = webView.url
        lastCommittedURL = nil // nothing is on screen any more: a failure now is a real one
        resetLoadingPage()
        loadingView.isHidden = false
        webView.isHidden = false
        if wasOurs, let url = resumeAt, let host = url.host?.lowercased(), allowedOrigins.contains(host) {
            armLoadingPage()
            // AND THE PAGE IS TOLD IT WAS THIS, not left to guess (ExitBridge, 2026-10-26)
            webView.load(URLRequest(url: ExitBridge.mark(url)))
        } else {
            loadRootUrl()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError)._code == (-999) { return }

        // A navigation that fails before it commits leaves the page it started from on screen,
        // whole and working. When that page is OURS and on show, the failure was an extra step on
        // top of the app — a provider page, a host outside WKAppBoundDomains, a link that could not
        // load — and the app stays exactly as it is. This used to hide the web view and reload the
        // root for ANY failure after the first load: the viewer's place gone and the launch film
        // again, for a failure that had nothing to do with the app ("when one signs in with Google
        // and goes back to sign in with something else the app fails" — the owner, 2026-09-28).
        if hasEverLoaded, loadingView.isHidden, !webView.isHidden,
           let host = lastCommittedURL?.host?.lowercased(), allowedOrigins.contains(host) {
            return
        }
        htmlIsLoaded = false;

        // PART 3.1 — THE FIRST-OPEN FALLBACK.
        //
        // On a cold launch with no network there is no service worker and no cache yet, so there is
        // nothing for WKWebView to show: it renders its own grey "cannot open page", or white. That
        // is an automatic rejection (2.1, and 4.2 "it's just a web page that doesn't work"), and it
        // is the FIRST thing an App Store reviewer does.
        //
        // Only for the first navigation. Once the app has loaded once, the web app's own offline
        // screen and its cached clips take over, and the retry loop below is the right behaviour.
        //
        // THE OFFLINE RULE (incident 2026-11-02: phones WITH signal were shown this page). It used to come
        // up on the FIRST failure of the first navigation — no retry, no look at the network — so one
        // dropped request on a cellular hand-off, a TLS hiccup or a timeout read as "needs a connection".
        // Now it shows only when iOS says there is NO network path AND two retries have failed
        // (shared/src/bootRetry.ts is the web app's copy of the same rule). Anything else is retried
        // quietly behind the loading still — 0.9 s, 2.2 s, then a back-off that settles at 30 s — and the
        // page is told what happened once it is up (`__saShell.firstOpen`), so the boot can report it.
        if !hasEverLoaded {
            let ns = error as NSError
            firstOpenFailures += 1
            firstOpenLastError = "\(ns.domain) \(ns.code)"
            if FirstOpenNet.offline && firstOpenFailures > 2 {
                hideStillConnecting()
                showingOfflineFallback = true
                resetLoadingPage()
                loadingView.isHidden = true
                animateConnectionProblem(false)
                webView.isHidden = false
                UITestHooks.gateNote("wall-shell", ["error": firstOpenLastError, "failures": firstOpenFailures])
                webView.loadHTMLString(offlineFallbackHTML, baseURL: rootUrl)
                return
            }
            // capped at 10 s: a path that is blocked rather than missing has nothing to wake the retry, and
            // the Simulator's 30-second outage was answered 16 s late at a 20 s step (2026-11-02, leg C30)
            let waits: [TimeInterval] = [0.9, 2.2, 5, 10]
            retryFirstOpen(after: waits[min(firstOpenFailures - 1, waits.count - 1)])
            // a path and still no answer (our origin, not the phone): from the third failure, about eight
            // seconds in, one quiet line under the art says so — the web launch's own words (splash.markSlow)
            if firstOpenFailures >= 3 { showStillConnecting() }
            return
        }

        self.overrideUIStyle(toDefault: true);
        webView.isHidden = true;
        resetLoadingPage()
        loadingView.isHidden = false;

        if loadingMode == LoadingMode.defaultCachePolicy {
            DispatchQueue.main.async {
                self.reloadWebview(loadingMode: LoadingMode.forceCache)
            }
        } else {
            animateConnectionProblem(true);
            setProgress(0.05, true);
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.setProgress(0.1, true);
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.reloadWebview()
                }
            }
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {

        if (keyPath == #keyPath(WKWebView.estimatedProgress) &&
                PWAShell.webView.isLoading &&
                !self.loadingView.isHidden &&
                !self.htmlIsLoaded) {
                    var progress = Float(PWAShell.webView.estimatedProgress);
                    
                    if (progress >= 0.8) { progress = 1.0; };
                    if (progress >= 0.3) { self.animateConnectionProblem(false); }
                    
                    self.setProgress(progress, true);
        }
    }
    
    func setProgress(_ progress: Float, _ animated: Bool) {
        self.progressView.setProgress(progress, animated: animated);
    }
    
    
    func animateConnectionProblem(_ show: Bool) {
        if (show) {
            self.connectionProblemView.isHidden = false;
            self.connectionProblemView.alpha = 0
            UIView.animate(withDuration: 0.7, delay: 0, options: [.repeat, .autoreverse], animations: {
                self.connectionProblemView.alpha = 1
            })
        }
        else {
            UIView.animate(withDuration: 0.3, delay: 0, options: [], animations: {
                self.connectionProblemView.alpha = 0 // Here you will get the animation you want
            }, completion: { _ in
                self.connectionProblemView.isHidden = true;
                self.connectionProblemView.layer.removeAllAnimations();
            })
        }
    }
        
    deinit {
        PWAShell.webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }
}

extension UIColor {
    // Check if the color is light or dark, as defined by the injected lightness threshold.
    // Some people report that 0.7 is best. I suggest to find out for yourself.
    // A nil value is returned if the lightness couldn't be determined.
    func isLight(threshold: Float = 0.5) -> Bool? {
        let originalCGColor = self.cgColor

        // Now we need to convert it to the RGB colorspace. UIColor.white / UIColor.black are greyscale and not RGB.
        // If you don't do this then you will crash when accessing components index 2 below when evaluating greyscale colors.
        let RGBCGColor = originalCGColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)
        guard let components = RGBCGColor?.components else {
            return nil
        }
        guard components.count >= 3 else {
            return nil
        }

        let brightness = Float(((components[0] * 299) + (components[1] * 587) + (components[2] * 114)) / 1000)
        return (brightness > threshold)
    }
}

extension ViewController: WKScriptMessageHandler {
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "print" {
            printView(webView: PWAShell.webView)
        }
        if message.name == "push-subscribe" {
            handleSubscribeTouch(message: message)
        }
        if message.name == "push-permission-request" {
            handlePushPermission()
        }
        if message.name == "push-permission-state" {
            handlePushState()
        }
        if message.name == "push-token" {
            handleFCMToken()
        }
        if message.name == "sa" {
            // "painted": frame zero is on screen under the loading view — lift it now. Only the
            // real app posts this (the bundled offline page has no script), so it is also the one
            // sure sign that a real page is up: after a Retry from the offline page, this is what
            // takes the shell out of first-open mode.
            if (message.body as? String) == "selftest-shake" {
                if ReportBridge.selfTest { NSLog("SA-SELFTEST shake: the page heard sa-shake") }
            }
            // the XCUITest's record of what the page said (dormant without -saUITest)
            if let said = message.body as? String, said.hasPrefix("uitest-saw:") {
                UITestHooks.saw(String(said.dropFirst("uitest-saw:".count)))
            }
            // the release gate's record of what the page did (dormant without -saGate)
            if let said = message.body as? String, said.hasPrefix("gate:") {
                UITestHooks.gateEvent(String(said.dropFirst("gate:".count)))
            }
            if (message.body as? String) == "painted" {
                // the page exists: tell it about Low Power Mode, heat and memory (B-013)
                PowerBridge.start()
                PowerBridge.post()
                // …and the network as it is now: the document-start value was the one at launch
                ReportBridge.postNetwork()
                // …and whether VoiceOver is running (the feed never settles its interface under it)
                ReportBridge.postVoiceOver()
                // the Simulator walk's proof of the report bridge (dormant without -saSelfTest)
                if ReportBridge.selfTest {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { ReportBridge.runSelfTest() }
                }
                showingOfflineFallback = false
                hasEverLoaded = true
                firstOpenRetry?.cancel()
                hideStillConnecting()
                // what the first open went through before this page could paint, for the boot's report
                // (App.tsx reportReady reads __saShell.firstOpen): 0 failures is the normal launch
                let firstOpen = "{ failures: \(firstOpenFailures), error: \(ReportBridge.jsonString(firstOpenLastError)) }"
                PWAShell.webView.evaluateJavaScript("window.__saShell = Object.assign(window.__saShell || {}, { firstOpen: \(firstOpen) })", completionHandler: nil)
                revealWeb()
                // a notification tapped while the app was closed: its deep link, now that the page is up
                NotifyBridge.flushPending()
            }
        }
        if message.name == "haptic" {
            let body = message.body as? [String: Any]
            let style = body?["style"] as? String ?? "light"
            let gen = UIImpactFeedbackGenerator(style: style == "soft" ? .soft : .light)
            gen.prepare()
            gen.impactOccurred(intensity: style == "soft" ? 0.7 : 0.5)
        }
        if message.name == "notify" {
            NotifyBridge.handle(message)
        }
        if message.name == "siwa" {
            let body = message.body as? [String: Any]
            let nonce = body?["nonce"] as? String ?? ""
            SignInWithApple.shared.start(nonce: nonce, anchor: self.view)
        }
        if message.name == "gauth" {
            // Google in the system sign-in sheet (SignInWithApple.swift, WebAuthSession)
            let body = message.body as? [String: Any]
            WebAuthSession.shared.start(url: (body?["url"] as? String).flatMap { URL(string: $0) }, anchor: self.view)
        }
        if message.name == "snap" {
            // Report a problem: the screen as it is, before the sheet (NotifyBridge.swift ReportBridge)
            ReportBridge.snapshot(message)
        }
        if message.name == "saveToPhotos" {
            // Save to Photos: download natively, add-only access, into the camera roll (SaveToPhotos.swift)
            SaveToPhotos.handle(message)
        }
  }
}

/// WHICH PROCESS DIED (2026-10-26). `app/src/lib/lifeline.ts` tells a crash from an app the person
/// closed by how long ago the page's last note was written — a death on screen is reloaded at once —
/// and that gap decides, alone. What only the shell knows is WHICH process died: `exit: 1` at document
/// start means this shell can say (WebView.swift), and `sa_resume=1` on a page it resumed means it was
/// WebKit's content process; a crash with no marker is the whole app, opened again by hand. The page
/// carries that beside the crash and never lets it decide one: a content process iOS takes in the
/// background is reloaded with the marker hours later, which is no on-screen crash. lib/lifeline.ts
/// strips the parameter the moment it reads it, so it never rides a reload or a share.
enum ExitBridge {
    static let param = "sa_resume"

    static func mark(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = parts.queryItems ?? []
        items.removeAll { $0.name == param }
        items.append(URLQueryItem(name: param, value: "1"))
        parts.queryItems = items
        return parts.url ?? url
    }
}
