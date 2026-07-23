import XCTest
@testable import Beaconstat

final class SessionManagerTests: XCTestCase {
    private final class MutableClock: Clock {
        var date: Date
        init(_ d: Date) { date = d }
        func now() -> Date { date }
        func nowISO8601() -> String { iso8601(date) }
        func iso8601(_ d: Date) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: d)
        }
        func applyServerTime(_ iso: String) {}
    }

    func testFirstSessionIsMarkedFirstOnce() {
        let store = InMemorySecureStore()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let sm = SessionManager(store: store, clock: clock, timeout: 300)
        let first = sm.startIfNeeded()
        XCTAssertNotNil(first)
        XCTAssertTrue(first!.isFirst)
        XCTAssertNil(first!.previousAt)

        // A brand-new manager (cold relaunch) → new session, but NOT first anymore.
        let sm2 = SessionManager(store: store, clock: clock, timeout: 300)
        let second = sm2.startIfNeeded()
        XCTAssertNotNil(second)
        XCTAssertFalse(second!.isFirst)
        // Second session's previousAt = the first session's start time (clock unchanged here).
        XCTAssertEqual(second!.previousAt, clock.iso8601(Date(timeIntervalSince1970: 1_000_000)))
        XCTAssertNotEqual(second!.id, first!.id)
    }

    func testSameSessionWithinTimeout() {
        let store = InMemorySecureStore()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let sm = SessionManager(store: store, clock: clock, timeout: 300)
        let a = sm.startIfNeeded()
        clock.date = clock.date.addingTimeInterval(120) // < timeout
        let b = sm.startIfNeeded()
        XCTAssertNil(b) // no new session
        XCTAssertEqual(sm.currentSessionId(), a!.id)
    }

    func testNewSessionAfterTimeout() {
        let store = InMemorySecureStore()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let sm = SessionManager(store: store, clock: clock, timeout: 300)
        let a = sm.startIfNeeded()
        clock.date = clock.date.addingTimeInterval(301) // > timeout
        let b = sm.startIfNeeded()
        XCTAssertNotNil(b)
        XCTAssertNotEqual(b!.id, a!.id)
        // New session after timeout carries the prior session's start time.
        XCTAssertEqual(b!.previousAt, clock.iso8601(Date(timeIntervalSince1970: 1_000_000)))
    }
}
