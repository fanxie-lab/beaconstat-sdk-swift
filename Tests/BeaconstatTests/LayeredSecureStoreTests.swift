import XCTest
@testable import Beaconstat

/// A `SecureStore` whose write success is controllable per key, standing in for
/// a Keychain that rejects `SecItemAdd` (unsandboxed macOS; iOS background
/// launch before first unlock).
private final class FlakySecureStore: SecureStore {
    private var storage: [SecureStoreKey: String] = [:]
    /// Keys whose writes fail. `nil` means *all* writes fail.
    var failingKeys: Set<SecureStoreKey>?
    private(set) var writeAttempts: [SecureStoreKey] = []
    private(set) var readAttempts: [SecureStoreKey] = []

    init(failingKeys: Set<SecureStoreKey>? = []) { self.failingKeys = failingKeys }

    func string(forKey key: SecureStoreKey) -> String? {
        readAttempts.append(key)
        return storage[key]
    }

    @discardableResult
    func set(_ value: String?, forKey key: SecureStoreKey) -> Bool {
        writeAttempts.append(key)
        guard failingKeys?.contains(key) != true, failingKeys != nil else { return false }
        storage[key] = value
        return true
    }

    /// Plant a value without going through `set`, to simulate an item that can
    /// be *read* from the Keychain but not rewritten.
    func plant(_ value: String, forKey key: SecureStoreKey) { storage[key] = value }
}

/// H5 — `FallbackSecureStore` picked in-memory-or-Keychain **once** on a single
/// probe failure, so one bad probe stranded the whole process on volatile
/// storage: a fresh `installId` per launch, `install_detected` re-fired every
/// time, `is_first_session=true` every time, and `app_updated` never.
final class LayeredSecureStoreTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("identity-\(UUID()).json")
    }

    // MARK: - per-operation, not all-or-nothing

    func testWritesGoToThePrimaryWhenItWorks() {
        let primary = FlakySecureStore()
        let mirrorFile = tempFile(); defer { try? FileManager.default.removeItem(at: mirrorFile) }
        let store = LayeredSecureStore(primary: primary, mirror: FileSecureStore(fileURL: mirrorFile))
        XCTAssertTrue(store.set("bcs_tok_x", forKey: .siteToken))
        XCTAssertEqual(primary.string(forKey: .siteToken), "bcs_tok_x")
        XCTAssertNil(store.degradationDescription)
    }

    /// The bug: one failure used to switch *every* key to volatile storage.
    func testOneFailingKeyDoesNotDemoteTheOtherKeys() {
        let primary = FlakySecureStore(failingKeys: [.siteToken])
        let mirrorFile = tempFile(); defer { try? FileManager.default.removeItem(at: mirrorFile) }
        let store = LayeredSecureStore(primary: primary, mirror: FileSecureStore(fileURL: mirrorFile))

        XCTAssertFalse(store.set("bcs_tok_x", forKey: .siteToken)) // not durable: no mirror for credentials
        store.set("install-abc", forKey: .installId)               // must still reach the Keychain

        XCTAssertEqual(primary.string(forKey: .installId), "install-abc")
        XCTAssertEqual(store.string(forKey: .installId), "install-abc")
        XCTAssertEqual(store.string(forKey: .siteToken), "bcs_tok_x") // served from the volatile tier
    }

    /// A Keychain item that reads fine but can't be rewritten must not shadow
    /// the newer value from a lower tier.
    func testPrimaryStopsBeingTrustedForAKeyAfterItsWriteFails() {
        let primary = FlakySecureStore(failingKeys: [.lastKnownVersion])
        primary.plant("1.0.0", forKey: .lastKnownVersion)
        let mirrorFile = tempFile(); defer { try? FileManager.default.removeItem(at: mirrorFile) }
        let store = LayeredSecureStore(primary: primary, mirror: FileSecureStore(fileURL: mirrorFile))

        XCTAssertEqual(store.string(forKey: .lastKnownVersion), "1.0.0")
        store.set("2.0.0", forKey: .lastKnownVersion) // primary rejects it
        XCTAssertEqual(store.string(forKey: .lastKnownVersion), "2.0.0",
                       "the stale Keychain value shadowed the newer mirrored one")
    }

    // MARK: - identity survives a broken Keychain across launches

    /// The phantom-install regression, end to end at the store level: with the
    /// Keychain rejecting every write, a *new* store instance (= next launch)
    /// must still see the same `installId`.
    func testInstallIdSurvivesRelaunchWhenEveryKeychainWriteFails() {
        let mirrorFile = tempFile(); defer { try? FileManager.default.removeItem(at: mirrorFile) }

        let first = LayeredSecureStore(primary: FlakySecureStore(failingKeys: nil),
                                       mirror: FileSecureStore(fileURL: mirrorFile))
        XCTAssertTrue(first.set("install-abc", forKey: .installId), "the mirror should have accepted it")
        first.set("1", forKey: .hasEmittedInstall)
        first.set("1", forKey: .hasStartedSession)

        let second = LayeredSecureStore(primary: FlakySecureStore(failingKeys: nil),
                                        mirror: FileSecureStore(fileURL: mirrorFile))
        XCTAssertEqual(second.string(forKey: .installId), "install-abc")
        XCTAssertEqual(second.string(forKey: .hasEmittedInstall), "1")
        XCTAssertEqual(second.string(forKey: .hasStartedSession), "1")
    }

    /// With no mirror available either, `set` must report failure so callers can
    /// decline to emit exactly-once events they cannot record.
    func testSetReportsFailureWhenNoDurableTierAcceptedTheWrite() {
        let store = LayeredSecureStore(primary: FlakySecureStore(failingKeys: nil), mirror: nil)
        XCTAssertFalse(store.set("install-abc", forKey: .installId))
        XCTAssertEqual(store.string(forKey: .installId), "install-abc") // still usable this run
        XCTAssertNotNil(store.degradationDescription)
    }

    // MARK: - the mirror must not hold credentials

    func testSiteTokenIsNeverWrittenToTheOnDiskMirror() {
        let mirrorFile = tempFile(); defer { try? FileManager.default.removeItem(at: mirrorFile) }
        let mirror = FileSecureStore(fileURL: mirrorFile)
        let store = LayeredSecureStore(primary: FlakySecureStore(failingKeys: nil), mirror: mirror)
        store.set("bcs_tok_secret", forKey: .siteToken)
        store.set("install-abc", forKey: .installId)

        XCTAssertNil(mirror.string(forKey: .siteToken))
        XCTAssertEqual(mirror.string(forKey: .installId), "install-abc")
        let onDisk = (try? String(contentsOf: mirrorFile, encoding: .utf8)) ?? ""
        XCTAssertFalse(onDisk.contains("bcs_tok_secret"), "a bearer credential reached the plain-text mirror")
    }

    // MARK: - read-through healing + diagnostics

    /// Once the Keychain works again, a mirror hit should back-fill it so the
    /// mirror stops being the source of truth.
    func testMirrorHitBackFillsTheRecoveredPrimary() {
        let mirrorFile = tempFile(); defer { try? FileManager.default.removeItem(at: mirrorFile) }
        let mirror = FileSecureStore(fileURL: mirrorFile)
        mirror.set("install-abc", forKey: .installId)

        let primary = FlakySecureStore() // healthy this launch
        let store = LayeredSecureStore(primary: primary, mirror: mirror)
        XCTAssertEqual(store.string(forKey: .installId), "install-abc")
        XCTAssertEqual(primary.string(forKey: .installId), "install-abc", "primary was not healed")
        XCTAssertNil(store.degradationDescription, "a successful heal is not a degradation")
    }

    func testDegradationIsReportedWhenTheKeychainIsUnusable() {
        let mirrorFile = tempFile(); defer { try? FileManager.default.removeItem(at: mirrorFile) }
        let store = LayeredSecureStore(primary: FlakySecureStore(failingKeys: nil),
                                       mirror: FileSecureStore(fileURL: mirrorFile))
        XCTAssertNil(store.degradationDescription)
        store.set("install-abc", forKey: .installId)
        XCTAssertNotNil(store.degradationDescription)
        XCTAssertTrue(store.degradationDescription!.contains("install_id"))
    }

    func testDeletePropagatesToEveryTier() {
        let mirrorFile = tempFile(); defer { try? FileManager.default.removeItem(at: mirrorFile) }
        let mirror = FileSecureStore(fileURL: mirrorFile)
        let primary = FlakySecureStore()
        let store = LayeredSecureStore(primary: primary, mirror: mirror)
        store.set("install-abc", forKey: .installId)
        store.set(nil, forKey: .installId)
        XCTAssertNil(store.string(forKey: .installId))
        XCTAssertNil(primary.string(forKey: .installId))
        XCTAssertNil(mirror.string(forKey: .installId))
    }
}

