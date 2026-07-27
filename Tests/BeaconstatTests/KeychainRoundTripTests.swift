import XCTest
@testable import Beaconstat

/// Test gap 1 — `KeychainSecureStore` against the **real** `SecItem*` API.
///
/// ## What the review said, and what is now true
///
/// The review found that `KeychainSecureStore` had zero executed coverage: the
/// availability probe failed in the unsigned SwiftPM test bundle, so every test
/// silently ran on the in-memory fallback. Two things have changed since:
///
/// 1. **There is no probe any more.** Wave 1 deleted `probeAvailability()` along
///    with `FallbackSecureStore`, which chose Keychain-or-memory *once* at
///    construction and stranded the whole process on memory after a single
///    failure (H5). `LayeredSecureStore` decides per operation and heals.
/// 2. **The logic is covered in-process.** `KeychainSecureStoreTests` drives the
///    injectable `SecItemAPI` seam through delete-then-add, every failure
///    status, the access group, and the `…ThisDeviceOnly` attribute — 12 tests
///    that do not need a working Keychain because they script the answers.
///
/// What neither covers is the **success path against a real Keychain**: that
/// `SecItemAdd` with `kSecUseDataProtectionKeychain` actually succeeds and
/// round-trips. That needs an entitled bundle.
///
/// So these tests run the real thing and **skip when the platform refuses**,
/// with `XCTSkip` rather than a silent pass — the distinction that matters,
/// since a silent pass is exactly how the original gap hid. On an unsigned
/// SwiftPM bundle (`swift test` on macOS) they skip; under
/// `xcodebuild test -destination 'platform=iOS Simulator'`, which CI now runs
/// per platform, the simulator Keychain is available and they execute.
///
/// Every item is namespaced to a per-run service, so nothing here can collide
/// with a real install's items or leak between tests.
final class KeychainRoundTripTests: XCTestCase {
    private var service = ""

    override func setUp() {
        super.setUp()
        service = "com.beaconstat.sdk.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        // Best-effort cleanup: the store is namespaced per run, but leaving
        // items behind on a developer's login keychain would be rude.
        let store = KeychainSecureStore(service: service)
        for key in SecureStoreKey.allCases { store.set(nil, forKey: key) }
        super.tearDown()
    }

    /// Establishes whether this bundle can use the data-protection keychain at
    /// all, and skips the test if not — visibly.
    private func requireWorkingKeychain(_ store: KeychainSecureStore) throws {
        guard store.set("probe", forKey: .lastKnownBuild) else {
            throw XCTSkip("""
                The data-protection keychain is unavailable to this test bundle. \
                That is expected for an unsigned SwiftPM bundle on macOS: \
                kSecUseDataProtectionKeychain requires an app-sandbox or \
                keychain-access-group entitlement. These assertions execute under \
                `xcodebuild test` on a simulator, which CI runs per platform. \
                The SDK's own behaviour when the Keychain refuses a write is \
                covered by KeychainSecureStoreTests, LayeredSecureStoreTests and \
                BeaconstatCoreIdentityTests.
                """)
        }
        store.set(nil, forKey: .lastKnownBuild)
    }

    func testValuesRoundTripThroughTheRealKeychain() throws {
        let store = KeychainSecureStore(service: service)
        try requireWorkingKeychain(store)

        XCTAssertTrue(store.set("install-abc", forKey: .installId))
        XCTAssertEqual(store.string(forKey: .installId), "install-abc")
    }

    /// The Keychain has no upsert, so `set` is delete-then-add. A second write
    /// must replace rather than duplicate — a duplicate would make reads
    /// nondeterministic, and identity is exactly where that is unacceptable.
    func testOverwritingReplacesRatherThanDuplicating() throws {
        let store = KeychainSecureStore(service: service)
        try requireWorkingKeychain(store)

        XCTAssertTrue(store.set("first", forKey: .installId))
        XCTAssertTrue(store.set("second", forKey: .installId))
        XCTAssertEqual(store.string(forKey: .installId), "second")
    }

    func testDeletingRemovesTheValue() throws {
        let store = KeychainSecureStore(service: service)
        try requireWorkingKeychain(store)

        XCTAssertTrue(store.set("install-abc", forKey: .installId))
        XCTAssertTrue(store.set(nil, forKey: .installId))
        XCTAssertNil(store.string(forKey: .installId))
    }

    /// Distinct keys must not shadow each other — they share a service and
    /// differ only by account.
    func testKeysAreIndependent() throws {
        let store = KeychainSecureStore(service: service)
        try requireWorkingKeychain(store)

        XCTAssertTrue(store.set("install-abc", forKey: .installId))
        XCTAssertTrue(store.set("bcs_tok_z", forKey: .siteToken))
        XCTAssertEqual(store.string(forKey: .installId), "install-abc")
        XCTAssertEqual(store.string(forKey: .siteToken), "bcs_tok_z")
    }

    /// A value written by one instance must be readable by another — that is
    /// the entire point of the Keychain here, and it is what makes an install
    /// id survive a relaunch.
    func testAValueSurvivesANewStoreInstance() throws {
        let store = KeychainSecureStore(service: service)
        try requireWorkingKeychain(store)
        XCTAssertTrue(store.set("install-abc", forKey: .installId))

        let reopened = KeychainSecureStore(service: service)
        XCTAssertEqual(reopened.string(forKey: .installId), "install-abc",
                       "identity did not survive a new store instance")
    }

    /// The whole identity stack, end to end, against the real Keychain: a write
    /// must reach the Keychain and the read must come from it rather than from
    /// the mirror, so `degradationDescription` stays nil.
    func testTheLayeredStackReportsNoDegradationWhenTheKeychainWorks() throws {
        let keychain = KeychainSecureStore(service: service)
        try requireWorkingKeychain(keychain)

        let mirrorFile = makeTemporaryQueueFile("identity")
        let layered = LayeredSecureStore(primary: keychain,
                                         mirror: FileSecureStore(fileURL: mirrorFile))
        XCTAssertTrue(layered.set("install-abc", forKey: .installId))
        XCTAssertEqual(layered.string(forKey: .installId), "install-abc")
        XCTAssertNil(layered.degradationDescription,
                     "a working Keychain must not report degraded storage")
    }

    /// `Fingerprint.installId` must be stable across calls once written — an
    /// unstable one reports a single install as many (H5).
    func testTheInstallIdIsStableAcrossReadsAgainstTheRealKeychain() throws {
        let keychain = KeychainSecureStore(service: service)
        try requireWorkingKeychain(keychain)

        let first = Fingerprint.installId(store: keychain)
        XCTAssertNotNil(first)
        XCTAssertEqual(Fingerprint.installId(store: keychain), first)
        XCTAssertEqual(Fingerprint.installId(store: KeychainSecureStore(service: service)), first)
    }
}
