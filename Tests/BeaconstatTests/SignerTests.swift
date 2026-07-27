import XCTest
@testable import Beaconstat

/// Crypto-only vectors: HMAC-SHA256 over an arbitrary byte string, reproduced
/// independently with `openssl dgst -sha256` / `-hmac`.
///
/// **These do not pin the wire format**, and used to be mistaken for a test that
/// did. `body` below is a hand-written string `PayloadEncoder` never produces —
/// the encoder emits `.sortedKeys`, so the real order is
/// `environment, events, productVersion`, not the `productVersion, environment,
/// events` written here (test gap 5). The vectors are still worth keeping,
/// because signing arbitrary bytes correctly is exactly what they check; they
/// are just answering a narrower question than the name suggested.
///
/// `WireGoldenVectorTests` is the one that pins the format, over the bytes the
/// encoder actually emits, coordinated with the backend.
final class SignerTests: XCTestCase {
    // Raw string (#"..."#) so the inner quotes are literal, byte-identical to the vector.
    private let body = Data(#"{"productVersion":"1.5.0","environment":{"device.platform":"ios"},"events":[{"name":"_bcs.install_detected","time":"2026-04-19T10:30:00.000Z"}]}"#.utf8)
    private let publicKey = "bcs_pub_abcdef0123456789"
    private let hmacSecret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private let timestamp = "2026-04-19T10:30:00.000Z"

    func testBodyHashMatchesGoldenVector() {
        XCTAssertEqual(Signer.sha256Hex(body),
                       "ad165d2191031377f6ad81ebd34ca021998899b51a3d0288ffb4c51cabf7b286")
    }

    func testSignatureMatchesGoldenVector() {
        let sig = Signer.sign(body: body, publicKey: publicKey,
                              hmacSecret: hmacSecret, timestamp: timestamp)
        XCTAssertEqual(sig, "98b7e041d493cddc79c81dae5f357117cc20708c2960634b1b6d9ad0cb12cda3")
    }

    func testCanonicalPayloadShape() {
        let hash = Signer.sha256Hex(body)
        XCTAssertEqual(Signer.canonicalPayload(timestamp: timestamp, publicKey: publicKey, bodyHash: hash),
                       "\(timestamp).\(publicKey).\(hash)")
    }

    func testSignatureIsLowercaseHex64Chars() {
        let sig = Signer.sign(body: body, publicKey: publicKey, hmacSecret: hmacSecret, timestamp: timestamp)
        XCTAssertEqual(sig.count, 64)
        XCTAssertTrue(sig.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}
