import XCTest
@testable import Beaconstat

final class BeaconstatCoreSessionTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    // Collect every event JSON sent to the events endpoint.
    private func sentEventBodies() -> [String] {
        MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events") ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }
    }

    private func core(file: URL) -> BeaconstatCore {
        BeaconstatCore(store: InMemorySecureStore(),
                       clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_580_200) }),
                       sessionProvider: { _ in .mocked() },
                       bundleIdentifier: "com.example.app", queueFileURL: file)
    }

    func testSessionStartedAndInstallAreTaggedAndFirst() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var opts = BeaconstatOptions(); opts.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: opts, environment: ["device.platform": "ios"])
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        let all = sentEventBodies().joined()
        XCTAssertTrue(all.contains("_bcs.session_started"))
        XCTAssertTrue(all.contains("_bcs.install_detected"))
        XCTAssertTrue(all.contains("_bcs.is_first_session"))
        XCTAssertTrue(all.contains("_bcs.session.id"))
    }

    func testTrackValidatesAndTagsUserEvents() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var opts = BeaconstatOptions(); opts.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: opts, environment: ["device.platform": "ios"])
        c.track("feature_used", properties: ["feature": "export"]) // valid
        c.track("_bcs.hack", properties: [:])                       // invalid: reserved prefix → dropped
        c.track("Bad Name", properties: [:])                        // invalid: regex → dropped
        c.flush()
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        let all = sentEventBodies().joined()
        XCTAssertTrue(all.contains("feature_used"))
        XCTAssertFalse(all.contains("_bcs.hack"))
        XCTAssertFalse(all.contains("Bad Name"))
        // The user event carries a session id.
        XCTAssertTrue(all.contains("_bcs.session.id"))
    }

    func testOversizedPropertyValueIsDropped() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var opts = BeaconstatOptions(); opts.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: opts, environment: ["device.platform": "ios"])
        let oversized = String(repeating: "x", count: 2000)
        c.track("feature_used", properties: ["ok": "v", "big": oversized])
        c.flush()
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        let all = sentEventBodies().joined()
        XCTAssertTrue(all.contains("feature_used"))
        XCTAssertTrue(all.contains("\"ok\""))
        XCTAssertFalse(all.contains(oversized))
    }

    func testInstallEventOmitsInstallSource() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var opts = BeaconstatOptions(); opts.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: opts, environment: ["device.platform": "ios"])
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        let all = sentEventBodies().joined()
        XCTAssertTrue(all.contains("_bcs.install_detected"))
        XCTAssertTrue(all.contains("_bcs.session.id"))
        XCTAssertFalse(all.contains("install.source"))
    }

    func testPropertyCountCappedAtFifty() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var opts = BeaconstatOptions(); opts.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: opts, environment: ["device.platform": "ios"])
        var props: [String: String] = [:]
        for i in 0..<60 { props["k\(i)"] = "v\(i)" }
        c.track("feature_used", properties: props)
        c.flush()
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        guard let body = sentEventBodies().first(where: { $0.contains("feature_used") }),
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]],
              let event = events.first(where: { ($0["name"] as? String) == "feature_used" }),
              let eventProps = event["properties"] as? [String: Any] else {
            XCTFail("could not locate feature_used event properties in sent body")
            return
        }
        // +1 for the injected _bcs.session.id, capped at 49 user keys.
        XCTAssertLessThanOrEqual(eventProps.count, 50)
    }

    func testOptedOutSendsNothing() {
        MockURLProtocol.handler = { _ in .init(statusCode: 200) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = InMemorySecureStore(); store.set("1", forKey: .optedOut)
        let c = BeaconstatCore(store: store,
                               clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_580_200) }),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app", queueFileURL: file)
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: BeaconstatOptions(), environment: [:])
        c.track("feature_used", properties: [:])
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty) // opt-out: no handshake, no events
    }

    func testOptOutPurgesQueueAndSilencesFurtherSends() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 503) // events stay queued
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: o, environment: ["device.platform": "ios"])
        let first = expectation(description: "first"); c.onQuiescent { first.fulfill() }
        wait(for: [first], timeout: 3)
        XCTAssertFalse(FileEventStore(fileURL: file).load().isEmpty) // events queued (503)

        c.optOut()
        c.track("feature_used", properties: [:])
        let second = expectation(description: "second"); c.onQuiescent { second.fulfill() }
        wait(for: [second], timeout: 3)
        XCTAssertTrue(FileEventStore(fileURL: file).load().isEmpty) // purged; nothing new queued
    }

    /// Reproduces the in-flight-flush race: a batch is checked out and sent
    /// (network call outstanding, queue file already rewritten without it) when
    /// `optOut()` runs. The purge sees an already-empty queue, but the danger is
    /// the *completion* of that outstanding send resurrecting the batch via
    /// `prepend` once it fires. Proves the events never reappear on disk.
    ///
    /// IMPORTANT: `onQuiescent` now waits for all in-flight network ops to drain
    /// (deterministic — see `outstandingNetworkOps` in BeaconstatCore), so it must
    /// NEVER be called while the held `/events` response is still unreleased —
    /// that would hang until the 3s expectation timeout. The sync point for
    /// "opt-out landed before the completion" isn't a wall-clock wait at all: it
    /// falls out of `queue` being a *serial* FIFO queue — `optOut()`'s `queue.async`
    /// block is enqueued (from this test's call below) strictly before the held
    /// send's completion handler can even be scheduled (that can't happen until
    /// after `releaseHeldEventsRequest()` unblocks the parked response), so the
    /// purge is always ordered ahead of the completion's opt-out-discard check.
    func testOptOutDiscardsInFlightBatch() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 503) // retryable failure -> would prepend() pre-fix
        }
        MockURLProtocol.holdEventsUntilReleased = true
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: o, environment: ["device.platform": "ios"])

        // The install-detected flush fires its /events send immediately; block
        // (on the mock's own semaphore, NOT onQuiescent) until that request is
        // in flight (batch already dequeued) but its response is parked.
        MockURLProtocol.waitForHeldEventsRequest()

        // Opt out while the batch is checked out and in flight. This enqueues the
        // purge onto the serial queue now — before the held completion can even
        // be scheduled — so ordering (not timing) guarantees it runs first.
        c.optOut()

        // Release the parked 503. Pre-fix, its re-hop onto the serial queue would
        // call queue_?.prepend(batch), resurrecting the purged events; the
        // opted-out guard (running after the purge, by construction above) must
        // discard it instead.
        MockURLProtocol.releaseHeldEventsRequest()

        // Only now is it safe to ask for quiescence: the held op has been
        // released, so it will actually drain instead of blocking the poll.
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(FileEventStore(fileURL: file).load().isEmpty) // still empty: batch discarded, not resurrected
    }
}