final class FileSecureStoreTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bcs-\(UUID())", isDirectory: true)
            .appendingPathComponent("identity.json")
    }

    /// M6: this is constructed on the main thread at launch, so `init` must not
    /// touch the filesystem.
    func testInitPerformsNoIO() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        _ = FileSecureStore(fileURL: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    func testRoundTripCreatesTheDirectoryLazily() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = FileSecureStore(fileURL: file)
        XCTAssertTrue(store.set("install-abc", forKey: .installId))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(FileSecureStore(fileURL: file).string(forKey: .installId), "install-abc")
    }

    func testMissingFileReadsAsEmpty() {
        XCTAssertNil(FileSecureStore(fileURL: tempFile()).string(forKey: .installId))
    }

    func testCorruptFileReadsAsEmptyAndIsRecoverable() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: file)
        let store = FileSecureStore(fileURL: file)
        XCTAssertNil(store.string(forKey: .installId))
        XCTAssertTrue(store.set("install-abc", forKey: .installId))
        XCTAssertEqual(FileSecureStore(fileURL: file).string(forKey: .installId), "install-abc")
    }

    func testDeleteRemovesOnlyThatKey() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = FileSecureStore(fileURL: file)
        store.set("install-abc", forKey: .installId)
        store.set("1", forKey: .hasEmittedInstall)
        store.set(nil, forKey: .installId)
        XCTAssertNil(store.string(forKey: .installId))
        XCTAssertEqual(store.string(forKey: .hasEmittedInstall), "1")
    }

    func testUnwritablePathReportsFailureRatherThanCrashing() {
        let store = FileSecureStore(fileURL: URL(fileURLWithPath: "/dev/null/nope/identity.json"))
        XCTAssertFalse(store.set("install-abc", forKey: .installId))
    }
}
