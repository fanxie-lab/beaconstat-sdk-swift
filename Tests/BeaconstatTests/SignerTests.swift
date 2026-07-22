import XCTest
@testable import Beaconstat

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
