import XCTest
@testable import Beaconstat

// `NonDurableSecureStore` and `AlwaysFailingKeychainStub` moved to
// `TestSupport.swift` — `LoggerPrivacyTests` needs the same degraded-store
// shapes, and a `private` double in one file cannot be reused.


/// H5 — the silent identity downgrade. Every one of these asserts on the
/// *observable* consequence the review measured: phantom installs.
final class BeaconstatCoreIdentityTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func handshake202() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
    }

    private func sentEventBodies() -> String {
        MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events") ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }.joined()
    }

    private func handshakeFingerprints() -> [String] {
        MockURLProtocol.capturedRequests.enumerated().compactMap { i, req -> String? in
            guard req.url!.path.hasSuffix("/handshake"),
                  let json = try? JSONSerialization.jsonObject(with: MockURLProtocol.capturedBodies[i]) as? [String: Any]
            else { return nil }
            return json["fingerprint"] as? String
        }
    }

    @discardableResult
    private func launch(store: SecureStore, queueFile: URL, log: LogCollector? = nil) -> BeaconstatCore {
        let core = BeaconstatCore(store: store,
                                  clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_580_200) }),
                                  sessionProvider: { _ in .mocked() },
                                  bundleIdentifier: "com.example.app",
                                  queueFileURL: queueFile,
                                  reachabilityFactory: { _ in nil },
                                  logSink: log.map { collector in { collector.append($0) } })
        var o = BeaconstatOptions(); o.flushInterval = 3600
        // Explicit, not inherited from the build configuration: the logger is
        // `debugLogging || isDebugBuild`, so the degradation assertions below
        // would pass vacuously under `swift test -c release`.
        o.debugLogging = true
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: o, environment: ["device.platform": "ios", "app.version": "1.0.0"])
        let done = expectation(description: "launch"); core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        return core
    }

    /// The headline regression: three launches with a broken Keychain but a
    /// working on-disk mirror must report **one** install, not three.
    func testKeychainFailureDoesNotMintAPhantomInstallPerLaunch() {
        handshake202()
        let mirrorFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: mirrorFile) }

        for _ in 0..<3 {
            let queueFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("q-\(UUID()).json")
            defer { try? FileManager.default.removeItem(at: queueFile) }
            // A brand-new Keychain store per launch, always rejecting writes.
            let store = LayeredSecureStore(primary: AlwaysFailingKeychainStub(),
                                           mirror: FileSecureStore(fileURL: mirrorFile))
            launch(store: store, queueFile: queueFile)
        }

        let installs = sentEventBodies().components(separatedBy: "_bcs.install_detected").count - 1
        XCTAssertEqual(installs, 1, "install_detected re-fired on a later launch — phantom install")
        let firstSessions = sentEventBodies().components(separatedBy: "_bcs.is_first_session").count - 1
        XCTAssertEqual(firstSessions, 1, "is_first_session=true re-sent on a later launch")

        let fingerprints = Set(handshakeFingerprints())
        XCTAssertEqual(fingerprints.count, 1, "a different fingerprint per launch: \(fingerprints)")
    }

    /// With no durable tier at all we must not *guess*: emitting
    /// `install_detected` we cannot record means re-emitting it every launch,
    /// and handshaking with a per-launch fingerprint means one install counted
    /// many times. Send nothing instead; the events stay queued for a run where
    /// storage works.
    func testNoDurableStorageSuppressesInstallAndHandshakeRatherThanGuessing() {
        handshake202()
        let queueFile = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: queueFile) }
        let log = LogCollector()
        launch(store: NonDurableSecureStore(), queueFile: queueFile, log: log)

        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty,
                      "handshook with an install id that will not survive the launch")
        XCTAssertFalse(sentEventBodies().contains("_bcs.install_detected"))
        XCTAssertTrue(log.contains("install id"), "the host was never told identity is broken:\n\(log.joined)")
    }

    /// The degradation must be surfaced, not silent — that was the whole point
    /// of H5: "The host is never told."
    func testDegradedSecureStorageIsLoggedAtConfigure() {
        handshake202()
        let queueFile = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: queueFile) }
        let mirrorFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: mirrorFile) }
        let log = LogCollector()
        let store = LayeredSecureStore(primary: AlwaysFailingKeychainStub(),
                                       mirror: FileSecureStore(fileURL: mirrorFile))
        launch(store: store, queueFile: queueFile, log: log)
        XCTAssertTrue(log.contains("secure storage degraded"),
                      "no degradation warning was logged:\n\(log.joined)")
    }

    /// A healthy store must stay silent — no crying wolf on every launch.
    func testHealthyStorageLogsNoDegradation() {
        handshake202()
        let queueFile = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: queueFile) }
        let log = LogCollector()
        launch(store: InMemorySecureStore(), queueFile: queueFile, log: log)
        XCTAssertFalse(log.contains("degraded"), log.joined)
    }
}
