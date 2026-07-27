import XCTest
@testable import Beaconstat

/// H1 — `optIn()` was a no-op after an opt-out-short-circuited `configure()`.
/// `configure()` returned before assigning `self.configuration`, so `optIn()`
/// found `configuration == nil`, started no timer, performed no handshake,
/// created no queue and no session manager. Every subsequent `track()` was
/// silently dropped until the next cold launch — while the README advertises
/// exactly that sequence as the supported GDPR flow.
///
/// M14 — `optOut()` left the `NWPathMonitor` running for the app's lifetime,
/// left the `NotificationCenter` observers registered, and left `install_id`,
/// `site_token` and the session history in the Keychain, so a "delete my data"
/// request never cleared local identity.
final class BeaconstatCoreConsentLifecycleTests: XCTestCase {
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

    private func sentBodies() -> String {
        MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events") ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }.joined()
    }

    private func tempQueue() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
    }

    private func core(file: URL, store: SecureStore = InMemorySecureStore(),
                      reachability: Reachability? = nil,
                      observer: LifecycleObserver = LifecycleObserver()) -> BeaconstatCore {
        BeaconstatCore(store: store,
                       clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_580_200) }),
                       sessionProvider: { _ in .mocked() },
                       bundleIdentifier: "com.example.app", sdkVersion: "9.9.9",
                       queueFileURL: file, reachabilityFactory: { _ in reachability },
                       lifecycleObserver: observer)
    }

    private func configure(_ c: BeaconstatCore) {
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: o, environment: ["device.platform": "ios"])
    }

    private func drain(_ c: BeaconstatCore, _ label: String = "flow") {
        let done = expectation(description: label); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    // MARK: - H1: the documented consent sequence

    /// The README's sequence, end to end: `optOut()` → `configure()` →
    /// `optIn()` → `track()` must reach the wire.
    func testDocumentedConsentSequenceReachesTheWire() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)

        c.optOut()          // no consent yet
        configure(c)        // host configures anyway, as the README shows
        drain(c, "configured while opted out")
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty, "collected while opted out")

        c.optIn()           // user taps "Allow analytics"
        c.track("feature_used", properties: ["feature": "export"])
        c.flush()
        drain(c, "after opt-in")

        XCTAssertTrue(sentBodies().contains("feature_used"),
                      "every track() after optIn() was silently dropped")
        XCTAssertTrue(sentBodies().contains("_bcs.install_detected"),
                      "opt-in did not run the launch sequence")
    }

    /// Opt-out must still be a real kill switch while it is active.
    func testOptedOutConfigureCollectsAndSendsNothing() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let store = InMemorySecureStore(); store.set("1", forKey: .optedOut)
        let c = core(file: file, store: store)
        configure(c)
        c.track("feature_used", properties: [:])
        c.trackOpenURL(URL(string: "myapp://home")!)
        c.flush()
        drain(c)
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty)
        XCTAssertTrue(FileEventStore(fileURL: file).load().isEmpty)
    }

    /// Events queued before an opt-out must not be resurrected by a later
    /// opt-in — that would transmit data collected without consent.
    func testOptInDoesNotResurrectPreOptOutEvents() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 503) // nothing gets acked, so events stay queued
        }
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        configure(c)
        c.track("before_consent_withdrawn", properties: [:])
        drain(c, "queued")
        XCTAssertFalse(FileEventStore(fileURL: file).load().isEmpty)

        c.optOut()
        drain(c, "opted out")
        MockURLProtocol.reset()
        handshake202()
        c.optIn()
        c.flush()
        drain(c, "opted back in")
        XCTAssertFalse(sentBodies().contains("before_consent_withdrawn"))
    }

    func testOptInBeforeConfigureDoesNotCollectAnything() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        c.optIn()
        c.track("feature_used", properties: [:])
        drain(c)
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty)
    }

    /// A stale queue file left behind by a crash between `optOut()` and its
    /// purge must not survive into an opted-out launch.
    func testConfigureWhileOptedOutPurgesAnyStaleQueueFile() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        FileEventStore(fileURL: file).save([Event(name: "stale", time: "2026-04-19T10:30:00.000Z")])
        let store = InMemorySecureStore(); store.set("1", forKey: .optedOut)
        let c = core(file: file, store: store)
        configure(c)
        drain(c)
        XCTAssertTrue(FileEventStore(fileURL: file).load().isEmpty)
    }

    // MARK: - M14: opt-out stops work and purges identity

    func testOptOutStopsTheReachabilityMonitorAndLifecycleObservers() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let reachability = ManualReachability()
        let observer = LifecycleObserver()
        let c = core(file: file, reachability: reachability, observer: observer)
        configure(c)
        drain(c, "configured")
        XCTAssertEqual(reachability.startCount, 1)
        XCTAssertTrue(observer.isObserving)

        c.optOut()
        drain(c, "opted out")
        XCTAssertEqual(reachability.stopCount, 1, "NWPathMonitor kept running after opt-out")
        XCTAssertFalse(observer.isObserving, "NotificationCenter observers stayed registered")
    }

    func testOptInRestartsTheMonitorsThatOptOutStopped() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let reachability = ManualReachability()
        let observer = LifecycleObserver()
        let c = core(file: file, reachability: reachability, observer: observer)
        configure(c)
        drain(c, "configured")
        c.optOut()
        drain(c, "opted out")
        c.optIn()
        drain(c, "opted in")
        XCTAssertEqual(reachability.startCount, 2)
        XCTAssertTrue(observer.isObserving)
    }

    /// "Delete my data" has to clear the device too, not just the server.
    func testOptOutPurgesLocalIdentityButKeepsTheConsentRecord() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let store = InMemorySecureStore()
        let c = core(file: file, store: store)
        configure(c)
        drain(c, "configured")
        XCTAssertNotNil(store.string(forKey: .installId))
        XCTAssertNotNil(store.string(forKey: .siteToken))
        XCTAssertNotNil(store.string(forKey: .hasEmittedInstall))
        XCTAssertNotNil(store.string(forKey: .lastSessionStartedAt))

        c.optOut()
        drain(c, "opted out")
        for key in SecureStoreKey.allCases where key != .optedOut {
            XCTAssertNil(store.string(forKey: key), "\(key.rawValue) survived the opt-out purge")
        }
        XCTAssertNotNil(store.string(forKey: .optedOut), "the consent record itself must persist")
    }

    /// Opting back in after a purge must behave like a brand-new anonymous
    /// install — a different identity, not the deleted one.
    func testOptInAfterAPurgeStartsAFreshAnonymousIdentity() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let store = InMemorySecureStore()
        let c = core(file: file, store: store)
        configure(c)
        drain(c, "configured")
        let original = store.string(forKey: .installId)

        c.optOut()
        drain(c, "opted out")
        c.optIn()
        drain(c, "opted in")

        XCTAssertNotNil(store.string(forKey: .installId))
        XCTAssertNotEqual(store.string(forKey: .installId), original)
    }
}
