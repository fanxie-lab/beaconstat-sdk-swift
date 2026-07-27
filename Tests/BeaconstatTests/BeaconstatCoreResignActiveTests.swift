import XCTest
@testable import Beaconstat

/// M3 — the core half of the macOS mapping: a resign-active signal must flush
/// what is queued and emit nothing, and a repeated background signal (hide then
/// quit) must not double-report the departure.
final class BeaconstatCoreResignActiveTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func tempQueue() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
    }

    private func handshake202() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
    }

    private func core(file: URL, observer: LifecycleObserver) -> BeaconstatCore {
        BeaconstatCore(store: InMemorySecureStore(),
                       clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
                       sessionProvider: { _ in .mocked() },
                       bundleIdentifier: "com.example.app", sdkVersion: "9.9.9",
                       queueFileURL: file, reachabilityFactory: { _ in nil },
                       lifecycleObserver: observer)
    }

    private func configure(_ c: BeaconstatCore, flushOnBackground: Bool = true) {
        var o = BeaconstatOptions()
        o.flushInterval = 3600
        o.batchSize = 10_000 // never trip the size trigger; drive flushes explicitly
        o.flushOnBackground = flushOnBackground
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: o, environment: ["device.platform": "macos"])
    }

    private func drain(_ c: BeaconstatCore, _ label: String = "flow") {
        let done = expectation(description: label); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func sentEventNames() -> [String] {
        var names: [String] = []
        for (i, req) in MockURLProtocol.capturedRequests.enumerated()
        where req.url!.path.hasSuffix("/events") {
            guard let json = try? JSONSerialization
                    .jsonObject(with: MockURLProtocol.capturedBodies[i]) as? [String: Any],
                  let events = json["events"] as? [[String: Any]] else { continue }
            names.append(contentsOf: events.compactMap { $0["name"] as? String })
        }
        return names
    }

    private func eventRequestCount() -> Int {
        MockURLProtocol.capturedRequests.filter { $0.url!.path.hasSuffix("/events") }.count
    }

    /// The heart of M3: an app switch flushes but reports nothing.
    func testResignActiveFlushesWithoutEmittingABackgroundEvent() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let c = core(file: file, observer: observer)
        configure(c); drain(c, "configured")
        c.track("feature_used", properties: [:]); drain(c, "tracked")

        observer.onResignActive?()
        drain(c, "resigned")

        XCTAssertTrue(sentEventNames().contains("feature_used"), "the queue must still be flushed")
        XCTAssertFalse(sentEventNames().contains("_bcs.apple.app_backgrounded"),
                       "⌘-Tab must not report a background transition: \(sentEventNames())")
        XCTAssertTrue(FileEventStore(fileURL: file).load().isEmpty)
        c.shutdown()
    }

    /// 200 app switches a day must not be 200 POSTs when there is nothing to
    /// send — the other half of the review's cost complaint.
    func testRepeatedResignActiveWithAnEmptyQueueSendsNothing() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let c = core(file: file, observer: observer)
        configure(c); drain(c, "configured")
        let baseline = eventRequestCount()

        for _ in 0..<50 { observer.onResignActive?() }
        drain(c, "resigned repeatedly")

        XCTAssertEqual(eventRequestCount(), baseline,
                       "an idle app switch must not cost a request")
        c.shutdown()
    }

    /// A real departure still reports one, exactly one.
    func testBackgroundStillEmitsExactlyOneEvent() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let c = core(file: file, observer: observer)
        configure(c); drain(c, "configured")

        observer.onBackground?()
        drain(c, "backgrounded")
        XCTAssertEqual(sentEventNames().filter { $0 == "_bcs.apple.app_backgrounded" }.count, 1)
        c.shutdown()
    }

    /// macOS signals the same departure twice — `didHide` then `willTerminate`.
    func testHideThenTerminateReportsOneDeparture() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let c = core(file: file, observer: observer)
        configure(c); drain(c, "configured")

        observer.onBackground?()   // didHide
        drain(c, "hidden")
        c.track("feature_used", properties: [:])
        observer.onBackground?()   // willTerminate
        drain(c, "terminating")

        XCTAssertEqual(sentEventNames().filter { $0 == "_bcs.apple.app_backgrounded" }.count, 1,
                       "\(sentEventNames())")
        XCTAssertTrue(sentEventNames().contains("feature_used"),
                      "the last-chance flush must still run: \(sentEventNames())")
        c.shutdown()
    }

    /// Coming back to the foreground arms the next departure.
    func testForegroundRearmsTheBackgroundEvent() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let c = core(file: file, observer: observer)
        configure(c); drain(c, "configured")

        observer.onBackground?(); drain(c, "background 1")
        observer.onForeground?(); drain(c, "foreground")
        observer.onBackground?(); drain(c, "background 2")

        XCTAssertEqual(sentEventNames().filter { $0 == "_bcs.apple.app_backgrounded" }.count, 2)
        c.shutdown()
    }

    /// `flushOnBackground: false` must silence the resign-active flush too.
    func testResignActiveRespectsFlushOnBackgroundFalse() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let c = core(file: file, observer: observer)
        configure(c, flushOnBackground: false); drain(c, "configured")
        c.track("feature_used", properties: [:]); drain(c, "tracked")

        observer.onResignActive?()
        drain(c, "resigned")
        XCTAssertFalse(sentEventNames().contains("feature_used"))
        c.shutdown()
    }

    /// The kill switch covers the new path as well.
    func testResignActiveDoesNothingWhileOptedOut() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let c = core(file: file, observer: observer)
        configure(c); drain(c, "configured")
        c.optOut(); drain(c, "opted out")
        MockURLProtocol.reset(); handshake202()

        observer.onResignActive?()
        drain(c, "resigned")
        XCTAssertEqual(eventRequestCount(), 0)
        c.shutdown()
    }
}
