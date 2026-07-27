import XCTest
@testable import Beaconstat

final class BeaconstatVersionTests: XCTestCase {
    func testVersionMatchesTheRelease() {
        XCTAssertEqual(BeaconstatVersion.current, "2.0.0")
    }

    /// The version has to actually reach the wire. The core used to carry a
    /// second, unread copy of it (L5), so "the constant is right" and "the
    /// server sees the right value" were not the same statement.
    @MainActor
    func testTheVersionIsWhatGoesOnTheWire() {
        let collector = EnvironmentCollector(sdkVersion: BeaconstatVersion.current,
                                             appVersion: nil, appBuild: nil,
                                             collectAccessibility: false)
        XCTAssertEqual(collector.collectDeferrable()["sdk.version"], "2.0.0")
    }

    func testVersionIsSemver() {
        let parts = BeaconstatVersion.current.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { $0.allSatisfy(\.isNumber) }, BeaconstatVersion.current)
    }
}
