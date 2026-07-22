import XCTest
@testable import Beaconstat

final class PublicAPISmokeTests: XCTestCase {
    func testPublicAPIIsCallableAndDoesNotCrash() {
        var options = BeaconstatOptions()
        options.endpoint = URL(string: "http://sdk-test.invalid") // never resolves — no live network
        Beaconstat.configure(publicKey: "bcs_pub_test",
                             hmacSecret: String(repeating: "a", count: 64),
                             options: options)
        Beaconstat.configure(publicKey: "bcs_pub_test",
                             hmacSecret: String(repeating: "a", count: 64),
                             options: options)
        Beaconstat.track("feature_used", properties: ["feature": "export"])
        Beaconstat.track("settings_opened")
        Beaconstat.flush()
        Beaconstat.optOut()
        Beaconstat.optIn()
        XCTAssertFalse(Beaconstat.isOptedOut)
    }
}
