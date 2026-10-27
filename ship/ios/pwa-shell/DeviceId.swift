import Foundation
import Security
import WebKit

/// THE DEVICE ID (the owner's Part 4, 2026-10-08) — one UUID per device, kept in the Keychain so it
/// survives a reinstall (the Keychain outlives the app's container; iCloud sync is off, so it never
/// travels to another device). The page reads it as `window.__saShell.deviceId` (WebView.swift)
/// and sends it when it mints a guest: the server then hands back the SAME guest — his feed state,
/// his history, everything he has seen — instead of a second viewer with a fresh thirty-day horizon.
/// It identifies the device to this app's own server and nothing else; it is never shown, never
/// logged, and goes nowhere but `POST /auth/guest`.
enum DeviceId {
    private static let service = "com.scrollanytime.app"
    private static let account = "device-id"

    /// The device's id, created on first use.
    static func current() -> String {
        if let have = read(), !have.isEmpty { return have }
        let fresh = UUID().uuidString.lowercased()
        write(fresh)
        return fresh
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        // readable after the first unlock, on this device only: never synced, never in a backup restored elsewhere
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// THE SESSION, WHERE A WEB STORAGE WIPE CANNOT REACH IT (the owner's P0, 2026-10-22: "people are signed out
/// every day"). The page (app/src/lib/session.ts) saves the session it holds — the token, the person, the
/// refresh secret, when it was last renewed: one JSON string it alone reads — through the `session` bridge
/// after every change, and asks for it back when it boots with nothing in web storage (iOS evicted the web
/// view's data, the store was cleared): the same person comes back with no round trip and no sign-in. One
/// generic-password item beside the device id: this device only, readable after the first unlock, never
/// synced, never in a backup restored elsewhere. Only the page's sign-out (endSession) clears it.
enum SessionKeychain {
    private static let service = "com.scrollanytime.app"
    private static let account = "session"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        // an update keeps the item's attributes; a first save adds it
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func clear() {
        SecItemDelete(base as CFDictionary)
    }
}

/// The `session` handler (WebView.swift), answered with a reply: `postMessage({op})` is a promise on the page.
///   { op: "get" }             → the saved JSON, or null
///   { op: "save", value }     → kept (the page's whole session, as one string)
///   { op: "clear" }           → forgotten (sign-out)
/// Only the app's own pages, in the main frame, are answered.
final class SessionBridge: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == rootUrl.host else {
            replyHandler(nil, "not this app's page")
            return
        }
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "no op")
            return
        }
        switch op {
        case "get":
            replyHandler(SessionKeychain.read(), nil)
        case "save":
            guard let value = body["value"] as? String, value.utf8.count < 16_384 else {
                replyHandler(nil, "no value")
                return
            }
            SessionKeychain.write(value)
            UITestHooks.sessionSaved(value)
            replyHandler(true, nil)
        case "clear":
            SessionKeychain.clear()
            UITestHooks.sessionSaved(nil)
            replyHandler(true, nil)
        default:
            replyHandler(nil, "unknown op")
        }
    }
}
