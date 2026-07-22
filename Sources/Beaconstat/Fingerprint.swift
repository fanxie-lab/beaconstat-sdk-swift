import CryptoKit
import Foundation

/// Anonymous install identity. No IDFA, no IDFV-as-identity, no PII.
enum Fingerprint {
    /// Returns the persistent install id, generating and storing one on first use.
    /// The Keychain-backed store lets this survive app reinstall (same install).
    static func installId(store: SecureStore) -> String {
        if let existing = store.string(forKey: .installId), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        store.set(generated, forKey: .installId)
        return generated
    }

    /// SHA256 hex of `"{bundleIdentifier}|{installId}"` (lowercase, 64 chars).
    static func compute(bundleIdentifier: String, installId: String) -> String {
        let input = "\(bundleIdentifier)|\(installId)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
