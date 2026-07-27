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

    /// Whether this key may be written to the on-disk identity mirror when the
    /// Keychain is unusable (see `LayeredSecureStore`).
    ///
    /// `siteToken` is excluded: it is a bearer credential, and it costs one
    /// handshake to replace, so there is no reason to persist it outside the
    /// Keychain. Everything else is anonymous local state whose *stability* is
    /// worth more than its secrecy — an unstable `installId` reports one install
    /// as many (H5).
    var isMirrorable: Bool { self != .siteToken }
}

/// Abstraction over secure persistence. `set(nil, forKey:)` deletes the key.
protocol SecureStore: AnyObject {
    func string(forKey key: SecureStoreKey) -> String?

    /// Writes (or, for `nil`, deletes) a value.
    ///
    /// - Returns: `false` when the write could **not** be persisted, i.e. the
    ///   value will not be there on the next launch. Callers that record
    ///   exactly-once facts (`hasEmittedInstall`, `installId`) must check this:
    ///   claiming a first install you cannot remember means claiming it again on
    ///   every launch (H5). Volatile stores report `true` — they are only used
    ///   in tests and as the last-resort tier inside `LayeredSecureStore`, which
    ///   reports durability on their behalf.
    @discardableResult
    func set(_ value: String?, forKey key: SecureStoreKey) -> Bool

    /// Non-`nil` when secure storage is not working as intended, with a reason
    /// fit for a log line. The core logs this once at `configure()` so a
    /// degraded install is visible instead of silently inflating metrics.
    var degradationDescription: String? { get }
}

extension SecureStore {
    var degradationDescription: String? { nil }
}

/// Stores that can scope their items to a shared Keychain access group (M12).
protocol KeychainAccessGroupConfigurable: AnyObject {
    /// Scopes newly written Keychain items to `group`, so a host app and its
    /// extensions resolve to one install identity. Must match a
    /// `keychain-access-groups` entitlement shared by both targets.
    func setKeychainAccessGroup(_ group: String?)
}

/// Thread-safe in-memory store. The last-resort tier of `LayeredSecureStore`,
/// and the store the test suite injects.
final class InMemorySecureStore: SecureStore {
    private var storage: [SecureStoreKey: String] = [:]
    private let lock = NSLock()

    func string(forKey key: SecureStoreKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    @discardableResult
    func set(_ value: String?, forKey key: SecureStoreKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
        return true
    }
}

/// Keychain-backed store (generic password items under one service).
final class KeychainSecureStore: SecureStore, KeychainAccessGroupConfigurable {
    /// Injectable `SecItem*` seam. The real Keychain is unavailable in an
    /// unsigned SwiftPM test bundle, which is why the delete-then-add logic,
    /// the access group, and every failure path had zero executed coverage.
    struct SecItemAPI {
        var copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        var delete: (CFDictionary) -> OSStatus

        static let system = SecItemAPI(copyMatching: SecItemCopyMatching,
                                       add: SecItemAdd,
                                       delete: SecItemDelete)
    }

    private let service: String
    private let secItem: SecItemAPI
    private let lock = NSLock()
    private var accessGroup: String?

    init(service: String = "com.beaconstat.sdk", secItem: SecItemAPI = .system) {
        self.service = service
        self.secItem = secItem
    }

    func setKeychainAccessGroup(_ group: String?) {
        lock.lock(); defer { lock.unlock() }
        accessGroup = group
    }

    private var currentAccessGroup: String? {
        lock.lock(); defer { lock.unlock() }
        return accessGroup
    }

