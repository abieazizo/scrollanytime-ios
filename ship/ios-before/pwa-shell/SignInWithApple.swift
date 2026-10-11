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
            PWAShell.webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('siwa-result', { detail: \(json) }))")
        }
    }
}
