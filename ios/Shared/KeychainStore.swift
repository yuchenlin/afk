import Foundation
import Security

/// Keychain helper for the xAI API key, shared between host and keyboard via access group.
public enum KeychainStore {
    public static let xaiService = "xyz.yuchenlin.afk.ios.xai"
    public static let xaiAccount = "api-key"

    public static func saveAPIKey(_ key: String, service: String = xaiService, account: String = xaiAccount) throws {
        let data = Data(key.utf8)
        // Remove both shared and legacy (no access-group) copies so we don't leave orphans.
        deleteAPIKey(service: service, account: account, shared: true)
        deleteAPIKey(service: service, account: account, shared: false)

        var attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccessGroup as String: AppGroupConstants.keychainAccessGroup,
        ]
        var status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecMissingEntitlement || status == errSecParam {
            // Fallback without access group (e.g. simulator / mis-provisioned).
            attrs.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemAdd(attrs as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    public static func readAPIKey(service: String = xaiService, account: String = xaiAccount) -> String? {
        if let shared = readRaw(service: service, account: account, shared: true) {
            return shared
        }
        // Migrate legacy item (saved before access-group entitlements) into the shared group.
        if let legacy = readRaw(service: service, account: account, shared: false) {
            try? saveAPIKey(legacy, service: service, account: account)
            return legacy
        }
        return nil
    }

    public static func deleteAPIKey(service: String = xaiService, account: String = xaiAccount) {
        deleteAPIKey(service: service, account: account, shared: true)
        deleteAPIKey(service: service, account: account, shared: false)
    }

    private static func deleteAPIKey(service: String, account: String, shared: Bool) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if shared {
            query[kSecAttrAccessGroup as String] = AppGroupConstants.keychainAccessGroup
        }
        SecItemDelete(query as CFDictionary)
    }

    private static func readRaw(service: String, account: String, shared: Bool) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if shared {
            query[kSecAttrAccessGroup as String] = AppGroupConstants.keychainAccessGroup
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    public enum KeychainError: LocalizedError {
        case unhandled(OSStatus)
        public var errorDescription: String? {
            switch self {
            case let .unhandled(status): return "Keychain error \(status)"
            }
        }
    }
}
