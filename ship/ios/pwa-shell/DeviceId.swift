import Foundation
import Security

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
