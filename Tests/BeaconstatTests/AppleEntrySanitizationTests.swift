import XCTest
@testable import Beaconstat

/// M2 — `track()` enforced a key regex, a 1024-char value cap and a 49-key cap,
/// but `trackShortcut` / `trackWidget` / the push hooks put `type`, `kind`,
/// `family`, `category` and `actionId` straight onto the wire.
///
/// Dynamic home-screen quick actions routinely encode their target
/// (`UIApplicationShortcutItem(type: "openChat:user@example.com")`,
/// `"openDoc:\(uuid)"`), so `_bcs.apple.shortcut_type` became both a PII leak
/// and an unbounded-cardinality reserved dimension — exactly what the deep-link
/// path was built to prevent.
final class AppleEntrySanitizationTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private let logs = LogCollector()

    private func makeCore() -> BeaconstatCore {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        logs.reset()
        let c = BeaconstatCore(store: InMemorySecureStore(),
                               clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app",
                               queueFileURL: FileManager.default.temporaryDirectory
                                   .appendingPathComponent("q-\(UUID()).json"),
                               reachabilityFactory: { _ in nil },
                               logSink: { [logs = self.logs] line in logs.append(line) })
        var o = BeaconstatOptions(); o.flushInterval = 3600; o.debugLogging = true
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: o, environment: ["device.platform": "ios"])
        return c
    }

    private func drain(_ c: BeaconstatCore) {
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    private func sentBodies() -> String {
        MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events")
                ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }.joined()
    }

    /// Properties of the named event, parsed rather than substring-matched.
    private func properties(of name: String) -> [String: String]? {
        for (i, req) in MockURLProtocol.capturedRequests.enumerated()
        where req.url!.path.hasSuffix("/events") {
            guard let json = try? JSONSerialization
                    .jsonObject(with: MockURLProtocol.capturedBodies[i]) as? [String: Any],
                  let events = json["events"] as? [[String: Any]],
                  let event = events.first(where: { ($0["name"] as? String) == name }) else { continue }
            return (event["properties"] as? [String: String]) ?? [:]
        }
        return nil
    }

    // MARK: - shortcut

    /// The review's exact scenario.
    func testShortcutTypeCarryingAnEmailNeverReachesTheWire() {
        let c = makeCore()
        c.trackShortcut("openChat:user@example.com")
        c.flush(); drain(c)

        let body = sentBodies()
        XCTAssertFalse(body.contains("user@example.com"), "PII on a reserved dimension: \(body)")
        XCTAssertFalse(body.contains("example.com"))
        XCTAssertEqual(properties(of: "_bcs.apple.opened_from_shortcut")?["_bcs.apple.shortcut_type"],
                       "openChat", "the action itself is still worth reporting")
        c.shutdown()
    }

    /// The cardinality half of the finding: a per-document id must not become a
    /// distinct value of a reserved dimension.
    func testShortcutTypeCarryingADocumentIdIsReducedToTheAction() {
        let c = makeCore()
        let uuid = UUID().uuidString
        c.trackShortcut("openDoc:\(uuid)")
        c.flush(); drain(c)

        XCTAssertFalse(sentBodies().contains(uuid))
        XCTAssertEqual(properties(of: "_bcs.apple.opened_from_shortcut")?["_bcs.apple.shortcut_type"],
                       "openDoc")
        c.shutdown()
    }

    /// The overwhelmingly common static case — a reverse-DNS type from
    /// `UIApplicationShortcutItems` — must be untouched.
    func testStaticShortcutTypeIsUnchanged() {
        let c = makeCore()
        c.trackShortcut("com.example.newItem")
        c.flush(); drain(c)
        XCTAssertEqual(properties(of: "_bcs.apple.opened_from_shortcut")?["_bcs.apple.shortcut_type"],
                       "com.example.newItem")
        c.shutdown()
    }

    /// Nothing safe survives sanitization, so the dimension is dropped — but the
    /// entry-point event itself still fires, because "the app was opened from a
    /// quick action" is the signal that matters.
    func testUnsalvageableShortcutTypeIsDroppedButTheEventStillFires() {
        let c = makeCore()
        c.trackShortcut("user@example.com")
        c.flush(); drain(c)

        let props = properties(of: "_bcs.apple.opened_from_shortcut")
        XCTAssertNotNil(props, "the entry-point event must still be reported")
        XCTAssertNil(props?["_bcs.apple.shortcut_type"])
        XCTAssertFalse(sentBodies().contains("user@example.com"))
        c.shutdown()
    }

    /// A reserved dimension is a label, not a payload. Wave 2's 64 KB per-event
    /// ceiling is a backstop; this is the actual bound.
    func testOverlongShortcutTypeIsDropped() {
        let c = makeCore()
        c.trackShortcut(String(repeating: "a", count: 5_000))
        c.flush(); drain(c)
        XCTAssertNil(properties(of: "_bcs.apple.opened_from_shortcut")?["_bcs.apple.shortcut_type"])
        c.shutdown()
    }

    // MARK: - widget

    func testWidgetKindAndFamilyAreSanitizedIndependently() {
        let c = makeCore()
        c.trackWidget(kind: "TodayWidget:user@example.com", family: "systemSmall")
        c.flush(); drain(c)

        let props = properties(of: "_bcs.apple.opened_from_widget")
        XCTAssertEqual(props?["_bcs.apple.widget_kind"], "TodayWidget")
        XCTAssertEqual(props?["_bcs.apple.widget_family"], "systemSmall",
                       "a clean sibling value must not be collateral damage")
        XCTAssertFalse(sentBodies().contains("user@example.com"))
        c.shutdown()
    }

    // MARK: - push

    func testPushCategoryAndActionIdAreSanitized() {
        let c = makeCore()
        c.trackPushOpened(category: "MESSAGE_CATEGORY", actionId: "reply:thread-42@example.com")
        c.flush(); drain(c)

        let props = properties(of: "_bcs.apple.push_opened")
        XCTAssertEqual(props?["_bcs.apple.push_category"], "MESSAGE_CATEGORY")
        XCTAssertEqual(props?["_bcs.apple.push_action_id"], "reply")
        XCTAssertFalse(sentBodies().contains("@example.com"))
        c.shutdown()
    }

    /// `push_was_silent` is SDK-produced, so sanitizing the host's `category`
    /// must not disturb it.
    func testPushReceivedKeepsWasSilentWhenTheCategoryIsRejected() {
        let c = makeCore()
        c.trackPushReceived(category: "user@example.com", wasSilent: true)
        c.flush(); drain(c)

        let props = properties(of: "_bcs.apple.push_received")
        XCTAssertEqual(props?["_bcs.apple.push_was_silent"], "true")
        XCTAssertNil(props?["_bcs.apple.push_category"])
        c.shutdown()
    }

    // MARK: - invariants that must not regress

    /// The deep-link path was already airtight and must stay byte-for-byte the
    /// same — in particular a dotted/hyphenated host must survive.
    func testDeepLinkSchemeAndHostAreStillReportedInFull() {
        let c = makeCore()
        c.trackOpenURL(URL(string: "https://my-app.example.co.uk/orders/42?token=secret#frag")!)
        c.flush(); drain(c)

        let props = properties(of: "_bcs.apple.opened_from_url")
        XCTAssertEqual(props?["_bcs.apple.url_scheme"], "https")
        XCTAssertEqual(props?["_bcs.apple.url_host"], "my-app.example.co.uk")
        XCTAssertEqual(props?["_bcs.apple.entry_type"], "universal_link")
        let body = sentBodies()
        XCTAssertFalse(body.contains("orders"))
        XCTAssertFalse(body.contains("secret"))
        XCTAssertFalse(body.contains("frag"))
        c.shutdown()
    }

    /// Every reserved event still carries its session id — sanitization runs on
    /// host-supplied scalars only.
    func testSessionIdIsStillAttachedToSanitizedEvents() {
        let c = makeCore()
        c.trackShortcut("openChat:user@example.com")
        c.flush(); drain(c)
        XCTAssertNotNil(properties(of: "_bcs.apple.opened_from_shortcut")?["_bcs.session.id"])
        c.shutdown()
    }

    /// The SDK's own logs must never carry what it just refused to transmit.
    func testTheRejectionLogNamesTheKeyAndNeverTheValue() {
        let c = makeCore()
        c.trackShortcut("user@example.com")
        c.flush(); drain(c)
        XCTAssertTrue(logs.contains("_bcs.apple.shortcut_type"), logs.joined)
        XCTAssertFalse(logs.contains("user@example.com"), logs.joined)
        c.shutdown()
    }
}
