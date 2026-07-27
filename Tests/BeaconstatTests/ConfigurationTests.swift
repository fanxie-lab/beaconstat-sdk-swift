import XCTest
@testable import Beaconstat

final class ConfigurationTests: XCTestCase {
    private let validHmac = String(repeating: "a", count: 64)

    func testAcceptsValidCredentialsAndDefaultsToProductionURL() throws {
        let cfg = try Configuration(publicKey: "bcs_pub_abc123",
                                   hmacSecret: validHmac,
                                   options: BeaconstatOptions())
        XCTAssertEqual(cfg.publicKey, "bcs_pub_abc123")
        XCTAssertEqual(cfg.hmacSecret, validHmac)
        XCTAssertEqual(cfg.baseURL, URL(string: "https://ingest.beaconstat.com")!)
    }

    func testRejectsPublicKeyWithoutPrefix() {
        XCTAssertThrowsError(try Configuration(publicKey: "pub_abc",
                                              hmacSecret: validHmac,
                                              options: BeaconstatOptions())) {
            XCTAssertEqual($0 as? Configuration.ValidationError, .invalidPublicKey)
        }
    }

    func testRejectsPrefixOnlyPublicKey() {
        XCTAssertThrowsError(try Configuration(publicKey: "bcs_pub_",
                                              hmacSecret: validHmac,
                                              options: BeaconstatOptions())) {
            XCTAssertEqual($0 as? Configuration.ValidationError, .invalidPublicKey)
        }
    }

    func testRejectsHmacOfWrongLength() {
        XCTAssertThrowsError(try Configuration(publicKey: "bcs_pub_abc",
                                              hmacSecret: "abc",
                                              options: BeaconstatOptions())) {
            XCTAssertEqual($0 as? Configuration.ValidationError, .invalidHmacSecret)
        }
    }

    func testRejectsNonHexHmac() {
        let nonHex = String(repeating: "z", count: 64)
        XCTAssertThrowsError(try Configuration(publicKey: "bcs_pub_abc",
                                              hmacSecret: nonHex,
                                              options: BeaconstatOptions())) {
            XCTAssertEqual($0 as? Configuration.ValidationError, .invalidHmacSecret)
        }
    }

    func testRejectsFullwidthUnicodeHexDigits() {
        let fullwidth = String(repeating: "\u{FF10}", count: 64) // 64 fullwidth "0"
        XCTAssertThrowsError(try Configuration(publicKey: "bcs_pub_abc",
                                              hmacSecret: fullwidth,
                                              options: BeaconstatOptions())) {
            XCTAssertEqual($0 as? Configuration.ValidationError, .invalidHmacSecret)
        }
    }

    func testRejectsOverLengthHmac() {
        let tooLong = String(repeating: "a", count: 65)
        XCTAssertThrowsError(try Configuration(publicKey: "bcs_pub_abc",
                                              hmacSecret: tooLong,
                                              options: BeaconstatOptions())) {
            XCTAssertEqual($0 as? Configuration.ValidationError, .invalidHmacSecret)
        }
    }

    func testEndpointOverrideWins() throws {
        var opts = BeaconstatOptions()
        opts.endpoint = URL(string: "https://ingest.staging.example.com")!
        let cfg = try Configuration(publicKey: "bcs_pub_abc",
                                   hmacSecret: validHmac, options: opts)
        XCTAssertEqual(cfg.baseURL, URL(string: "https://ingest.staging.example.com")!)
    }

    /// A cleartext override needs the explicit opt-in (M11) — see
    /// `TransportHygieneTests` for the full scheme matrix.
    func testCleartextEndpointOverrideRequiresTheOptIn() throws {
        var opts = BeaconstatOptions()
        opts.endpoint = URL(string: "http://localhost:3000")!
        XCTAssertThrowsError(try Configuration(publicKey: "bcs_pub_abc",
                                              hmacSecret: validHmac, options: opts))
        opts.allowInsecureEndpoint = true
        let cfg = try Configuration(publicKey: "bcs_pub_abc",
                                   hmacSecret: validHmac, options: opts)
        XCTAssertEqual(cfg.baseURL, URL(string: "http://localhost:3000")!)
    }
}
