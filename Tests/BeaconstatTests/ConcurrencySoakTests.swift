import XCTest
@testable import Beaconstat

/// Test gap 8 — nothing hammered `track()` from N threads while flush, reconnect
/// and background transitions fired.
///
/// The review confirmed there are no data races and no double-send in the
/// checkout model **by reading the code**. That reading is correct, and it is
/// also the kind of correctness that a well-meaning refactor breaks silently:
/// move one line across the `queue_.checkout(batch.count)` call and the SDK
/// starts double-sending or dropping under load, with every existing test still
/// green because every existing test is single-threaded.
///
/// So this asserts the conservation law directly:
///
/// **events accepted == events delivered + events still queued**
///
/// Nothing may be invented (no event delivered twice) and nothing may vanish
/// (no event neither delivered nor queued). Every event carries a unique marker
/// so both directions are checkable, not just the counts.
///
/// This depends on test gap 9: `MockURLProtocol` stored its captures in
/// unsynchronised `static var`s appended from URLSession loading threads, and
/// split requests and bodies across two arrays that every helper indexed in
/// lockstep. Under genuine concurrency that is a data race and an index crash,
/// so this test could not have been written against the old harness.
final class ConcurrencySoakTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private let handshakeBody =
        Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8)

    private static let threads = 8
    private static let eventsPerThread = 250   // 2,000 events total

    /// Marker on every event, so delivered and queued events can be matched by
    /// identity rather than counted. `t3_117` — no risk of colliding with a
    /// session UUID.
    private static func marker(thread: Int, index: Int) -> String { "t\(thread)_\(index)" }

    private func core(file: URL, reachability: Reachability?,
                      observer: LifecycleObserver) -> BeaconstatCore {
        BeaconstatCore(store: InMemorySecureStore(),
                       clock: SystemClock(),
                       sessionProvider: { _ in .mocked() },
                       bundleIdentifier: "com.example.app",
                       queueFileURL: file,
                       reachabilityFactory: { _ in reachability },
                       lifecycleObserver: observer)
    }

    private func configure(_ c: BeaconstatCore, batchSize: Int) {
        var o = BeaconstatOptions()
        o.flushInterval = 5                     // the floor: the periodic timer fires during the soak
        o.batchSize = batchSize
        o.maxQueuedEvents = 10_000              // no eviction, so the law is exact
        o.maxRetries = 0
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: o, environment: ["device.platform": "ios"])
    }

    private func drain(_ c: BeaconstatCore, _ label: String, timeout: TimeInterval = 30) {
        let done = expectation(description: label); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: timeout)
    }

    /// Markers on the wire, across every captured batch. A marker appearing
    /// twice is a double-send.
    private func deliveredMarkers() -> [String] {
        SentBatch.allEvents().compactMap { $0["marker"] }
    }

    private func queuedMarkers(file: URL) -> [String] {
        FileEventStore(fileURL: file).load().compactMap { $0.properties?["marker"] }
    }

    // MARK: - The law

    /// 2,000 events from 8 threads, with the server accepting everything, while
    /// explicit flushes, reconnects and background transitions interleave.
    func testNothingIsLostOrDuplicatedUnderConcurrentTrackAndFlush() {
        MockURLProtocol.handler = { [handshakeBody] req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: handshakeBody)
                : .init(statusCode: 202)
        }
        let file = makeTemporaryQueueFile()
        let reachability = ManualReachability()
        let observer = LifecycleObserver()
        let c = core(file: file, reachability: reachability, observer: observer)
        configure(c, batchSize: 25)
        drain(c, "configured")

        DispatchQueue.concurrentPerform(iterations: Self.threads) { thread in
            for i in 0..<Self.eventsPerThread {
                c.track("feature_used", properties: ["marker": Self.marker(thread: thread, index: i)])
                // Interleave every trigger that can start or interrupt a flush.
                switch i % 50 {
                case 0:  c.flush()
                case 17: reachability.simulateReconnect()
                case 33: observer.onBackground?()
                case 41: observer.onForeground?()
                default: break
                }
            }
        }

        c.flush()
        drain(c, "soaked")
        // A background transition can leave a batch mid-flight; flush until the
        // queue stops shrinking rather than assuming one pass drains it.
        for _ in 0..<10 where !FileEventStore(fileURL: file).load().isEmpty {
            c.flush()
            drain(c, "draining")
        }

        let delivered = deliveredMarkers()
        let queued = queuedMarkers(file: file)
        let expected = Set((0..<Self.threads).flatMap { thread in
            (0..<Self.eventsPerThread).map { Self.marker(thread: thread, index: $0) }
        })

        // 1. Nothing delivered twice.
        XCTAssertEqual(delivered.count, Set(delivered).count,
                       "\(delivered.count - Set(delivered).count) event(s) were sent more than once")
        // 2. Nothing invented.
        XCTAssertTrue(Set(delivered).isSubset(of: expected), "an event appeared that was never tracked")
        // 3. Nothing lost: every accepted event is either delivered or still queued.
        let accountedFor = Set(delivered).union(queued)
        XCTAssertEqual(accountedFor, expected,
                       "\(expected.subtracting(accountedFor).count) event(s) vanished")
        // 4. And the headline conservation law, stated as the review asked.
        XCTAssertEqual(Set(delivered).count + Set(queued).subtracting(delivered).count,
                       expected.count)

        c.shutdown()
        drain(c, "shut down")
    }

    /// The same law under a server that keeps failing, so every batch takes the
    /// `release()` path instead of `acknowledge()`. This is where a checkout
    /// regression shows up as duplication rather than loss.
    func testNothingIsLostOrDuplicatedWhenEveryFlushFails() {
        MockURLProtocol.handler = { [handshakeBody] req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: handshakeBody)
                : .init(statusCode: 503)
        }
        let file = makeTemporaryQueueFile()
        let reachability = ManualReachability()
        let c = core(file: file, reachability: reachability, observer: LifecycleObserver())
        configure(c, batchSize: 10)
        drain(c, "configured")

        DispatchQueue.concurrentPerform(iterations: Self.threads) { thread in
            for i in 0..<100 {
                c.track("feature_used", properties: ["marker": Self.marker(thread: thread, index: i)])
                if i % 10 == 0 { c.flush() }
                if i % 25 == 0 { reachability.simulateReconnect() }
            }
        }
        c.flush()
        drain(c, "soaked")

        // Nothing was ever acknowledged, so everything must still be on disk,
        // exactly once each.
        let queued = queuedMarkers(file: file)
        let expected = Set((0..<Self.threads).flatMap { thread in
            (0..<100).map { Self.marker(thread: thread, index: $0) }
        })
        XCTAssertEqual(queued.count, Set(queued).count, "the queue duplicated events under retry")
        XCTAssertEqual(Set(queued), expected,
                       "\(expected.subtracting(Set(queued)).count) event(s) lost across failed flushes")
        c.shutdown()
        drain(c, "shut down")
    }

    /// Consent, hammered. `optOut()` mid-soak must stop collection, and nothing
    /// tracked after it may reach the wire — the property that matters legally,
    /// checked under the concurrency that makes it hard.
    func testOptOutDuringAConcurrentSoakLetsNothingThroughAfterwards() {
        MockURLProtocol.handler = { [handshakeBody] req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: handshakeBody)
                : .init(statusCode: 202)
        }
        let file = makeTemporaryQueueFile()
        let c = core(file: file, reachability: ManualReachability(), observer: LifecycleObserver())
        configure(c, batchSize: 20)
        drain(c, "configured")

        let optedOut = Locked(false)
        DispatchQueue.concurrentPerform(iterations: Self.threads) { thread in
            for i in 0..<200 {
                // One thread pulls the switch part-way through.
                if thread == 0 && i == 100 {
                    c.optOut()
                    optedOut.value = true
                }
                // Every event tracked after the switch is marked, so a leak is
                // identifiable rather than merely countable.
                let prefix = optedOut.value ? "after" : "before"
                c.track("feature_used", properties: ["marker": "\(prefix)_t\(thread)_\(i)"])
                if i % 25 == 0 { c.flush() }
            }
        }
        c.flush()
        drain(c, "soaked")

        let leaked = deliveredMarkers().filter { $0.hasPrefix("after") }
        XCTAssertTrue(leaked.isEmpty,
                      "\(leaked.count) event(s) tracked after optOut() reached the wire: "
                      + "\(leaked.prefix(5))")
        XCTAssertTrue(c.isOptedOut)
        // And the local queue was purged, so nothing waits to be sent at opt-in.
        XCTAssertTrue(FileEventStore(fileURL: file).load().isEmpty,
                      "events survived the opt-out purge")
        c.shutdown()
        drain(c, "shut down")
    }

    /// At most one batch may be in flight at a time, however many triggers
    /// coincide. Checked by making the server observe overlap directly rather
    /// than by inspecting the `flushing` flag.
    func testOnlyOneBatchIsEverInFlight() {
        let inFlight = Locked(0)
        let maxObserved = Locked(0)
        MockURLProtocol.handler = { [handshakeBody] req in
            guard !req.url!.path.hasSuffix("/handshake") else {
                return .init(statusCode: 200, data: handshakeBody)
            }
            let now = inFlight.value + 1
            inFlight.value = now
            if now > maxObserved.value { maxObserved.value = now }
            // Hold the "connection" open so an overlapping send would be visible.
            Thread.sleep(forTimeInterval: 0.002)
            inFlight.value -= 1
            return .init(statusCode: 202)
        }
        let file = makeTemporaryQueueFile()
        let reachability = ManualReachability()
        let c = core(file: file, reachability: reachability, observer: LifecycleObserver())
        configure(c, batchSize: 5)
        drain(c, "configured")

        DispatchQueue.concurrentPerform(iterations: Self.threads) { thread in
            for i in 0..<60 {
                c.track("feature_used", properties: ["marker": Self.marker(thread: thread, index: i)])
                c.flush()
                if i % 10 == 0 { reachability.simulateReconnect() }
            }
        }
        drain(c, "soaked")

        XCTAssertGreaterThan(maxObserved.value, 0, "no batch was ever sent, so nothing was proven")
        XCTAssertEqual(maxObserved.value, 1,
                       "\(maxObserved.value) batches were in flight at once — the flushing flag "
                       + "no longer serialises the timer, retry, reconnect, batch-size and drain "
                       + "triggers")
        c.shutdown()
        drain(c, "shut down")
    }
}
