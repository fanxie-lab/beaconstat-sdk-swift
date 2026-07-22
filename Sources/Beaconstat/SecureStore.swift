import Foundation

/// Keys the SDK persists in secure storage. Raw values are the Keychain account names.
enum SecureStoreKey: String, CaseIterable {
    case siteToken = "site_token"
    case installId = "install_id"
    case hasEmittedInstall = "has_emitted_install"
    case lastSessionStartedAt = "last_session_started_at"
    case lastKnownVersion = "last_known_version"
    case lastKnownBuild = "last_known_build"
    case optedOut = "opted_out"
}

/// Abstraction over secure persistence. `set(nil, forKey:)` deletes the key.
protocol SecureStore: AnyObject {
    func string(forKey key: SecureStoreKey) -> String?
    func set(_ value: String?, forKey key: SecureStoreKey)
}

/// Thread-safe in-memory store. Used in tests and as the degraded fallback
/// (M8) when the Keychain is unavailable.
final class InMemorySecureStore: SecureStore {
    private var storage: [SecureStoreKey: String] = [:]
    private let lock = NSLock()

    func string(forKey key: SecureStoreKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ value: String?, forKey key: SecureStoreKey) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }
}

/// Keychain-backed store (generic password items under one service).
final class KeychainSecureStore: SecureStore {
    private let service: String

    init(service: String = "com.beaconstat.sdk") {
        self.service = service
    }

    func string(forKey key: SecureStoreKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, forKey key: SecureStoreKey) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(base as CFDictionary) // idempotent
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
