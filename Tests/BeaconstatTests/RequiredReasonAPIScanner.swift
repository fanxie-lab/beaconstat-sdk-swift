import Foundation
import XCTest
@testable import Beaconstat

/// Sweeps the SDK's own Swift sources for Apple's required-reason APIs and
/// reports, for each hit, whether it sits behind a macOS-only compilation
/// condition.
///
/// A source scan rather than a runtime check because that is the only way to
/// see the question Apple's static analysis asks: which symbols end up in the
/// binary for a given platform. `#if` is resolved by the compiler, so a runtime
/// test on macOS can never observe what an iOS build contains.
enum RequiredReasonAPIScanner {
    struct Hit: CustomStringConvertible {
        let file: String
        let line: Int
        let token: String
        let category: String
        /// True when every enclosing branch this line sits in requires macOS.
        let isMacOSGated: Bool

        var description: String {
            "\(file):\(line) — \(token) (\(category))\(isMacOSGated ? " [macOS-gated]" : "")"
        }
    }

    /// Apple's five required-reason categories, as tokens that would appear in
    /// Swift source. Patterns, not plain substrings, so `stat(` does not match
    /// `fstatfs(` and `systemSize` does not match a longer identifier.
    private static let categories: [(category: String, tokens: [String])] = [
        ("FileTimestamp", [#"\bcreationDate\b"#, #"\bmodificationDate\b"#, #"\bfileModificationDate\b"#,
                           #"\bcontentModificationDateKey\b"#, #"\bcreationDateKey\b"#,
                           #"\bgetattrlist\b"#, #"\bgetattrlistbulk\b"#, #"\bfgetattrlist\b"#,
                           #"\bgetattrlistat\b"#, #"\battributesOfItem\b"#,
                           #"\bstat\s*\("#, #"\bfstat\s*\("#, #"\blstat\s*\("#, #"\bfstatat\s*\("#]),
        ("SystemBootTime", [#"\bsystemUptime\b"#, #"\bmach_absolute_time\b"#]),
        ("DiskSpace", [#"\bvolumeAvailableCapacity\w*\b"#, #"\bvolumeTotalCapacityKey\b"#,
                       #"\bsystemFreeSize\b"#, #"\bsystemSize\b"#, #"\battributesOfFileSystem\b"#,
                       #"\bstatfs\s*\("#, #"\bstatvfs\s*\("#, #"\bfstatfs\s*\("#, #"\bfstatvfs\s*\("#]),
        ("ActiveKeyboards", [#"\bactiveInputModes\b"#]),
        ("UserDefaults", [#"\bUserDefaults\b"#, #"\bNSUserDefaults\b"#])
    ]

    /// The package's `Sources/Beaconstat` directory, located from this file's
    /// compile-time path.
    static func sourcesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)              // Tests/BeaconstatTests/RequiredReasonAPIScanner.swift
            .deletingLastPathComponent()             // Tests/BeaconstatTests
            .deletingLastPathComponent()             // Tests
            .deletingLastPathComponent()             // <package root>
            .appendingPathComponent("Sources/Beaconstat")
    }

    static func scanSources() throws -> [Hit] {
        let directory = sourcesDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("""
                The package sources are not reachable from this test bundle at \
                \(directory.path). That happens when the bundle runs somewhere other than \
                the machine that compiled it (a physical device). The audit runs on every \
                `swift test` and every simulator leg of CI.
                """)
        }
        // `.swift` only. `PrivacyInfo.xcprivacy` lives in the same directory and
        // its comments name every covered API in the audit; scanning it would
        // have the manifest flag itself.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertFalse(names.isEmpty, "no Swift sources found to scan in \(directory.path)")
        return try names.flatMap { try scan(file: directory.appendingPathComponent($0), named: $0) }
    }

    private static func scan(file: URL, named name: String) throws -> [Hit] {
        scan(source: try String(contentsOf: file, encoding: .utf8), named: name)
    }

    /// Split from the file read so the `#if` bookkeeping can be exercised
    /// against synthetic sources — a scanner that silently stopped matching
    /// would make `testTheOnlyRequiredReasonAPIInTheSourceIsMacOSGated` pass
    /// for the wrong reason, which is the failure mode this whole file exists
    /// to prevent.
    static func scan(source: String, named name: String) -> [Hit] {
        let lines = source.components(separatedBy: .newlines)
        var hits: [Hit] = []
        // Conditions of the branch currently open at each nesting level. A line
        // is macOS-gated when ANY enclosing branch requires macOS, which is the
        // conservative direction: an extra `#if` around a gated read cannot
        // make it reachable elsewhere.
        var branches: [String] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                branches.append(String(trimmed.dropFirst(4)))
                continue
            }
            if trimmed.hasPrefix("#elseif ") {
                if !branches.isEmpty { branches.removeLast() }
                branches.append(String(trimmed.dropFirst(8)))
                continue
            }
            if trimmed == "#else" {
                // The complement of a macOS branch is emphatically not macOS.
                if !branches.isEmpty { branches.removeLast() }
                branches.append("")
                continue
            }
            if trimmed == "#endif" {
                if !branches.isEmpty { branches.removeLast() }
                continue
            }
            // Comments describe covered APIs all over this package; only code
            // puts a symbol in the binary.
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else { continue }
            let gated = branches.contains { requiresMacOS($0) }
            for (category, tokens) in categories where matches(tokens, in: line) != nil {
                hits.append(Hit(file: name, line: index + 1,
                                token: matches(tokens, in: line) ?? category,
                                category: category, isMacOSGated: gated))
            }
        }
        return hits
    }

    /// `os(macOS)` present and not negated. Anything more clever would be
    /// guessing at expressions this package does not write.
    private static func requiresMacOS(_ condition: String) -> Bool {
        condition.contains("os(macOS)") && !condition.contains("!os(macOS)")
    }

    /// Returns the matched token's plain name, or nil.
    private static func matches(_ patterns: [String], in line: String) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let matched = Range(match.range, in: line) {
                return String(line[matched])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "( \t"))
            }
        }
        return nil
    }
}

// MARK: - Tests for the scanner itself

/// The scanner grading itself.
///
/// `testTheOnlyRequiredReasonAPIInTheSourceIsMacOSGated` asserts an *absence*,
/// and an absence test is worthless unless the thing doing the looking can be
/// shown to find what is there. These drive the scanner over synthetic sources
/// containing exactly the patterns it must catch.
final class RequiredReasonAPIScannerTests: XCTestCase {
    private func scan(_ source: String) -> [RequiredReasonAPIScanner.Hit] {
        RequiredReasonAPIScanner.scan(source: source, named: "Synthetic.swift")
    }

