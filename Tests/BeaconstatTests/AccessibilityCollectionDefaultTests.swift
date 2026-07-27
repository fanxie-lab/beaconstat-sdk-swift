import XCTest
@testable import Beaconstat

/// M10 — seven accessibility settings were collected **by default**.
///
/// None of them is App-Store-prohibited and the SDK carries no IDFA/IDFV, but
/// they are disability-adjacent signals, and combined with `device.model`,
/// screen metrics, `timezone`, `locale` and OS version they sharpen the
/// fingerprint considerably. Every adopter also inherited a privacy-manifest
/// obligation they never opted into. Off unless asked for.
@MainActor
final class AccessibilityCollectionDefaultTests: XCTestCase {
    func testDefaultOptionsDoNotCollectAccessibility() {
        XCTAssertFalse(BeaconstatOptions().collectAccessibility,
                       "accessibility collection must be opt-in")
    }

    /// The default has to reach the wire keys, not just the flag: the facade
    /// passes `collectAccessibility` to two separate collector entry points.
    func testDefaultOptionsProduceNoAccessibilityWireKeys() {
        let options = BeaconstatOptions()
        let collector = EnvironmentCollector(sdkVersion: "9.9.9", appVersion: "1.0.0",
                                             appBuild: "1",
                                             collectAccessibility: options.collectAccessibility)
        var env = collector.collectDeferrable()
        env.merge(EnvironmentCollector
            .collectMainThreadOnly(collectAccessibility: options.collectAccessibility)) { _, new in new }
        XCTAssertTrue(env.keys.filter { $0.hasPrefix("accessibility.") }.isEmpty,
                      "leaked: \(env.keys.filter { $0.hasPrefix("accessibility.") })")
    }

    /// Opting in must still work — this is a default change, not a removal.
    func testExplicitOptInStillCollectsAccessibility() {
        var options = BeaconstatOptions()
        options.collectAccessibility = true
        let env = EnvironmentCollector.collectMainThreadOnly(
            collectAccessibility: options.collectAccessibility)
        XCTAssertFalse(env.keys.filter { $0.hasPrefix("accessibility.") }.isEmpty)
    }

    /// Nothing else in the default snapshot changes — the flag must gate the
    /// `accessibility.*` keys and nothing else.
    func testTurningAccessibilityOffLeavesEveryOtherKeyIntact() {
        let on = EnvironmentCollector.collectMainThreadOnly(collectAccessibility: true)
        let off = EnvironmentCollector.collectMainThreadOnly(collectAccessibility: false)
        let removed = Set(on.keys).subtracting(off.keys)
        XCTAssertFalse(removed.isEmpty)
        XCTAssertTrue(removed.allSatisfy { $0.hasPrefix("accessibility.") }, "also dropped: \(removed)")
        for key in off.keys { XCTAssertEqual(on[key], off[key]) }
    }
}
