import XCTest
@testable import Beaconstat

final class FingerprintTests: XCTestCase {
    func testInstallIdIsStableAcrossCalls() {
        let store = InMemorySecureStore()
        let a = Fingerprint.installId(store: store)
        let b = Fingerprint.installId(store: store)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    func testInstallIdPersistsToStore() {
        let store = InMemorySecureStore()
        let id = Fingerprint.installId(store: store)
        XCTAssertEqual(store.string(forKey: .installId), id)
    }

    func testInstallIdReusesPreexistingValue() {
        let store = InMemorySecureStore()
        store.set("PREEXISTING", forKey: .installId)
        XCTAssertEqual(Fingerprint.installId(store: store), "PREEXISTING")
    }

    func testComputeIsDeterministic64CharHex() {
        let a = Fingerprint.compute(bundleIdentifier: "com.example.app", installId: "ABC")
        let b = Fingerprint.compute(bundleIdentifier: "com.example.app", installId: "ABC")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testComputeChangesWithInput() {
        let a = Fingerprint.compute(bundleIdentifier: "com.example.app", installId: "ABC")
        let b = Fingerprint.compute(bundleIdentifier: "com.example.app", installId: "XYZ")
        XCTAssertNotEqual(a, b)
    }
}
