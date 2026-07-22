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
        XCTAssertTrue(o.collectAccessibility)
        XCTAssertFalse(o.debugLogging)
        XCTAssertNil(o.endpoint)
        XCTAssertEqual(o.testMode, .automatic)
    }

    func testFlushIntervalIsThirtySecondsUnderDebug() {
        // `swift test` builds the DEBUG configuration.
        XCTAssertEqual(BeaconstatOptions().flushInterval, 30)
        XCTAssertEqual(BeaconstatOptions.defaultFlushInterval, 30)
    }

    func testEndpointIsOverridable() {
        var o = BeaconstatOptions()
        o.endpoint = URL(string: "http://localhost:3000")
        XCTAssertEqual(o.endpoint, URL(string: "http://localhost:3000"))
    }
}
