import XCTest
@testable import Beaconstat

/// H3 — `dequeueBatch` took up to 100 events with no byte budget at all. At the
/// enforced property limits a batch could approach ~5 MB, and the reference
/// ingest API runs on Express's default 100 KB body-parser limit, so a full
/// batch of large events is 413'd every single time.
final class EventQueueByteBudgetTests: XCTestCase {
    private final class MemStore: EventStore {
        var events: [Event] = []
        func load() -> [Event] { events }
        @discardableResult
        func save(_ e: [Event]) -> Bool { events = e; return true }
    }
    private func log() -> Logger { Logger(enabled: false, sink: { _ in }) }
    private func queue(maxQueued: Int = 5000, logger: Logger? = nil) -> EventQueue {
        EventQueue(store: MemStore(), maxQueued: maxQueued, logger: logger ?? log())
    }
    /// ~`bytes` of payload in a single property value.
    private func bigEvent(_ name: String, bytes: Int) -> Event {
        Event(name: name, time: "t", properties: ["p": String(repeating: "x", count: bytes)])
    }

    func testBatchStopsAtTheByteBudget() {
        let q = queue()
        for i in 1...20 { q.enqueue(bigEvent("e\(i)", bytes: 1000)) }
        let batch = q.nextBatch(max: 100, maxBytes: 5_000)
        XCTAssertGreaterThan(batch.count, 0)
        XCTAssertLessThan(batch.count, 20, "the budget must actually bite")
        let encoded = try? JSONEncoder().encode(batch)
        XCTAssertLessThanOrEqual((encoded?.count ?? .max), 6_500, "roughly within budget")
    }

    func testCountLimitStillAppliesUnderAGenerousBudget() {
        let q = queue()
        for i in 1...150 { q.enqueue(Event(name: "e\(i)", time: "t")) }
        XCTAssertEqual(q.nextBatch(max: 100, maxBytes: 10_000_000).count,
                       EventQueue.maxEventsPerBatch)
    }

    /// The wedge case: if a batch that overshoots the budget returned empty,
    /// the head event could never be selected and nothing behind it would ever
    /// send. One event over budget goes out alone; the server's 413 handling
    /// then decides its fate.
    func testAnEventLargerThanTheBudgetIsStillSentAlone() {
        let q = queue()
        q.enqueue(bigEvent("huge", bytes: 8_000))
        q.enqueue(Event(name: "after", time: "t"))
        let batch = q.nextBatch(max: 100, maxBytes: 1_000)
        XCTAssertEqual(batch.count, 1, "never return empty while something is pending")
        XCTAssertEqual(batch.first?.name, "huge")
    }

    /// ...and it does not drag its neighbours with it.
    func testAnOverBudgetHeadEventDoesNotPullInFollowers() {
        let q = queue()
        q.enqueue(bigEvent("huge", bytes: 8_000))
        for i in 1...5 { q.enqueue(Event(name: "e\(i)", time: "t")) }
        XCTAssertEqual(q.nextBatch(max: 100, maxBytes: 1_000).map(\.name), ["huge"])
    }

    /// An event that could never fit in ANY batch is refused at the door rather
    /// than parked at the front of the queue forever. This is the absolute
    /// ceiling, deliberately independent of the adaptive per-batch budget, so a
    /// 413-driven shrink can never start discarding legitimate events.
    func testAnEventOverTheAbsoluteCeilingIsNeverQueued() {
        let collector = LogCollector()
        let q = queue(logger: Logger(enabled: true, sink: collector.append))
        q.enqueue(bigEvent("monstrous", bytes: EventQueue.maxEventBytes + 1_000))
        q.enqueue(Event(name: "ordinary", time: "t"))
        XCTAssertEqual(q.nextBatch(max: 100, maxBytes: 1_000_000).map(\.name), ["ordinary"])
        XCTAssertTrue(collector.contains("too large"), "\(collector.lines)")
    }

    /// The ceiling has to leave room for a legitimately maximal event: the
    /// server accepts 50 property keys at 1024 chars each.
    func testTheCeilingAcceptsAMaximalLegitimateEvent() {
        var properties: [String: String] = [:]
        for i in 0..<50 { properties["k\(i)"] = String(repeating: "v", count: 1024) }
        let q = queue()
        q.enqueue(Event(name: "maximal", time: "2026-04-19T10:30:00.000Z", properties: properties))
        XCTAssertEqual(q.nextBatch(max: 100, maxBytes: 1_000_000).count, 1,
                       "a maximal but legal event must not be refused")
    }

    func testDefaultBudgetLeavesHeadroomUnderTheApisHundredKilobyteLimit() {
        XCTAssertLessThan(EventQueue.defaultMaxBatchBytes, 100 * 1024)
        XCTAssertGreaterThan(EventQueue.defaultMaxBatchBytes, EventQueue.maxEventBytes)
    }
}
