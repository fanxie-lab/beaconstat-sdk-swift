import Foundation

/// Keys the SDK persists in secure storage. Raw values are the Keychain account names.
enum SecureStoreKey: String, CaseIterable {
    case siteToken = "site_token"
    case installId = "install_id"
    case hasEmittedInstall = "has_emitted_install"
    case lastSessionStartedAt = "last_session_started_at"
    case hasStartedSession = "has_started_session"
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
            kSecUseDataProtectionKeychain as String: true,
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
        _ = write(value, forKey: key)
    }

    /// Returns whether the write (or delete) succeeded. `set` ignores it to
    /// keep the protocol total; internal callers can use this if they care.
    @discardableResult
    func write(_ value: String?, forKey key: SecureStoreKey) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let deleteStatus = SecItemDelete(base as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            return false
        }
        guard let value, let data = value.data(using: .utf8) else {
            return true // nil value = delete only
        }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Best-effort check that the Keychain is usable in this process (an unsigned
    /// SwiftPM test bundle, or a misconfigured entitlement, returns false).
    static func probeAvailability(service: String = "com.beaconstat.sdk.probe") -> Bool {
        let store = KeychainSecureStore(service: service)
        let ok = store.write("1", forKey: .installId)
        store.set(nil, forKey: .installId) // clean up the sentinel
        return ok
    }
}

/// Routes to `primary` when available, else a `fallback` (in-memory, degraded).
/// The choice is made once at construction.
final class FallbackSecureStore: SecureStore {
    private let store: SecureStore

    init(primary: SecureStore, isPrimaryAvailable: () -> Bool, fallback: () -> SecureStore) {
        store = isPrimaryAvailable() ? primary : fallback()
    }

    func string(forKey key: SecureStoreKey) -> String? { store.string(forKey: key) }
    func set(_ value: String?, forKey key: SecureStoreKey) { store.set(value, forKey: key) }
}
