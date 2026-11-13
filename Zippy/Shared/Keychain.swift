import Foundation
import Security

/// Kleiner Zugriff auf generische Passwörter im Schlüsselbund.
/// Wird von der App und der FSKit-Erweiterung benutzt.
enum Keychain {
    /// Übergabe des Passworts von der App an die FSKit-Erweiterung (einmalig, wird gelöscht).
    static let handoffService = "dev.zippy.password-handoff"

    /// Gemeinsame Schlüsselbund-Gruppe von App und Erweiterung aus dem Info.plist
    /// (`ZippyKeychainGroup`, z. B. "TEAMID.dev.zippy.shared"). Leer ohne Team-ID.
    static var sharedGroup: String? {
        (Bundle.main.object(forInfoDictionaryKey: "ZippyKeychainGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// - Parameter accessGroup: gemeinsame Gruppe für App und Erweiterung (FSKit), sonst nil
    static func save(_ password: String, service: String, account: String, label: String? = nil,
                     accessGroup: String? = nil) {
        delete(service: service, account: account, accessGroup: accessGroup)
        var item = query(service: service, account: account, accessGroup: accessGroup)
        item[kSecValueData as String] = Data(password.utf8)
        if let label { item[kSecAttrLabel as String] = label }
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { log.error("Schlüsselbund speichern: \(status)") }
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
        // Gemeinsame Gruppen gibt es nur im Data-Protection-Schlüsselbund; der braucht
        // eine richtige Signatur (Team-ID). Ohne Gruppe: klassischer Anmelde-Schlüsselbund,
        // der auch mit Ad-hoc-Signatur funktioniert.
        if let accessGroup {
            item[kSecAttrAccessGroup as String] = accessGroup
            item[kSecUseDataProtectionKeychain as String] = true
        }
        return item
    }
}
