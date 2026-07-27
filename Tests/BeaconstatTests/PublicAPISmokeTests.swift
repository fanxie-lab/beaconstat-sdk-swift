import XCTest
@testable import Beaconstat

/// `@MainActor` because `Beaconstat.configure` is (M1). This class doubles as
/// the compile-time witness that the documented call site — a main-actor context
/// such as `App.init` — still works.
@MainActor
final class PublicAPISmokeTests: XCTestCase {
    func testPublicAPIIsCallableAndDoesNotCrash() {
        var options = BeaconstatOptions()
        // Never resolves, so no live network. `https` on purpose: the SDK now
        // rejects a cleartext endpoint unless opted in (M11), and this smoke
        // test should exercise the shape a host actually ships.
        options.endpoint = URL(string: "https://sdk-test.invalid")
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
