import XCTest
@testable import Beaconstat

final class BeaconstatVersionTests: XCTestCase {
    func testVersionIsOneZeroZero() {
        XCTAssertEqual(BeaconstatVersion.current, "1.0.0")
    }
}
