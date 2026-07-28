import XCTest
@testable import Beaconstat

/// H3 — `dequeueBatch` took up to 100 events with no byte budget at all. At the
/// enforced property limits a batch could approach ~5 MB, which the ingest API
/// 413'd every single time.
///
/// The original 80 KB was sized against Express's 100 KB body-parser default,
/// which `apps/api` was inheriting silently. It now pins `JSON_BODY_LIMIT_BYTES`
/// at 256 KB, so the budget was re-derived — and deliberately left where it is.
/// `BudgetRationaleTests` at the bottom of this file is that derivation, kept as
/// executable assertions rather than a comment, so the next person to look at
/// the headroom finds the reasoning instead of just the number.
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

    func testDefaultBudgetLeavesHeadroomUnderTheApisBodyLimit() {
        XCTAssertLessThan(EventQueue.defaultMaxBatchBytes, BudgetRationaleTests.apiJSONBodyLimitBytes)
        XCTAssertGreaterThan(EventQueue.defaultMaxBatchBytes, EventQueue.maxEventBytes)
    }
}

/// Why the batch budget is 80 KB and not something larger, as tests.
///
/// The ingest API moved its JSON body limit from an inherited 100 KB to a
/// pinned 256 KB, which looks like an invitation to raise this. It is not, and
/// the reasons are checkable, so they are checked. Every assertion here is a
/// claim that would have to stop being true before raising the budget made
/// sense — if one of them goes red, reopen the decision rather than adjusting
/// the number to match.
final class BudgetRationaleTests: XCTestCase {
    /// `JSON_BODY_LIMIT_BYTES` in `apps/api/src/config/body-parser.config.ts`.
    /// Mirrored, like `SDK_MAX_BATCH_BYTES` is mirrored on the API side, so
    /// the relationship is asserted from both ends of a boundary that spans two
    /// repositories.
    static let apiJSONBodyLimitBytes = 256 * 1024
    /// body-parser's default, which any self-hosted or proxied deployment in
    /// front of the API is liable to still have.
    static let ubiquitousDefaultBodyLimitBytes = 100 * 1024

    private func log() -> Logger { Logger(enabled: false, sink: { _ in }) }
    private func queue() -> EventQueue {
        EventQueue(store: NullEventStore(), maxQueued: 5_000, logger: log())
    }
    private func encodedWireSize(_ events: [Event], environment: [String: String]) throws -> Int {
        try PayloadEncoder.encode(EventBatch(productVersion: "1.2.3",
                                             environment: environment, events: events)).count
    }
    /// A realistic default-configuration environment map, collected rather than
    /// hand-written, so a future key addition shows up here.
    @MainActor private func realEnvironment() -> [String: String] {
        let collector = EnvironmentCollector(sdkVersion: BeaconstatVersion.current,
                                             appVersion: "1.2.3", appBuild: "456",
                                             collectAccessibility: false)
        var environment = collector.collectDeferrable()
        environment.merge(EnvironmentCollector
            .collectMainThreadOnly(collectAccessibility: false)) { _, new in new }
        return environment
    }
    private func typicalEvent() -> Event {
        Event(name: "checkout_completed", time: "2026-04-19T10:30:00.000Z",
              properties: ["_bcs.session.id": "3f2504e0-4f89-11d3-9a0c-0305e82c3301"])
    }
    /// A property-heavy but unremarkable event: eight 40-character values.
    private func propertyHeavyEvent() -> Event {
        var properties = ["_bcs.session.id": "3f2504e0-4f89-11d3-9a0c-0305e82c3301"]
        for i in 0..<8 { properties["property_number_\(i)"] = String(repeating: "v", count: 40) }
        return Event(name: "some_reasonably_named_event",
                     time: "2026-04-19T10:30:00.000Z", properties: properties)
    }
    /// The largest event the server will accept: 50 property keys at 1024 chars.
    private func maximalLegalEvent() -> Event {
        var properties: [String: String] = [:]
        for i in 0..<50 { properties["k\(i)"] = String(repeating: "v", count: 1024) }
        return Event(name: "maximal", time: "2026-04-19T10:30:00.000Z", properties: properties)
    }

    /// Reason 1: for realistic traffic the byte budget never binds — the
    /// server's 100-event cap does. A full batch of typical events is a small
    /// fraction of the budget, so raising it would not admit one more event.
    @MainActor
    func testAFullBatchOfTypicalEventsIsNowhereNearTheBudget() throws {
        let environment = realEnvironment()
        let body = try encodedWireSize(Array(repeating: typicalEvent(), count: 100), environment: environment)
        XCTAssertLessThan(body, EventQueue.defaultMaxBatchBytes / 2,
                          "100 typical events came to \(body) bytes")
    }

