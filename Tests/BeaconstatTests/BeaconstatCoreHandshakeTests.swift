import XCTest
@testable import Beaconstat

final class BeaconstatCoreHandshakeTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func tempQueue() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
    }

    /// Where a batch goes under the configuration the suite is compiled in.
    /// `.automatic` routing sends Debug builds to the test pipeline and Release
    /// builds to production — a distinction no test could make while
    /// `swift test -c release` failed to compile (test gap 6).
    static var expectedEventsPath: String {
        BeaconstatCore.isDebugBuild || BeaconstatCore.isSimulator ? "/v1/debug/events" : "/v1/events"
    }

    /// - Parameter file: **always** supplied. Omitting it made the core fall back
    ///   to `BeaconstatCore.defaultQueueFileURL()`, i.e. the host machine's real
    ///   `~/Library/Application Support/Beaconstat/queue.json` — the same
    ///   test-isolation defect the review recorded against `PublicAPISmokeTests`
    ///   (L10), which it did not notice here.
    private func makeCore(store: SecureStore, file: URL) -> BeaconstatCore {
        BeaconstatCore(store: store,
                       clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_580_200) }),
                       sessionProvider: { _ in .mocked() },
                       bundleIdentifier: "com.example.app",
                       queueFileURL: file,
                       reachabilityFactory: { _ in nil })
    }

    func testHandshakeThenSignedInstallEvent() {
        MockURLProtocol.handler = { req in
            if req.url!.path.hasSuffix("/handshake") {
                return .init(statusCode: 200,
                             data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:32:00.000Z"}"#.utf8))
            }
            return .init(statusCode: 202, data: Data(#"{"success":true,"eventsQueued":1}"#.utf8))
        }
        let store = InMemorySecureStore()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let core = makeCore(store: store, file: file)
        let done = expectation(description: "flow")
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: BeaconstatOptions(), environment: ["device.platform": "ios"])
        core.onQuiescent { done.fulfill() } // test seam: fires when the serial queue drains
        wait(for: [done], timeout: 3)

        // Read the order from the mock's own (locked) capture list rather than a
        // `var` appended to from a URLSession loading thread.
        XCTAssertEqual(MockURLProtocol.capturedRequests.map { $0.url!.path },
                       ["/v1/handshake", Self.expectedEventsPath])
        XCTAssertEqual(store.string(forKey: .siteToken), "bcs_tok_z")
        XCTAssertNotNil(store.string(forKey: .hasEmittedInstall))
        // The events request carried the required signed headers.
        let eventsReq = MockURLProtocol.requests(forPathSuffix: "/events").first!
        XCTAssertEqual(eventsReq.value(forHTTPHeaderField: "x-site-token"), "bcs_tok_z")
        XCTAssertNotNil(eventsReq.value(forHTTPHeaderField: "x-signature"))
        XCTAssertNotNil(eventsReq.value(forHTTPHeaderField: "x-timestamp"))
        XCTAssertTrue(MockURLProtocol.eventBodies().contains("_bcs.install_detected"))
        core.shutdown()
    }

    func testInstallDetectedFiresOnlyOnce() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let store = InMemorySecureStore()
        store.set("1", forKey: .hasEmittedInstall) // already emitted before
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let core = makeCore(store: store, file: file)
        let done = expectation(description: "flow")
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: BeaconstatOptions(), environment: ["device.platform": "ios"])
        core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        // `install_detected` must not be re-emitted. A send does happen: since
        // C1 a successful handshake flushes what's already queued, which on this
        // path is the run's `session_started` — previously that sat on disk until
        // the periodic timer (4 hours away in Release).
        let sent = MockURLProtocol.eventBodies()
        XCTAssertFalse(sent.contains("_bcs.install_detected"))
        XCTAssertTrue(sent.contains("_bcs.session_started"))
        core.shutdown()
    }

    func testInvalidKeysDisableSilently() {
        MockURLProtocol.handler = { _ in .init(statusCode: 200) }
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let core = makeCore(store: InMemorySecureStore(), file: file)
        let done = expectation(description: "flow")
        core.configure(publicKey: "not_valid", hmacSecret: "short",
                       options: BeaconstatOptions(), environment: [:])
        core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty) // never hit the network
        core.shutdown()
    }

    // MARK: handshake `environmentType`

    /// Runs one configure and returns the `environmentType` the handshake body
    /// carried. The server routes by this value, so it has to be the resolved
    /// environment, not a two-way guess.
    private func handshakeEnvironmentType(options: BeaconstatOptions,
                                          environment: [String: String]) throws -> String {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let core = makeCore(store: InMemorySecureStore(), file: file)
        let done = expectation(description: "flow")
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: options, environment: environment)
        core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        core.shutdown()
        let body = try XCTUnwrap(MockURLProtocol.bodies(forPathSuffix: "/handshake").first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        return try XCTUnwrap(json["environmentType"] as? String)
    }

    private var isDebugOrSimulator: Bool { BeaconstatCore.isDebugBuild || BeaconstatCore.isSimulator }

    /// A TestFlight run reports `testflight`. (A Debug/simulator build outranks
    /// TestFlight, so under `swift test` in Debug the resolved value is
    /// `development`; the Release leg of the suite exercises `testflight`.
    /// `TestModeResolverTests` pins the full table independent of the build.)
    func testHandshakeReportsTestFlightEnvironment() throws {
        let got = try handshakeEnvironmentType(
            options: BeaconstatOptions(),
            environment: ["device.platform": "ios", "run_context.is_testflight": "true"])
        XCTAssertEqual(got, isDebugOrSimulator ? "development" : "testflight")
    }

    func testHandshakeReportsProductionWhenTestFlightOptedOut() throws {
        var o = BeaconstatOptions(); o.routeTestFlightToTest = false
        let got = try handshakeEnvironmentType(
            options: o, environment: ["device.platform": "ios", "run_context.is_testflight": "true"])
        XCTAssertEqual(got, isDebugOrSimulator ? "development" : "production")
    }

    func testHandshakeReportsProductionWhenForced() throws {
        var o = BeaconstatOptions(); o.testMode = .forceProduction
        let got = try handshakeEnvironmentType(
            options: o, environment: ["device.platform": "ios", "run_context.is_testflight": "true"])
        XCTAssertEqual(got, "production")
    }

    func testHandshakeReportsDevelopmentWhenForcedToTest() throws {
        var o = BeaconstatOptions(); o.testMode = .forceTest
        let got = try handshakeEnvironmentType(options: o, environment: ["device.platform": "ios"])
        XCTAssertEqual(got, "development")
    }
}
