import XCTest
@testable import Beaconstat

final class RetryPolicyTests: XCTestCase {
    func testExponentialSequence() {
        XCTAssertEqual(RetryPolicy.delay(forAttempt: 1, maxRetries: 3), 2)
        XCTAssertEqual(RetryPolicy.delay(forAttempt: 2, maxRetries: 3), 4)
        XCTAssertEqual(RetryPolicy.delay(forAttempt: 3, maxRetries: 3), 8)
    }
    func testCapAndBounds() {
        XCTAssertEqual(RetryPolicy.delay(forAttempt: 10, maxRetries: 20, cap: 30), 30)
        XCTAssertNil(RetryPolicy.delay(forAttempt: 4, maxRetries: 3))
        XCTAssertNil(RetryPolicy.delay(forAttempt: 0, maxRetries: 3))
    }
}
