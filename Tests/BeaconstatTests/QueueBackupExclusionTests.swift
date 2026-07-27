import XCTest
@testable import Beaconstat

/// L4 — the queue file lives in Application Support, which is included in
/// iCloud/iTunes backups. Transient telemetry has no business riding along,
/// and a restore would replay it onto a second device.
final class QueueBackupExclusionTests: XCTestCase {
    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcs-backup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func isExcluded(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    func testQueueFileIsExcludedFromBackup() throws {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("queue.json")
        FileEventStore(fileURL: url).save([Event(name: "a", time: "t")])
        XCTAssertTrue(try isExcluded(url), "queue.json must not be backed up")
    }

    /// Per-FILE, not per-directory. `identity.json` shares this directory and
    /// Wave 1 made it deliberately durable — excluding the directory would be
    /// inherited by its contents and would silently undo that, so a restored
    /// device would count as a brand-new install.
    func testIdentityFileInTheSameDirectoryIsUntouched() throws {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let identity = dir.appendingPathComponent("identity.json")
        try Data(#"{"install_id":"abc"}"#.utf8).write(to: identity)

        FileEventStore(fileURL: dir.appendingPathComponent("queue.json"))
            .save([Event(name: "a", time: "t")])

        XCTAssertFalse(try isExcluded(identity),
                       "identity must keep riding along in backups — it is not telemetry")
        XCTAssertFalse(try isExcluded(dir),
                       "the shared directory must not be excluded; contents inherit it")
    }

    /// `.atomic` writes to a temp file and renames, which replaces the inode —
    /// so the flag has to be reapplied, not just set once at creation.
    func testExclusionSurvivesRepeatedAtomicRewrites() throws {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("queue.json")
        let store = FileEventStore(fileURL: url)
        for i in 1...5 { store.save([Event(name: "e\(i)", time: "t")]) }
        XCTAssertTrue(try isExcluded(url), "still excluded after 5 atomic rewrites")
    }

    /// A failed write must not leave the store believing it has already applied
    /// the flag to a file that does not exist yet.
    func testExclusionIsAppliedOnceTheFirstWriteActuallySucceeds() throws {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("queue.json")
        let store = FileEventStore(fileURL: url)
        // Make the directory unwritable so the first save fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        XCTAssertFalse(store.save([Event(name: "a", time: "t")]))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        XCTAssertTrue(store.save([Event(name: "a", time: "t")]))
        XCTAssertTrue(try isExcluded(url), "the flag must land on the first write that succeeds")
    }
}