    func testAnUngatedUserDefaultsReadIsFlagged() {
        let hits = scan("let x = UserDefaults.standard.string(forKey: \"k\")")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.category, "UserDefaults")
        XCTAssertFalse(try XCTUnwrap(hits.first).isMacOSGated)
    }

    func testTheSameReadInsideAnIfOSMacOSBranchIsGated() throws {
        let hits = scan("""
            #if os(macOS)
            let x = UserDefaults.standard.string(forKey: "k")
            #endif
            """)
        XCTAssertTrue(try XCTUnwrap(hits.first).isMacOSGated)
    }

    /// The exact shape `EnvironmentCollector.colorScheme()` uses.
    func testAnElseIfOSMacOSBranchIsGated() throws {
        let hits = scan("""
            #if canImport(UIKit) && !os(watchOS)
            return light()
            #elseif os(macOS)
            let x = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
            #else
            return "light"
            #endif
            """)
        XCTAssertTrue(try XCTUnwrap(hits.first).isMacOSGated)
    }

    /// The trap the `#else` handling exists for: the complement of a macOS
    /// branch is every platform that is not macOS, i.e. exactly the ones that
    /// need a declaration.
    func testTheElseBranchOfAMacOSConditionIsNotGated() throws {
        let hits = scan("""
            #if os(macOS)
            return "dark"
            #else
            let x = UserDefaults.standard.string(forKey: "k")
            #endif
            """)
        XCTAssertFalse(try XCTUnwrap(hits.first).isMacOSGated)
    }

    func testANegatedMacOSConditionIsNotGated() throws {
        let hits = scan("""
            #if !os(macOS)
            let x = UserDefaults.standard.string(forKey: "k")
            #endif
            """)
        XCTAssertFalse(try XCTUnwrap(hits.first).isMacOSGated)
    }

    /// Nesting has to pop correctly, or a `#endif` earlier in a file would leak
    /// a macOS gate onto everything after it.
    func testAGateDoesNotLeakPastItsEndif() throws {
        let hits = scan("""
            #if os(macOS)
            let a = UserDefaults.standard
            #endif
            let b = UserDefaults.standard
            """)
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits[0].isMacOSGated)
        XCTAssertFalse(hits[1].isMacOSGated)
    }

    func testCommentsMentioningACoveredAPIAreNotFlagged() {
        XCTAssertTrue(scan("// UserDefaults and systemUptime are not used here").isEmpty)
        XCTAssertTrue(scan("/// mach_absolute_time() would need reason 35F9.1").isEmpty)
    }

    /// One per category, so a future edit that drops a category from the sweep
    /// fails rather than quietly narrowing it.
    func testEveryRequiredReasonCategoryIsDetected() {
        let samples: [(String, String)] = [
            ("FileTimestamp", "let d = try FileManager.default.attributesOfItem(atPath: p)"),
            ("SystemBootTime", "let up = ProcessInfo.processInfo.systemUptime"),
            ("DiskSpace", "let v = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])"),
            ("ActiveKeyboards", "let modes = UITextInputMode.activeInputModes"),
            ("UserDefaults", "UserDefaults.standard.set(1, forKey: \"k\")")
        ]
        for (category, source) in samples {
            XCTAssertEqual(scan(source).first?.category, category, "missed \(category): \(source)")
        }
    }

    /// Word boundaries: `statvfs`/`fstatfs` must not be mistaken for the
    /// file-timestamp `stat(`, and vice versa, or the reported category — and
    /// therefore the reason code an author would go looking for — is wrong.
    func testTokenMatchingRespectsWordBoundaries() {
        XCTAssertEqual(scan("statfs(path, &buffer)").first?.category, "DiskSpace")
        XCTAssertEqual(scan("stat(path, &buffer)").first?.category, "FileTimestamp")
        XCTAssertTrue(scan("let reinstated = value").isEmpty, "'stat' inside a word is not a hit")
    }

    /// `sysctlbyname` for `hw.machine` is how `device.model` is read, and it is
    /// deliberately not a covered API — if the sweep ever starts flagging it,
    /// the audit's conclusion changes.
    func testSysctlByNameIsNotACoveredAPI() {
        XCTAssertTrue(scan("guard sysctlbyname(\"hw.machine\", nil, &size, nil, 0) == 0 else { return nil }").isEmpty)
    }

    /// The queue file's only metadata write. Excluding a file from backup is
    /// not in the file-timestamp category, which is about *reading* creation
    /// and modification dates.
    func testExcludingAFileFromBackupIsNotACoveredAPI() {
        XCTAssertTrue(scan("values.isExcludedFromBackup = true").isEmpty)
        XCTAssertTrue(scan("try url.setResourceValues(values)").isEmpty)
    }
}
