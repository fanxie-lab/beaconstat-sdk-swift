import XCTest
@testable import Beaconstat

/// M8 — overflow dropped from the front, and `_bcs.install_detected` /
/// `_bcs.session_started` are enqueued first, so an offline chatty session lost
/// exactly the events that matter and kept arbitrary custom ones.
final class EventQueueEvictionTests: XCTestCase {
    private final class MemStore: EventStore {
        var events: [Event] = []
        func load() -> [Event] { events }
        @discardableResult
        func save(_ e: [Event]) -> Bool { events = e; return true }
    }
    private func log() -> Logger { Logger(enabled: false, sink: { _ in }) }
    private func ev(_ n: Int) -> Event { Event(name: "e\(n)", time: "t\(n)") }
    private func install() -> Event { Event(name: "_bcs.install_detected", time: "t0") }
    private func session(_ n: Int = 0) -> Event { Event(name: "_bcs.session_started", time: "s\(n)") }
    private func updated() -> Event { Event(name: "_bcs.apple.app_updated", time: "u0") }

    private func queue(maxQueued: Int, logger: Logger? = nil) -> EventQueue {
        EventQueue(store: MemStore(), maxQueued: maxQueued, logger: logger ?? log())
    }

    /// The review's headline scenario: a first launch offline, then a chatty
    /// session. The launch events are at the front, so front-eviction ate them.
    func testInstallAndSessionSurviveAChattyOfflineSession() {
        let q = queue(maxQueued: 5)
        q.enqueue(session())
        q.enqueue(install())
        for i in 1...20 { q.enqueue(ev(i)) }

        let names = q.nextBatch(max: 100).map(\.name)
        XCTAssertEqual(q.count, 5)
        XCTAssertTrue(names.contains("_bcs.session_started"), "session_started evicted: \(names)")
        XCTAssertTrue(names.contains("_bcs.install_detected"), "install_detected evicted: \(names)")
    }

    /// `_bcs.apple.app_updated` is the same class of event — exactly once per
    /// version transition, and unreconstructable once dropped.
    func testAppUpdatedIsProtectedToo() {
        let q = queue(maxQueued: 3)
        q.enqueue(updated())
        for i in 1...10 { q.enqueue(ev(i)) }
        XCTAssertTrue(q.nextBatch(max: 100).contains { $0.name == "_bcs.apple.app_updated" })
    }

    /// Ordinary events still evict oldest-first — the protection reorders which
    /// events are candidates, not the order among them.
    func testOrdinaryEventsStillEvictOldestFirst() {
        let q = queue(maxQueued: 3)
        for i in 1...5 { q.enqueue(ev(i)) }
        XCTAssertEqual(q.nextBatch(max: 100), [ev(3), ev(4), ev(5)])
    }

    /// Protection must not reorder the survivors.
    func testEvictionPreservesRelativeOrder() {
        let q = queue(maxQueued: 4)
        q.enqueue(ev(1))
        q.enqueue(install())
        q.enqueue(ev(2))
        q.enqueue(session())
        q.enqueue(ev(3))
        q.enqueue(ev(4))
        XCTAssertEqual(q.nextBatch(max: 100).map(\.name),
                       ["_bcs.install_detected", "_bcs.session_started", "e3", "e4"])
    }

    /// Protection cannot be absolute or the queue grows without bound. When
    /// there is nothing else left to drop, protected events evict oldest-first.
    func testProtectionFallsBackWhenEverythingIsProtected() {
        let q = queue(maxQueued: 3)
        for i in 1...6 { q.enqueue(session(i)) }
        XCTAssertEqual(q.count, 3, "the cap must still hold")
        XCTAssertEqual(q.nextBatch(max: 100).map(\.time), ["s4", "s5", "s6"])
    }

    /// The successor to `testPrependBeyondCapDropsOldest`, which pinned the old
    /// contract: a batch being retried was the *preferred* casualty of the next
    /// overflow. It is now in-flight, so it is not an eviction candidate at all.
    func testInFlightBatchIsNeverEvicted() {
        let q = queue(maxQueued: 3)
        for i in 4...6 { q.enqueue(ev(i)) }        // [4,5,6]
        q.checkout(q.nextBatch(max: 2).count)      // in flight: [4,5]; pending: [6]
        q.enqueue(ev(7))
        q.enqueue(ev(8))                           // over cap -> evict from pending only
        q.release()                                // 5xx: the batch comes back

        let names = q.nextBatch(max: 100).map(\.name)
        XCTAssertTrue(names.contains("e4"), "the retried batch was evicted: \(names)")
        XCTAssertTrue(names.contains("e5"), "the retried batch was evicted: \(names)")
        XCTAssertEqual(Array(names[0..<2]), ["e4", "e5"], "and it stays at the front")
    }

    /// The cap bounds TOTAL residency, and in-flight events are resident, so
    /// protecting them costs pending capacity rather than raising the ceiling.
    func testCapCountsInFlightEventsAndIsStillHonoured() {
        let q = queue(maxQueued: 3)
        for i in 1...3 { q.enqueue(ev(i)) }
        q.checkout(q.nextBatch(max: 2).count)
        for i in 4...50 { q.enqueue(ev(i)) }
        XCTAssertEqual(q.inFlightCount, 2)
        XCTAssertEqual(q.count, 3, "the cap still holds while a batch is in flight")
        XCTAssertEqual(q.pendingCount, 1)
    }

    /// The only case that can exceed the cap is an in-flight batch larger than
    /// the cap itself — the alternative would be evicting events that are on
    /// the wire right now. Bounded by one batch, and it resolves on ack.
    func testOvershootIsBoundedByASingleInFlightBatch() {
        let q = queue(maxQueued: 5)
        for i in 1...5 { q.enqueue(ev(i)) }
        q.checkout(q.nextBatch(max: 5).count)      // all 5 in flight
        q.setMaxQueued(1)                          // host reconfigures downwards
        for i in 6...50 { q.enqueue(ev(i)) }
        XCTAssertEqual(q.inFlightCount, 5, "events on the wire are never evicted")
        XCTAssertEqual(q.pendingCount, 0, "pending gave everything it had")
        q.acknowledge()
        q.enqueue(ev(99))
        XCTAssertEqual(q.count, 1, "and the cap reasserts itself the moment the batch lands")
    }

    /// Lowering the cap on reconfigure uses the same policy.
    func testSetMaxQueuedIsAlsoPriorityAware() {
        let q = queue(maxQueued: 100)
        q.enqueue(install())
        for i in 1...10 { q.enqueue(ev(i)) }
        q.setMaxQueued(2)
        XCTAssertEqual(q.count, 2)
        XCTAssertTrue(q.nextBatch(max: 100).contains { $0.name == "_bcs.install_detected" })
    }

    func testEvictionIsLogged() {
        let collector = LogCollector()
        let q = queue(maxQueued: 2, logger: Logger(enabled: true, sink: collector.append))
        for i in 1...5 { q.enqueue(ev(i)) }
        XCTAssertTrue(collector.contains("dropped"), "expected an eviction log: \(collector.lines)")
    }

    func testDroppingProtectedEventsSaysSoDistinctly() {
        let collector = LogCollector()
        let q = queue(maxQueued: 1, logger: Logger(enabled: true, sink: collector.append))
        q.enqueue(session(1))
        q.enqueue(session(2))
        XCTAssertTrue(collector.contains("high-value"),
                      "dropping a protected event deserves its own line: \(collector.lines)")
    }
}
