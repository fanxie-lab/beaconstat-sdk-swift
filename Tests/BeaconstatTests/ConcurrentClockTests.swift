import XCTest
@testable import Beaconstat

/// `SystemClock.formatter` is a `nonisolated(unsafe) static let` (M13).
///
/// That annotation is a promise: `ISO8601DateFormatter` is configured exactly
/// once and is safe to *use* from multiple threads. The promise is load-bearing
/// — `nowISO8601()` runs on the enqueue path for every event, so making it
/// per-call or lock-serialised would cost real time — and it is the kind of
/// promise that rots silently, because a formatter that is not thread-safe does
/// not crash, it returns a corrupted string.
///
/// So: hammer it. Every timestamp produced concurrently must be a well-formed
/// ISO 8601 instant that round-trips back to the date it came from.
final class ConcurrentClockTests: XCTestCase {
    private static let threads = 8
    private static let iterations = 500

    func testTimestampsAreWellFormedUnderConcurrentFormatting() {
        let clock = SystemClock()
        let results = Results()

        DispatchQueue.concurrentPerform(iterations: Self.threads) { thread in
            for i in 0..<Self.iterations {
                // A distinct instant per (thread, iteration), so a torn read
                // shows up as a value that does not round-trip rather than as a
                // coincidentally-correct one.
                let date = Date(timeIntervalSince1970: 1_776_580_200 + Double(thread) + Double(i) / 1000)
                results.record(clock.iso8601(date), for: date)
            }
        }

        XCTAssertEqual(results.count, Self.threads * Self.iterations)
        XCTAssertTrue(results.mismatches.isEmpty,
                      "\(results.mismatches.count) timestamp(s) did not round-trip; the first few: "
                      + "\(results.mismatches.prefix(5))")
    }

    /// The skew correction is guarded by `SystemClock`'s own lock. Reading the
    /// clock while another thread applies server time must never produce a
    /// malformed value.
    func testApplyingServerTimeConcurrentlyWithReadsStaysWellFormed() {
        let clock = SystemClock()
        let malformed = Counter()

        DispatchQueue.concurrentPerform(iterations: Self.threads) { thread in
            for i in 0..<Self.iterations {
                if thread == 0 {
                    clock.applyServerTime("2026-04-19T10:30:0\(i % 10).000Z")
                } else {
                    let stamp = clock.nowISO8601()
                    if !Self.isWellFormed(stamp) { malformed.increment() }
                }
            }
        }
        XCTAssertEqual(malformed.value, 0)
    }

    private static func isWellFormed(_ stamp: String) -> Bool {
        // `2026-04-19T10:30:00.000Z` — fixed width, fixed separators, and it
        // must parse back.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return stamp.count == 24 && stamp.hasSuffix("Z") && formatter.date(from: stamp) != nil
    }

    /// Collects from many threads; `XCTAssert` itself is not the thing under
    /// test, so keep it off the hot loop.
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = 0
        private var bad: [String] = []

        var count: Int { lock.lock(); defer { lock.unlock() }; return seen }
        var mismatches: [String] { lock.lock(); defer { lock.unlock() }; return bad }

        func record(_ stamp: String, for date: Date) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(identifier: "UTC")
            let roundTripped = formatter.date(from: stamp)
            let ok = ConcurrentClockTests.isWellFormed(stamp)
                && roundTripped.map { abs($0.timeIntervalSince(date)) < 0.001 } == true
            lock.lock(); defer { lock.unlock() }
            seen += 1
            if !ok { bad.append(stamp) }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
}
