import XCTest
@testable import Beaconstat

final class InMemorySecureStoreTests: XCTestCase {
    func testSetThenGet() {
        let store = InMemorySecureStore()
        XCTAssertNil(store.string(forKey: .siteToken))
        store.set("bcs_tok_x", forKey: .siteToken)
        XCTAssertEqual(store.string(forKey: .siteToken), "bcs_tok_x")
    }

    func testSetNilDeletes() {
        let store = InMemorySecureStore()
        store.set("1", forKey: .hasEmittedInstall)
        store.set(nil, forKey: .hasEmittedInstall)
        XCTAssertNil(store.string(forKey: .hasEmittedInstall))
    }

    func testKeysAreIndependent() {
        let store = InMemorySecureStore()
        store.set("1.4.2", forKey: .lastKnownVersion)
        store.set("421", forKey: .lastKnownBuild)
        XCTAssertEqual(store.string(forKey: .lastKnownVersion), "1.4.2")
        XCTAssertEqual(store.string(forKey: .lastKnownBuild), "421")
    }
}

final class SendableAndKeychainShapeTests: XCTestCase {
    // Compiles only if BeaconstatOptions/TestMode are Sendable.
    func testOptionsAreSendable() {
        func requireSendable<T: Sendable>(_ : T.Type) {}
        requireSendable(BeaconstatOptions.self)
        requireSendable(TestMode.self)
    }

    // InMemory behavior must remain unchanged after the Keychain refactor.
    func testInMemoryStillRoundTrips() {
        let s = InMemorySecureStore()
        s.set("bcs_tok_x", forKey: .siteToken)
        XCTAssertEqual(s.string(forKey: .siteToken), "bcs_tok_x")
        s.set(nil, forKey: .siteToken)
        XCTAssertNil(s.string(forKey: .siteToken))
    }
}
