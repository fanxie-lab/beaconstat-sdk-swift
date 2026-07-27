import XCTest
@testable import Beaconstat

/// M1/M6 — `configure()` used to run the *whole* environment snapshot on the
/// caller's thread: `sysctlbyname`, the App Store receipt URL, `Locale`,
/// `TimeZone`, `UIScreen.main`, `UITraitCollection.current` and six
/// `UIAccessibility` reads, all synchronously before first frame, with nothing
/// requiring the caller to be on main.
///
/// The split has to hold two invariants at once: the UIKit reads stay on main
/// (M1) and everything else leaves the launch critical path (M6) — without
/// dropping a single wire key.
@MainActor
final class EnvironmentCollectorSplitTests: XCTestCase {
    private func collector(collectAccessibility: Bool = true) -> EnvironmentCollector {
        EnvironmentCollector(sdkVersion: "9.9.9", appVersion: "1.2.3", appBuild: "42",
                             collectAccessibility: collectAccessibility)
    }

    /// The split must be lossless: no wire key may go missing.
    func testMainThreadAndDeferrableKeysUnionToTheFullSnapshot() {
        let c = collector()
        let full = c.collect()
        var union = c.collectDeferrable()
        union.merge(EnvironmentCollector.collectMainThreadOnly(collectAccessibility: true)) { _, new in new }
        XCTAssertEqual(Set(full.keys), Set(union.keys))
        XCTAssertEqual(full, union)
    }

    func testTheTwoHalvesAreDisjoint() {
        let deferrable = Set(collector().collectDeferrable().keys)
        let main = Set(EnvironmentCollector.collectMainThreadOnly(collectAccessibility: true).keys)
        XCTAssertTrue(deferrable.isDisjoint(with: main), "overlap: \(deferrable.intersection(main))")
    }

    /// Anything backed by `UIScreen` / `UITraitCollection` / `UIAccessibility`
    /// must be in the main-thread half, or `@MainActor` on `configure` buys
    /// nothing.
    func testUIBackedKeysAreInTheMainThreadHalf() {
        let main = Set(EnvironmentCollector.collectMainThreadOnly(collectAccessibility: true).keys)
        let deferrable = Set(collector().collectDeferrable().keys)
        for key in main where key.hasPrefix("accessibility.") { XCTAssertFalse(deferrable.contains(key)) }
        XCTAssertTrue(main.contains("user_preference.color_scheme"))
        XCTAssertFalse(deferrable.contains("user_preference.color_scheme"))
        for key in ["device.screen_width", "device.screen_height", "device.screen_scale"] {
            XCTAssertFalse(deferrable.contains(key), "\(key) is a UIScreen read and must stay on main")
        }
    }

    /// The expensive launch-time work — `sysctlbyname`, receipt URL, Locale,
    /// TimeZone — must be in the deferrable half.
    func testExpensiveLaunchWorkIsDeferrable() {
        let deferrable = collector().collectDeferrable()
        XCTAssertNotNil(deferrable["device.model"])             // sysctlbyname
        XCTAssertNotNil(deferrable["run_context.is_testflight"]) // appStoreReceiptURL
        XCTAssertNotNil(deferrable["locale"])                    // Locale.current
        XCTAssertNotNil(deferrable["timezone"])                  // TimeZone.current
        XCTAssertNotNil(deferrable["sdk.version"])
        XCTAssertNotNil(deferrable["app.version"])
    }

    /// The deferrable half must be genuinely safe off the main thread.
    func testDeferrableHalfIsIdenticalWhenCollectedOffTheMainThread() {
        let c = collector()
        let onMain = c.collectDeferrable()
        let done = expectation(description: "off main")
        var offMain: [String: String] = [:]
        DispatchQueue.global().async {
            offMain = c.collectDeferrable()
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(onMain, offMain)
    }

    func testAccessibilityOptOutAppliesToTheMainThreadHalf() {
        let keys = EnvironmentCollector.collectMainThreadOnly(collectAccessibility: false).keys
        XCTAssertTrue(keys.filter { $0.hasPrefix("accessibility.") }.isEmpty)
    }
}
