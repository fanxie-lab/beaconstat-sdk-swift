import CryptoKit
import Foundation

/// HMAC request signing, matching the server's `signature.guard.ts` exactly.
enum Signer {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalPayload(timestamp: String, publicKey: String, bodyHash: String) -> String {
        "\(timestamp).\(publicKey).\(bodyHash)"
    }

    /// The HMAC key is the UTF-8 BYTES OF THE hmacSecret STRING (not hex-decoded) —
    /// the server keys `crypto.createHmac('sha256', hmacSecret)` the same way.
    static func sign(body: Data, publicKey: String, hmacSecret: String, timestamp: String) -> String {
        let bodyHash = sha256Hex(body)
        let canonical = canonicalPayload(timestamp: timestamp, publicKey: publicKey, bodyHash: bodyHash)
        let key = SymmetricKey(data: Data(hmacSecret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }
}
