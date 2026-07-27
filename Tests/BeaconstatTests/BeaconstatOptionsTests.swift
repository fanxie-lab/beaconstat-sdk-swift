import XCTest
@testable import Beaconstat

final class BeaconstatOptionsTests: XCTestCase {
    func testDefaults() {
        let o = BeaconstatOptions()
        XCTAssertEqual(o.batchSize, 50)
        XCTAssertEqual(o.sessionTimeout, 300)
        XCTAssertEqual(o.maxQueuedEvents, 500)
        XCTAssertEqual(o.maxRetries, 3)
        XCTAssertTrue(o.flushOnBackground)
        XCTAssertFalse(o.collectAccessibility) // opt-in since M10
        XCTAssertFalse(o.debugLogging)
        XCTAssertNil(o.endpoint)
        XCTAssertEqual(o.testMode, .automatic)
    }

    /// The default cadence is build-configuration dependent, and until
    /// `swift test -c release` compiled (test gap 6) only the Debug half of it
    /// was ever asserted — the 4-hour Release default that M9's
    /// "retries exhausted" path exists to work around was pinned by nothing.
    func testFlushIntervalDefaultMatchesTheBuildConfiguration() {
        #if DEBUG
        XCTAssertEqual(BeaconstatOptions().flushInterval, 30)
        XCTAssertEqual(BeaconstatOptions.defaultFlushInterval, 30)
        #else
        XCTAssertEqual(BeaconstatOptions().flushInterval, 14_400)
        XCTAssertEqual(BeaconstatOptions.defaultFlushInterval, 14_400)
        #endif
        // Whatever the configuration, the default must survive `Configuration`'s
        // clamp untouched — a default outside its own limits would be absurd.
        XCTAssertTrue(BeaconstatOptions.Limits.flushInterval
            .contains(BeaconstatOptions.defaultFlushInterval))
    }

    func testEndpointIsOverridable() {
        var o = BeaconstatOptions()
        o.endpoint = URL(string: "http://localhost:3000")
        XCTAssertEqual(o.endpoint, URL(string: "http://localhost:3000"))
    }
}
