import XCTest
@testable import Beaconstat

/// M2 — unit-level contract for the sanitizer that guards host-supplied scalars
/// on reserved `_bcs.apple.*` dimensions.
final class ReservedValueTests: XCTestCase {
    func testPlainIdentifiersPassThroughUnchanged() {
        for value in ["com.example.newItem", "systemSmall", "MESSAGE_CATEGORY",
                      "REPLY_ACTION", "Today-Widget", "v2"] {
            XCTAssertEqual(ReservedValue.sanitize(value), value)
        }
    }

    /// The review's exact example: a dynamic quick action encoding its target.
    func testStructuralDelimiterTruncatesToTheActionToken() {
        XCTAssertEqual(ReservedValue.sanitize("openChat:user@example.com"), "openChat")
        XCTAssertEqual(ReservedValue.sanitize("openDoc:550E8400-E29B-41D4-A716-446655440000"), "openDoc")
        XCTAssertEqual(ReservedValue.sanitize("openDoc/42"), "openDoc")
        XCTAssertEqual(ReservedValue.sanitize("openDoc?id=42"), "openDoc")
        XCTAssertEqual(ReservedValue.sanitize("openDoc#section"), "openDoc")
    }

    /// No delimiter to truncate at and the value is plainly an identifier —
    /// there is nothing safe to keep, so keep nothing.
    func testValuesThatAreEntirelyIdentifyingAreRejected() {
        XCTAssertNil(ReservedValue.sanitize("user@example.com"))
        XCTAssertNil(ReservedValue.sanitize("+447700900123"))
        XCTAssertNil(ReservedValue.sanitize("user%40example.com"))
    }

    func testEmptyAndWhitespaceOnlyValuesAreRejected() {
        XCTAssertNil(ReservedValue.sanitize(""))
        XCTAssertNil(ReservedValue.sanitize("   "))
        XCTAssertNil(ReservedValue.sanitize(":everythingAfterTheColon"))
    }

    /// A reserved dimension is a low-cardinality label, not a payload.
    func testOverlongValuesAreRejectedRatherThanTruncated() {
        XCTAssertEqual(ReservedValue.sanitize(String(repeating: "a", count: 64))?.count, 64)
        XCTAssertNil(ReservedValue.sanitize(String(repeating: "a", count: 65)))
    }

    func testNonAsciiIsRejected() {
        XCTAssertNil(ReservedValue.sanitize("café"))
        XCTAssertNil(ReservedValue.sanitize("🎉"))
        XCTAssertNil(ReservedValue.sanitize("open Chat"))
        XCTAssertNil(ReservedValue.sanitize("open\nChat"))
    }

    func testSurroundingWhitespaceIsTrimmedNotRejected() {
        XCTAssertEqual(ReservedValue.sanitize("  openChat  "), "openChat")
        XCTAssertEqual(ReservedValue.sanitize(" openChat : x"), "openChat")
    }

    /// Whatever comes out must itself be safe to send: no delimiters, nothing
    /// outside the allowlist, never empty, never over the cap.
    func testOutputIsAlwaysASafeLabel() {
        let inputs = ["com.example.a", "openChat:user@example.com", "a/b/c", "  x  ",
                      "", "user@example.com", String(repeating: "z", count: 200),
                      "🎉", "A_B-C.D", "?", "::::"]
        for input in inputs {
            guard let out = ReservedValue.sanitize(input) else { continue }
            XCTAssertFalse(out.isEmpty)
            XCTAssertLessThanOrEqual(out.count, 64)
            for character in out {
                XCTAssertTrue(character.isASCII, "\(input) -> \(out)")
                XCTAssertFalse(":/?#@ ".contains(character), "\(input) -> \(out)")
            }
        }
    }

    /// Sanitizing an already-sanitized value must be a no-op, or the wire value
    /// would depend on how many times it happened to be passed through.
    func testSanitizeIsIdempotent() {
        for input in ["com.example.newItem", "openChat:user@example.com", " a/b ", "x"] {
            guard let once = ReservedValue.sanitize(input) else { continue }
            XCTAssertEqual(ReservedValue.sanitize(once), once)
        }
    }
}