    /// The same for a property-heavy event. Still under budget, still capped by
    /// event count rather than bytes.
    @MainActor
    func testAFullBatchOfPropertyHeavyEventsStillFitsTheBudget() throws {
        let environment = realEnvironment()
        let body = try encodedWireSize(Array(repeating: propertyHeavyEvent(), count: 100),
                                       environment: environment)
        XCTAssertLessThan(body, EventQueue.defaultMaxBatchBytes,
                          "100 property-heavy events came to \(body) bytes")
    }

    /// Stated as the threshold itself: bytes only become the binding constraint
    /// above ~810 bytes per event, which is far above anything the SDK emits.
    @MainActor
    func testTheEventCountCapBindsBeforeTheByteBudgetForAnythingTypical() throws {
        let environment = realEnvironment()
        let budget = EventQueue.defaultMaxBatchBytes - (try JSONEncoder().encode(environment).count)
        let crossoverBytesPerEvent = budget / EventQueue.maxEventsPerBatch
        let typicalBytesPerEvent = try encodedWireSize([typicalEvent()], environment: [:])
        XCTAssertGreaterThan(crossoverBytesPerEvent, typicalBytesPerEvent * 4,
                             "crossover \(crossoverBytesPerEvent) B/event vs typical \(typicalBytesPerEvent)")
    }

    /// Reason 2: the budget's real job is to clear the single-event ceiling, and
    /// it does so with room to spare. A maximal legal event is well under both
    /// `maxEventBytes` and the budget, so a larger budget unlocks no event that
    /// is currently refused — `maxEventBytes` is a separate, fixed constant.
    func testTheBudgetClearsAMaximalLegalEventWithRoomToSpare() throws {
        let encoded = try JSONEncoder().encode(maximalLegalEvent()).count
        XCTAssertLessThan(encoded, EventQueue.maxEventBytes, "maximal legal event: \(encoded) bytes")
        XCTAssertGreaterThan(EventQueue.defaultMaxBatchBytes - encoded, 16 * 1024)
    }

    /// Reason 3: 256 KB is the API's deliberate margin. Its own test asserts the
    /// limit is at least twice the SDK's ceiling, so raising this past 128 KB
    /// would turn `apps/api/src/config/body-parser.config.spec.ts` red — the
    /// coupling that pinning the limit was meant to remove, rebuilt.
    func testTheBudgetStaysInsideTheMarginTheAPIDeliberatelyBought() {
        XCTAssertLessThanOrEqual(EventQueue.defaultMaxBatchBytes * 2, Self.apiJSONBodyLimitBytes,
                                 "apps/api asserts JSON_BODY_LIMIT_BYTES >= SDK_MAX_BATCH_BYTES * 2")
    }

    /// Reason 4: `endpoint` is host-overridable, so the thing that answers may
    /// be a proxy or a self-hosted build still on body-parser's 100 KB default.
    /// Staying under it means the first batch lands rather than converging
    /// through the 413 shrink path.
    @MainActor
    func testTheWorstCaseBodyStaysUnderTheUbiquitousHundredKilobyteDefault() throws {
        let environment = realEnvironment()
        let budget = EventQueue.defaultMaxBatchBytes - (try JSONEncoder().encode(environment).count)
        // Fill with events just under the per-event ceiling so selection stops
        // on bytes, not on the 100-event cap — the genuine worst case.
        let q = queue()
        for _ in 0..<20 {
            q.enqueue(Event(name: "big", time: "2026-04-19T10:30:00.000Z",
                            properties: ["p": String(repeating: "x", count: 20_000)]))
        }
        let selected = q.nextBatch(max: EventQueue.maxEventsPerBatch, maxBytes: budget)
        XCTAssertGreaterThan(selected.count, 1, "the byte budget must be what stopped selection")
        let body = try encodedWireSize(selected, environment: environment)
        XCTAssertLessThan(body, Self.ubiquitousDefaultBodyLimitBytes,
                          "worst-case body \(body) bytes must clear body-parser's default")
    }

    /// And the shrink path still terminates against the tightest limit the SDK
    /// tolerates: halving from the default reaches the floor in a bounded number
    /// of steps rather than asymptotically.
    func testHalvingFromTheDefaultReachesTheFloorInABoundedNumberOfSteps() {
        var budget = EventQueue.defaultMaxBatchBytes
        var steps = 0
        while budget > EventQueue.minimumBatchBytes && steps < 100 {
            budget = max(EventQueue.minimumBatchBytes, budget / 2)
            steps += 1
        }
        XCTAssertEqual(budget, EventQueue.minimumBatchBytes)
        XCTAssertLessThanOrEqual(steps, 6, "took \(steps) halvings to reach the floor")
    }
}

/// Discards everything. The rationale tests exercise selection, not durability.
private final class NullEventStore: EventStore {
    func load() -> [Event] { [] }
    @discardableResult func save(_ events: [Event]) -> Bool { true }
}