    func string(forKey key: SecureStoreKey) -> String? {
        // Deliberately no `kSecAttrAccessGroup`: an unscoped query spans every
        // access group the process can reach, so an app that already has an
        // item in its private group still finds it after adopting a shared
        // group (M12) — adopting the option must not mint a new install.
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard secItem.copyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Delete-then-add (the Keychain has no upsert).
    ///
    /// - Returns: whether the Keychain accepted the change. Previously this was
    ///   discarded, so a per-key write failure was invisible (H5).
    @discardableResult
    func set(_ value: String?, forKey key: SecureStoreKey) -> Bool {
        let base = baseQuery(for: key)
        // Unscoped delete, for the same reason the read is unscoped: it must
        // clear any copy in any reachable group, or a stale item in the private
        // group would keep shadowing the shared one.
        let deleteStatus = secItem.delete(base as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            return false
        }
        guard let value, let data = value.data(using: .utf8) else {
            return true // nil value = delete only
        }
        var add = base
        add[kSecValueData as String] = data
        // ...ThisDeviceOnly: identity must not ride an encrypted backup onto a
        // second device, where it would merge two installs into one (H5).
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let group = currentAccessGroup { add[kSecAttrAccessGroup as String] = group }
        return secItem.add(add as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(for key: SecureStoreKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}

/// Durable, non-Keychain mirror for the SDK's anonymous local state.
///
/// Exists for one reason: when the Keychain is unusable — unsandboxed macOS,
/// where `kSecUseDataProtectionKeychain` needs an entitlement, or an iOS
/// background launch before the first unlock — the SDK used to generate a fresh
/// `installId` on every launch and re-fire `install_detected` with
/// `is_first_session=true`, so a handful of real installs reported as hundreds
/// (H5). A plain JSON file keeps that state stable across launches.
///
/// Never holds `siteToken` (see `SecureStoreKey.isMirrorable`). Writes are
/// atomic; a missing or corrupt file reads as empty. No I/O in `init` — this is
/// constructed on the main thread during app launch (M6).
final class FileSecureStore: SecureStore {
    private let fileURL: URL
    private let lock = NSLock()
    private var cache: [String: String]?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func string(forKey key: SecureStoreKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loaded()[key.rawValue]
    }

    @discardableResult
    func set(_ value: String?, forKey key: SecureStoreKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var contents = loaded()
        contents[key.rawValue] = value
        guard let data = try? JSONSerialization.data(withJSONObject: contents, options: [.sortedKeys]) else {
            return false
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return false
        }
        cache = contents
        return true
    }

    /// Caller must hold `lock`.
    private func loaded() -> [String: String] {
        if let cache { return cache }
        let contents = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            ?? [:]
        cache = contents
        return contents
    }
}

/// Read-through, per-operation secure store.
///
/// Replaces the old `FallbackSecureStore`, which chose Keychain-or-in-memory
/// **once** at construction: a single probe failure stranded the whole process
/// on volatile storage for its entire lifetime, even if the Keychain became
/// usable a second later (H5).
///
/// Tiers, in order:
/// 1. `primary` — the Keychain. Authoritative while it works.
/// 2. `mirror` — durable on-disk copy of the mirrorable keys, so a
///    Keychain-denied process does not mint a phantom install every launch.
/// 3. `volatile` — in-memory, so the SDK still functions for this run.
///
/// A read that misses `primary` but hits `mirror` back-fills `primary`, so the
/// Keychain becomes the source of truth again as soon as it can be.
final class LayeredSecureStore: SecureStore, KeychainAccessGroupConfigurable {
    private let primary: SecureStore
    private let mirror: SecureStore?
    private let volatile: SecureStore
    private let lock = NSLock()
    /// Keys whose `primary` write failed. `primary` may still hold a stale value
    /// for them, so reads must skip it until a write succeeds again.
    private var untrustedPrimaryKeys: Set<SecureStoreKey> = []
    private var degradation: String?

    init(primary: SecureStore, mirror: SecureStore?, volatile: SecureStore = InMemorySecureStore()) {
        self.primary = primary
        self.mirror = mirror
        self.volatile = volatile
    }

    var degradationDescription: String? {
        lock.lock(); defer { lock.unlock() }
        return degradation
    }

    func setKeychainAccessGroup(_ group: String?) {
        (primary as? KeychainAccessGroupConfigurable)?.setKeychainAccessGroup(group)
    }

    func string(forKey key: SecureStoreKey) -> String? {
        let primaryTrusted = trustsPrimary(key)
        if primaryTrusted, let value = primary.string(forKey: key) { return value }
        if key.isMirrorable, let value = mirror?.string(forKey: key) {
            // Read-through: heal the Keychain if it works again, so the mirror
            // stops being the source of truth (and stops reporting degraded).
            if primaryTrusted {
                if primary.set(value, forKey: key) { return value }
                // The heal failed, so the Keychain is not authoritative for this
                // key either — stop consulting it before it can shadow the mirror.
                distrustPrimary(key)
            }
            degrade("read \(key.rawValue) from the on-disk mirror — the Keychain did not have it")
            return value
        }
        return volatile.string(forKey: key)
    }

    @discardableResult
    func set(_ value: String?, forKey key: SecureStoreKey) -> Bool {
        let primaryOK = primary.set(value, forKey: key)
        let mirrorOK = key.isMirrorable ? (mirror?.set(value, forKey: key) ?? false) : false
        // Keep the volatile tier coherent unconditionally, so it can never serve
        // a value the caller has since overwritten.
        volatile.set(value, forKey: key)
        if primaryOK {
            trustPrimary(key)
        } else {
            distrustPrimary(key)
            degrade("Keychain write for \(key.rawValue) failed"
                    + (mirrorOK ? " — using the on-disk mirror" : " and no durable mirror accepted it"))
        }
        return primaryOK || mirrorOK
    }

    // MARK: - private

    private func trustsPrimary(_ key: SecureStoreKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !untrustedPrimaryKeys.contains(key)
    }

    private func trustPrimary(_ key: SecureStoreKey) {
        lock.lock(); defer { lock.unlock() }
        untrustedPrimaryKeys.remove(key)
    }

    private func distrustPrimary(_ key: SecureStoreKey) {
        lock.lock(); defer { lock.unlock() }
        untrustedPrimaryKeys.insert(key)
    }

    /// First reason wins — it is the most proximate cause, and repeating a
    /// downstream symptom on every subsequent key is noise.
    private func degrade(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        if degradation == nil { degradation = reason }
    }
}
