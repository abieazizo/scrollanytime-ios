import UIKit
import WebKit

var webView: WKWebView! = nil

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

    override func viewDidLoad() {
        super.viewDidLoad()
        initWebView()
        initToolbarView()
        loadRootUrl()
    
        NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification , object: nil)
        
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
        let winScene = UIApplication.shared.connectedScenes.first
        let windowScene = winScene as! UIWindowScene
        var statusBarHeight = windowScene.statusBarManager?.statusBarFrame.height ?? 60
        
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
        armLoadingPage()
        PWAShell.webView.load(URLRequest(url: SceneDelegate.universalLinkToLaunch ?? SceneDelegate.shortcutLinkToLaunch ?? rootUrl, cachePolicy: cachePolicy))
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
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        htmlIsLoaded = false;
        
        if (error as NSError)._code == (-999) { return }

        // PART 3.1 — THE FIRST-OPEN FALLBACK.
        //
        // On a cold launch with no network there is no service worker and no cache yet, so there is
        // nothing for WKWebView to show: it renders its own grey "cannot open page", or white. That
        // is an automatic rejection (2.1, and 4.2 "it's just a web page that doesn't work"), and it
        // is the FIRST thing an App Store reviewer does.
        //
        // Only for the first navigation. Once the app has loaded once, the web app's own offline
        // screen and its cached clips take over, and the retry loop below is the right behaviour.
        if !hasEverLoaded {
            showingOfflineFallback = true
            resetLoadingPage()
            loadingView.isHidden = true
            animateConnectionProblem(false)
            webView.isHidden = false
            webView.loadHTMLString(offlineFallbackHTML, baseURL: rootUrl)
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
            if (message.body as? String) == "painted" {
                showingOfflineFallback = false
                hasEverLoaded = true
                revealWeb()
            }
        }
        if message.name == "haptic" {
            let body = message.body as? [String: Any]
            let style = body?["style"] as? String ?? "light"
            let gen = UIImpactFeedbackGenerator(style: style == "soft" ? .soft : .light)
            gen.prepare()
            gen.impactOccurred(intensity: style == "soft" ? 0.7 : 0.5)
        }
        if message.name == "siwa" {
            let body = message.body as? [String: Any]
            let nonce = body?["nonce"] as? String ?? ""
            SignInWithApple.shared.start(nonce: nonce, anchor: self.view)
        }
  }
}
