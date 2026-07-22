import XCTest
@testable import Beaconstat

final class ClockTests: XCTestCase {
    private let fixed = Date(timeIntervalSince1970: 1_776_594_600) // 2026-04-19T10:30:00Z

    func testISO8601IsUTCMillisecondZulu() {
        let clock = SystemClock(dateProvider: { self.fixed })
        XCTAssertEqual(clock.nowISO8601(), "2026-04-19T10:30:00.000Z")
    }

    func testSkewFromServerTimeCorrectsNow() {
        // Device is 120s behind the server.
        let clock = SystemClock(dateProvider: { self.fixed })
        clock.applyServerTime("2026-04-19T10:32:00.000Z")
        XCTAssertEqual(clock.now().timeIntervalSince1970,
                       self.fixed.timeIntervalSince1970 + 120, accuracy: 0.001)
        XCTAssertEqual(clock.nowISO8601(), "2026-04-19T10:32:00.000Z")
    }

    func testInvalidServerTimeIsIgnored() {
        let clock = SystemClock(dateProvider: { self.fixed })
        clock.applyServerTime("not-a-date")
        XCTAssertEqual(clock.nowISO8601(), "2026-04-19T10:30:00.000Z")
    }
}
