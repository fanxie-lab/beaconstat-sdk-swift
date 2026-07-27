import XCTest
@testable import Beaconstat

/// M11 — the analytics transport shared the host app's cookie storage and URL
/// cache, had no request timeout, and accepted an `http://` endpoint that would
/// ship the site token and HMAC signature in cleartext.
final class TransportHygieneTests: XCTestCase {
    private let validHmac = String(repeating: "a", count: 64)

    // MARK: - URLSession configuration

    /// `URLSession(configuration: .default)` stores and replays `Set-Cookie`
    /// from the ingest host in the app's shared `HTTPCookieStorage`, and writes
    /// responses into the app's shared `URLCache`. Neither belongs to a
    /// telemetry transport.
    func testSessionSharesNoCookieJarOrCacheWithTheHostApp() {
        let config = TelemetrySession.make().configuration
        XCTAssertNil(config.httpCookieStorage, "must not touch the app's cookie jar")
        XCTAssertNil(config.urlCache, "must not touch the app's URL cache")
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.httpCookieAcceptPolicy, .never)
        XCTAssertNotEqual(config.httpCookieStorage, HTTPCookieStorage.shared)
    }

    /// The 60 s default is a long time to hold a background assertion open for
    /// a request that is not going to complete (H2).
    func testSessionHasASensibleRequestTimeout() {
        let config = TelemetrySession.make().configuration
        XCTAssertLessThanOrEqual(config.timeoutIntervalForRequest, 20)
        XCTAssertGreaterThan(config.timeoutIntervalForRequest, 0)
        XCTAssertLessThanOrEqual(config.timeoutIntervalForResource, 60)
    }

    /// Retry and reconnect are the SDK's job; `waitsForConnectivity` would hold
    /// a request open indefinitely behind our own backoff.
    func testSessionDoesNotWaitForConnectivity() {
        XCTAssertFalse(TelemetrySession.make().configuration.waitsForConnectivity)
    }

    // MARK: - Endpoint scheme (M11)

    func testHttpsEndpointIsAccepted() throws {
        var options = BeaconstatOptions()
        options.endpoint = URL(string: "https://ingest.example.com")!
        let config = try Configuration(publicKey: "bcs_pub_abc", hmacSecret: validHmac,
                                       options: options)
        XCTAssertEqual(config.baseURL, URL(string: "https://ingest.example.com")!)
    }

    /// `http://` ships the site token and the HMAC signature in cleartext.
    func testPlainHttpEndpointIsRejectedByDefault() {
        var options = BeaconstatOptions()
        options.endpoint = URL(string: "http://ingest.example.com")!
        XCTAssertThrowsError(try Configuration(publicKey: "bcs_pub_abc", hmacSecret: validHmac,
                                               options: options)) {
            XCTAssertEqual($0 as? Configuration.ValidationError, .insecureEndpoint)
        }
    }

    /// Local development and CI need it, so the escape hatch is explicit rather
    /// than the check being weakened.
    func testPlainHttpIsAllowedWithTheExplicitOptIn() throws {
        var options = BeaconstatOptions()
        options.endpoint = URL(string: "http://localhost:3000")!
        options.allowInsecureEndpoint = true
        let config = try Configuration(publicKey: "bcs_pub_abc", hmacSecret: validHmac,
                                       options: options)
        XCTAssertEqual(config.baseURL, URL(string: "http://localhost:3000")!)
    }

    /// The opt-in relaxes the check to `http`, not to anything at all.
    func testNonHttpSchemesAreRejectedEvenWithTheOptIn() {
        for raw in ["file:///tmp/x", "ftp://example.com", "ws://example.com", "javascript:alert(1)"] {
            var options = BeaconstatOptions()
            options.endpoint = URL(string: raw)!
            options.allowInsecureEndpoint = true
            XCTAssertThrowsError(try Configuration(publicKey: "bcs_pub_abc", hmacSecret: validHmac,
                                                   options: options), raw) {
                XCTAssertEqual($0 as? Configuration.ValidationError, .insecureEndpoint, raw)
            }
        }
    }

    func testEndpointWithoutAHostIsRejected() {
        var options = BeaconstatOptions()
        options.endpoint = URL(string: "https://")!
        XCTAssertThrowsError(try Configuration(publicKey: "bcs_pub_abc", hmacSecret: validHmac,
                                               options: options)) {
            XCTAssertEqual($0 as? Configuration.ValidationError, .insecureEndpoint)
        }
    }

    /// The default production endpoint must not need the opt-in.
    func testDefaultEndpointNeedsNoOptIn() throws {
        let config = try Configuration(publicKey: "bcs_pub_abc", hmacSecret: validHmac,
                                       options: BeaconstatOptions())
        XCTAssertEqual(config.baseURL.scheme, "https")
    }

    /// A cleartext endpoint is a decision the host should see in its log.
    func testInsecureEndpointIsRecordedAsAClampNotice() throws {
        var options = BeaconstatOptions()
        options.endpoint = URL(string: "http://localhost:3000")!
        options.allowInsecureEndpoint = true
        let config = try Configuration(publicKey: "bcs_pub_abc", hmacSecret: validHmac,
                                       options: options)
        XCTAssertTrue(config.clampNotices.contains { $0.contains("cleartext") },
                      "expected a warning, got: \(config.clampNotices)")
    }
}
