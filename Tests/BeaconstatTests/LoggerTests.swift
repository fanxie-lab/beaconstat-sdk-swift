import XCTest
@testable import Beaconstat

final class LoggerTests: XCTestCase {
    func testDisabledLoggerDoesNotEmit() {
        var lines: [String] = []
        let log = Logger(enabled: false, sink: { lines.append($0) })
        log.debug("hidden")
        XCTAssertTrue(lines.isEmpty)
    }

    func testEnabledLoggerEmits() {
        var lines: [String] = []
        let log = Logger(enabled: true, sink: { lines.append($0) })
        log.debug("shown")
        XCTAssertEqual(lines, ["shown"])
    }
}
