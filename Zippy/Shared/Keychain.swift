import Foundation
import Security

/// Minimal access to generic passwords in the keychain.
/// Used by both the app and the FSKit extension.
enum Keychain {
    /// Hands a password from the app to the FSKit extension (one-shot, deleted after reading).
    static let handoffService = "dev.zippy.password-handoff"

    /// Keychain group shared by app and extension, from Info.plist
    /// (`ZippyKeychainGroup`, e.g. "TEAMID.dev.zippy.shared"). Empty without a team ID.
    static var sharedGroup: String? {
        (Bundle.main.object(forInfoDictionaryKey: "ZippyKeychainGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Replaces any existing item for `service`/`account`.
    /// - Parameter accessGroup: group shared by app and extension (FSKit), otherwise nil
    static func save(_ password: String, service: String, account: String, label: String? = nil,
                     accessGroup: String? = nil) {
        delete(service: service, account: account, accessGroup: accessGroup)
        var item = query(service: service, account: account, accessGroup: accessGroup)
        item[kSecValueData as String] = Data(password.utf8)
        if let label { item[kSecAttrLabel as String] = label }
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { log.error("Saving to keychain failed: \(status)") }
    }

    static func load(service: String, account: String, accessGroup: String? = nil) -> String? {
        var item = query(service: service, account: account, accessGroup: accessGroup)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String, accessGroup: String? = nil) {
        SecItemDelete(query(service: service, account: account, accessGroup: accessGroup) as CFDictionary)
    }

    private static func query(service: String, account: String, accessGroup: String?) -> [String: Any] {
        var item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Shared groups only exist in the data protection keychain, which requires a real
        // signature (team ID). Without a group we use the classic login keychain, which
        // also works with an ad-hoc signature.
        if let accessGroup {
            item[kSecAttrAccessGroup as String] = accessGroup
            item[kSecUseDataProtectionKeychain as String] = true
        }
        return item
    }
}
