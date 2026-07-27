import XCTest
@testable import Beaconstat

/// Deep-link sanitisation: only `scheme` and `host` may reach the wire, never
/// the path, the query or the fragment.
///
/// Test gap 10 — these assertions used to be `body.contains("…")` against the
/// raw JSON. `XCTAssertFalse(body.contains("abc123"))` was the sharp one:
/// `abc123` is pure hex, and every body carries a random session-id UUID, so
/// about once in a million runs it failed for a reason with nothing to do with
/// sanitisation. Four lines below, the team had documented that exact failure
/// class ("a purely numeric/hex marker here caused an intermittent false
/// failure") and worked around it by choosing a non-hex marker — but left this
/// instance in. The workaround also only fixes the false *failure*; a leaked
/// substring that happens to appear inside a property key still produces a false
/// pass.
///
/// Decoding the batch and asserting on the properties fixes both directions.
final class BeaconstatCoreOpenURLTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    /// The one `_bcs.apple.opened_from_url` event that was sent.
    private func openedEvent(file: StaticString = #filePath,
                             line: UInt = #line) throws -> SentBatch.SentEvent {
        try XCTUnwrap(SentBatch.firstEvent(named: "_bcs.apple.opened_from_url"),
                      "no opened_from_url event reached the wire", file: file, line: line)
    }

    private func makeCore() -> BeaconstatCore {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let c = BeaconstatCore(store: InMemorySecureStore(),
                               clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app",
                               // Was leaked on every invocation, like test gap 11's
                               // `AppUpdatedTests.run()` — this file was never flagged.
                               queueFileURL: makeTemporaryQueueFile(),
                               reachabilityFactory: { _ in nil })
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: o, environment: ["device.platform": "ios"])
        return c
    }

    private func settle(_ c: BeaconstatCore) {
        c.flush()
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    func testUniversalLinkSanitizesPathAndQuery() throws {
        let c = makeCore()
        c.trackOpenURL(URL(string: "https://example.com/secret/path?token=abc123#frag")!)
        settle(c)

        // Exactly these keys, exactly these values, and nothing else. Anything
        // derived from the path, the query or the fragment would have to appear
        // here — under this name or another — and cannot.
        try XCTAssertEqual(openedEvent().propertiesExcludingSessionId,
                           ["_bcs.apple.entry_type": "universal_link",
                            "_bcs.apple.url_scheme": "https",
                            "_bcs.apple.url_host": "example.com"])
        // Belt and braces across the whole run, for the markers that cannot
        // occur inside a hex UUID. `abc123` and the rest are deliberately *not*
        // scanned for here — a hex marker collides with the random session id
        // roughly once in a million runs, which is the flake the original
        // `body.contains("abc123")` carried. The exact-dictionary assertion
        // above already covers them, with no coincidence to trip over.
        let values = SentBatch.allPropertyValues()
        for leaked in ["secret", "token", "frag"] {
            XCTAssertFalse(values.contains { $0.contains(leaked) },
                           "\(leaked) reached the wire: \(values)")
        }
        c.shutdown()
    }

    func testCustomSchemeIsUrlScheme() throws {
        let c = makeCore()
        // The path marker is a plain "42" again: the previous version had to
        // pick a deliberately non-hex marker ("zzyzx") to avoid colliding with
        // the session UUID. Comparing the property dictionary exactly removes
        // the need for that workaround entirely.
        c.trackOpenURL(URL(string: "myapp://open/item/42")!)
        settle(c)

        try XCTAssertEqual(openedEvent().propertiesExcludingSessionId,
                           ["_bcs.apple.entry_type": "url_scheme",
                            "_bcs.apple.url_scheme": "myapp",
                            "_bcs.apple.url_host": "open"])
        c.shutdown()
    }

    func testOpenActivityWithNilURL() throws {
        let c = makeCore()
        c.trackOpenActivity(nil)
        settle(c)

        let event = try openedEvent()
        XCTAssertNotNil(event["_bcs.session.id"])
        XCTAssertEqual(event.propertiesExcludingSessionId,
                       ["_bcs.apple.entry_type": "activity"])
        c.shutdown()
    }

    func testOpenActivityWithWebpageURL() throws {
        let c = makeCore()
        c.trackOpenActivity(URL(string: "https://example.com/deep/path?x=1"))
        settle(c)

        // entry_type is hardcoded "activity" — NOT derived from the scheme, so
        // a universal link arriving as an activity is still labelled `activity`.
        try XCTAssertEqual(openedEvent().propertiesExcludingSessionId,
                           ["_bcs.apple.entry_type": "activity",
                            "_bcs.apple.url_scheme": "https",
                            "_bcs.apple.url_host": "example.com"])
        c.shutdown()
    }

    func testSchemeComparisonIsCaseInsensitive() throws {
        let c = makeCore()
        c.trackOpenURL(URL(string: "HTTPS://Example.COM/foo")!)
        settle(c)

        // `universal_link` proves the scheme check lowercases; the host and
        // scheme values prove both are normalised on the way out.
        try XCTAssertEqual(openedEvent().propertiesExcludingSessionId,
                           ["_bcs.apple.entry_type": "universal_link",
                            "_bcs.apple.url_scheme": "https",
                            "_bcs.apple.url_host": "example.com"])
        c.shutdown()
    }
}
