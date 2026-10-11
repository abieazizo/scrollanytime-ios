import AuthenticationServices
import UIKit
import WebKit

// NATIVE Sign in with Apple for the web layer. The page posts { nonce } (already SHA-256'd) to the
// `siwa` message handler; the system sheet runs; the result goes back as a `siwa-result` event with
// the identity token, which the web layer sends to POST /auth/apple/native. No Services ID and no
// client secret are needed for this path — the token's audience is the app's bundle id.
final class SignInWithApple: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let shared = SignInWithApple()
    private weak var anchorView: UIView?

    func start(nonce: String, anchor: UIView) {
        anchorView = anchor
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        if !nonce.isEmpty { request.nonce = nonce }
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let window = anchorView?.window { return window }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            dispatch(["ok": false, "error": "no-token"])
            return
        }
        var detail: [String: Any] = ["ok": true, "identityToken": token, "user": cred.user]
        // Apple provides the name exactly once, on the first authorization
        if let n = cred.fullName {
            let parts = [n.givenName, n.familyName].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { detail["name"] = parts.joined(separator: " ") }
        }
        if let email = cred.email { detail["email"] = email }
        dispatch(detail)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let canceled = (error as? ASAuthorizationError)?.code == .canceled
        dispatch(["ok": false, "error": canceled ? "canceled" : "failed"])
    }

    private func dispatch(_ detail: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            PWAShell.webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('siwa-result', { detail: \(json) }))")
        }
    }
}

// GOOGLE, IN THE SYSTEM SIGN-IN SHEET (2026-09-28). Google used to load inside the app's own web
// view: a back-swipe, a Google hop outside WKAppBoundDomains, or any failed step reloaded the whole
// app with its launch film — "when one signs in with Google and goes back to sign in with something
// else the app fails" (the owner). Now the page posts { url } (the provider URL the Worker built,
// ?native=1) to the `gauth` message handler; ASWebAuthenticationSession shows Google with its own
// Cancel while the app underneath never navigates; and whatever the Worker's callback redirects to
// on the scrollanytime: scheme comes back as a `gauth-result` event. The scheme is deliberately NOT
// registered in Info.plist: only this session can receive it, and what it carries is a grant that
// only the page holding the verifier can redeem.
final class WebAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthSession()
    private static let callbackScheme = "scrollanytime"
    private var session: ASWebAuthenticationSession?
    private weak var anchorView: UIView?

    func start(url: URL?, anchor: UIView) {
        // only ever Google's authorize endpoint — never a page the web layer names at will
        guard let url = url, url.scheme == "https", url.host == "accounts.google.com" else {
            dispatch(["ok": false, "error": "bad-url"])
            return
        }
        // a second tap while a sheet is up: that sheet answers, this one is refused
        if session != nil {
            dispatch(["ok": false, "error": "busy"])
            return
        }
        anchorView = anchor
        let done: (URL?, Error?) -> Void = { [weak self] callbackURL, error in
            DispatchQueue.main.async {
                self?.session = nil
                if let callbackURL = callbackURL {
                    self?.dispatch(["ok": true, "url": callbackURL.absoluteString])
                } else {
                    let canceled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    self?.dispatch(["ok": false, "error": canceled ? "canceled" : "failed"])
                }
            }
        }
        let s: ASWebAuthenticationSession
        if #available(iOS 17.4, *) {
            s = ASWebAuthenticationSession(url: url, callback: .customScheme(WebAuthSession.callbackScheme), completionHandler: done)
        } else {
            s = ASWebAuthenticationSession(url: url, callbackURLScheme: WebAuthSession.callbackScheme, completionHandler: done)
        }
        s.presentationContextProvider = self
        // shared cookies: someone already signed in to Google in Safari just picks the account
        s.prefersEphemeralWebBrowserSession = false
        session = s
        if !s.start() {
            session = nil
            dispatch(["ok": false, "error": "failed"])
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window = anchorView?.window { return window }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private func dispatch(_ detail: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            PWAShell.webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('gauth-result', { detail: \(json) }))")
        }
    }
}
