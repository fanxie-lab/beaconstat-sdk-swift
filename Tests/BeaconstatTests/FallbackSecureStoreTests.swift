import XCTest
@testable import Beaconstat

final class FallbackSecureStoreTests: XCTestCase {
    func testUsesPrimaryWhenAvailable() {
        let primary = InMemorySecureStore()
        let store = FallbackSecureStore(primary: primary, isPrimaryAvailable: { true },
                                        fallback: { InMemorySecureStore() })
        store.set("v", forKey: .siteToken)
        XCTAssertEqual(primary.string(forKey: .siteToken), "v") // wrote to primary
    }

    func testFallsBackWhenPrimaryUnavailable() {
        let primary = InMemorySecureStore()
        let fallback = InMemorySecureStore()
        let store = FallbackSecureStore(primary: primary, isPrimaryAvailable: { false },
                                        fallback: { fallback })
        store.set("v", forKey: .siteToken)
        XCTAssertNil(primary.string(forKey: .siteToken))       // primary untouched
        XCTAssertEqual(fallback.string(forKey: .siteToken), "v")
    }
}
