import XCTest
@testable import Beaconstat

final class EventValidationTests: XCTestCase {
    func testValidUserNames() {
        XCTAssertTrue(EventValidation.isValidUserEventName("feature_used"))
        XCTAssertTrue(EventValidation.isValidUserEventName("billing.upgraded"))
    }
    func testInvalidUserNames() {
        XCTAssertFalse(EventValidation.isValidUserEventName("_bcs.session_started")) // reserved prefix
        XCTAssertFalse(EventValidation.isValidUserEventName("SessionStarted"))
        XCTAssertFalse(EventValidation.isValidUserEventName("session-started"))
        XCTAssertFalse(EventValidation.isValidUserEventName(String(repeating: "a", count: 101)))
    }
    func testKeys() {
        XCTAssertTrue(EventValidation.isValidUserKey("format"))
        XCTAssertTrue(EventValidation.isValidUserKey("export.format"))
        XCTAssertFalse(EventValidation.isValidUserKey("_bcs.session.id"))
        XCTAssertFalse(EventValidation.isValidUserKey("Format"))
    }
    func testRejectsTrailingWhitespace() {
        XCTAssertFalse(EventValidation.isValidUserEventName("feature_used\n"))
        XCTAssertFalse(EventValidation.isValidUserKey("format\n"))
    }
}
