import XCTest
@testable import Beaconstat

/// L1 — the environment snapshot was taken once at `configure()` and reused for
/// every batch for the whole process lifetime. So `device.orientation`,
/// `device.screen_width`/`_height`, `user_preference.color_scheme` and every
/// `accessibility.*` value were launch-time values forever: rotate the device or
/// switch to Dark Mode and the SDK kept reporting whatever was true at launch.
/// Nothing documented it.
final class VolatileEnvironmentRefreshTests: XCTestCase {
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
                       bundleIdentifier: "com.example.app",
                       queueFileURL: file, reachabilityFactory: { _ in nil },
                       lifecycleObserver: observer)
    }

    private func drain(_ c: BeaconstatCore, _ label: String = "flow") {
        let done = expectation(description: label); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// The refresh crosses main and comes back, so settle twice.
    private func settleRefresh(_ c: BeaconstatCore) {
        drain(c, "refresh out"); drain(c, "refresh back")
    }

    /// The `environment` map of every batch that reached the wire.
    private func sentEnvironments() -> [[String: String]] {
        var out: [[String: String]] = []
        for (i, req) in MockURLProtocol.capturedRequests.enumerated()
        where req.url!.path.hasSuffix("/events") {
            guard let json = try? JSONSerialization
                    .jsonObject(with: MockURLProtocol.capturedBodies[i]) as? [String: Any],
                  let env = json["environment"] as? [String: String] else { continue }
            out.append(env)
        }
        return out
    }

    /// The review's scenario: the user rotates the device (or flips to Dark
    /// Mode) while the app is backgrounded, and comes back.
    func testForegroundRefreshesTheVolatileKeys() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let c = core(file: file, observer: observer)

        let live = LogCollector() // doubles as a mutable box for the current UI state
        live.append("portrait")
        var options = BeaconstatOptions(); options.flushInterval = 3600; options.batchSize = 10_000
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: options,
                    environment: ["device.orientation": "portrait",
                                  "user_preference.color_scheme": "light"],
                    volatileEnvironment: {
                        ["device.orientation": live.lines.last ?? "portrait",
                         "user_preference.color_scheme": live.lines.last == "landscape" ? "dark" : "light"]
                    })
        drain(c, "configured")

        // The user leaves, rotates, changes appearance, and comes back.
        observer.onBackground?(); drain(c, "backgrounded")
        live.append("landscape")
        observer.onForeground?()
        settleRefresh(c)

        MockURLProtocol.reset(); handshake202()
        c.track("feature_used", properties: [:]); c.flush(); drain(c, "tracked")

        guard let env = sentEnvironments().last else { return XCTFail("nothing sent") }
        XCTAssertEqual(env["device.orientation"], "landscape",
                       "the snapshot is still reporting launch-time orientation")
        XCTAssertEqual(env["user_preference.color_scheme"], "dark")
        c.shutdown()
    }

    /// A refresh must not drop the keys it doesn't own — the deferred half
    /// (`device.model`, `locale`, `sdk.version`) is collected once by design.
    func testRefreshLeavesTheStableKeysIntact() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let c = core(file: file, observer: observer)
        var options = BeaconstatOptions(); options.flushInterval = 3600; options.batchSize = 10_000
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: options,
                    environment: ["device.orientation": "portrait"],
                    deferredEnvironment: { ["device.model": "iPhone15,2", "locale": "en_GB"] },
                    volatileEnvironment: { ["device.orientation": "landscape"] })
        drain(c, "configured")

        observer.onForeground?()
        settleRefresh(c)
        MockURLProtocol.reset(); handshake202()
        c.track("feature_used", properties: [:]); c.flush(); drain(c, "tracked")

        guard let env = sentEnvironments().last else { return XCTFail("nothing sent") }
        XCTAssertEqual(env["device.model"], "iPhone15,2")
        XCTAssertEqual(env["locale"], "en_GB")
        XCTAssertEqual(env["device.orientation"], "landscape")
        c.shutdown()
    }

    /// The refresh must stay off the per-event path — the whole point of M6 was
    /// that the UI reads are not free.
    func testTheVolatileSnapshotIsNotTakenPerEvent() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let c = core(file: file, observer: observer)
        let calls = LogCollector()
        var options = BeaconstatOptions(); options.flushInterval = 3600; options.batchSize = 10_000
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: options,
                    environment: [:],
                    volatileEnvironment: { calls.append("collected"); return [:] })
        drain(c, "configured")
        let afterConfigure = calls.lines.count

        for i in 0..<40 { c.track("feature_used", properties: ["i": "\(i)"]) }
        c.trackShortcut("com.example.newItem")
        c.flush()
        drain(c, "tracked")
        XCTAssertEqual(calls.lines.count, afterConfigure,
                       "the UI snapshot must not be re-read per event")

        observer.onForeground?()
        settleRefresh(c)
        XCTAssertEqual(calls.lines.count, afterConfigure + 1, "exactly one refresh per foreground")
        c.shutdown()
    }

    /// Refreshing must not run while the host has opted out.
    func testNoRefreshWhileOptedOut() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let c = core(file: file, observer: observer)
        let calls = LogCollector()
        var options = BeaconstatOptions(); options.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: options,
                    environment: [:], volatileEnvironment: { calls.append("collected"); return [:] })
        drain(c, "configured")
        c.optOut(); drain(c, "opted out")
        let before = calls.lines.count

        observer.onForeground?()
        settleRefresh(c)
        XCTAssertEqual(calls.lines.count, before)
        c.shutdown()
    }

    /// Omitting the closure keeps the previous behaviour exactly — the rest of
    /// the suite depends on it.
    func testNoVolatileClosureIsSupported() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let c = core(file: file, observer: observer)
        var options = BeaconstatOptions(); options.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: options,
                    environment: ["device.orientation": "portrait"])
        drain(c, "configured")
        observer.onForeground?()
        settleRefresh(c)
        MockURLProtocol.reset(); handshake202()
        c.track("feature_used", properties: [:]); c.flush(); drain(c, "tracked")
        XCTAssertEqual(sentEnvironments().last?["device.orientation"], "portrait")
        c.shutdown()
    }

    /// The two collector entry points must produce the same snapshot — the
    /// nonisolated one exists only so the refresh can run from a context the
    /// compiler cannot prove is main.
    @MainActor
    func testTheTwoCollectorEntryPointsAgree() {
        for accessibility in [true, false] {
            XCTAssertEqual(
                EnvironmentCollector.collectMainThreadOnly(collectAccessibility: accessibility),
                EnvironmentCollector.collectMainThreadOnlyAssumingMainThread(
                    collectAccessibility: accessibility))
        }
    }
}
