import XCTest
@testable import Beaconstat

final class PublicAPISmokeTests: XCTestCase {
    func testPublicAPIIsCallableAndDoesNotCrash() {
        Beaconstat.configure(publicKey: "bcs_pub_test",
                             hmacSecret: String(repeating: "a", count: 64))
        Beaconstat.configure(publicKey: "bcs_pub_test",
                             hmacSecret: String(repeating: "a", count: 64),
                             options: BeaconstatOptions())
        Beaconstat.track("feature_used", properties: ["feature": "export"])
        Beaconstat.track("settings_opened")
        Beaconstat.flush()
        Beaconstat.optOut()
        Beaconstat.optIn()
        XCTAssertFalse(Beaconstat.isOptedOut)
    }
}
