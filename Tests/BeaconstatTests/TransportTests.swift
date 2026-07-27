import XCTest
@testable import Beaconstat

final class TransportTests: XCTestCase {
    private let base = URL(string: "https://ingest.beaconstat.com")!
    private func transport() -> Transport {
        Transport(session: .mocked(), baseURL: base, logger: Logger(enabled: false, sink: { _ in }))
    }
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    func testHandshakeSuccessDecodes() {
        MockURLProtocol.handler = { _ in
            .init(statusCode: 200,
                  data: Data(#"{"siteToken":"bcs_tok_abc","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
        }
        let exp = expectation(description: "handshake")
        transport().handshake(apiKey: "bcs_pub_x", fingerprint: "fp", productVersion: "1.0.0",
                              environmentType: "production") { result in
            guard case .success(let resp) = result else { return XCTFail("expected success") }
            XCTAssertEqual(resp.siteToken, "bcs_tok_abc")
            XCTAssertEqual(resp.serverTime, "2026-04-19T10:30:00.000Z")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        let req = MockURLProtocol.capturedRequests.first!
        XCTAssertEqual(req.url?.absoluteString, "https://ingest.beaconstat.com/v1/handshake")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "bcs_pub_x")
    }

    func testSendBatchSendsSignedHeadersAndExactBodyToProdEndpoint() {
        MockURLProtocol.handler = { _ in .init(statusCode: 202, data: Data(#"{"success":true,"eventsQueued":1}"#.utf8)) }
        let body = Data(#"{"a":"b"}"#.utf8)
        let exp = expectation(description: "send")
        transport().sendBatch(bodyData: body, apiKey: "bcs_pub_x", siteToken: "bcs_tok_abc",
                             signature: "deadbeef", timestamp: "2026-04-19T10:30:00.000Z",
                             isTest: false, idempotencyKey: "idem-abc") { result in
            guard case .success = result else { return XCTFail("expected success") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        let req = MockURLProtocol.capturedRequests.first!
        XCTAssertEqual(req.url?.absoluteString, "https://ingest.beaconstat.com/v1/events")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-site-token"), "bcs_tok_abc")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-signature"), "deadbeef")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-timestamp"), "2026-04-19T10:30:00.000Z")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-idempotency-key"), "idem-abc")
        XCTAssertEqual(MockURLProtocol.capturedBodies.first, body) // exact bytes preserved
    }

    func testTestModeRoutesToDebugEndpoint() {
        MockURLProtocol.handler = { _ in .init(statusCode: 202) }
        let exp = expectation(description: "send")
        transport().sendBatch(bodyData: Data("{}".utf8), apiKey: "k", siteToken: "t",
                             signature: "s", timestamp: "ts", isTest: true,
                             idempotencyKey: "k") { _ in exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(MockURLProtocol.capturedRequests.first?.url?.absoluteString,
                       "https://ingest.beaconstat.com/v1/debug/events")
    }

    func testStatusMapping() {
        for (code, expected) in [(401, TransportError.unauthorized), (400, .badRequest),
                                 (429, .rateLimited), (503, .server)] {
            MockURLProtocol.reset()
            MockURLProtocol.handler = { _ in .init(statusCode: code) }
            let exp = expectation(description: "s\(code)")
            transport().sendBatch(bodyData: Data(), apiKey: "k", siteToken: "t", signature: "s",
                                 timestamp: "ts", isTest: false, idempotencyKey: "k") { result in
                guard case .failure(let e) = result else { return XCTFail("expected failure") }
                XCTAssertEqual(e, expected)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 2)
        }
    }

    func testTestModeResolver() {
        // forceProduction/forceTest ignore run context.
        XCTAssertFalse(TestModeResolver.routesToTest(.forceProduction, isDebug: true, isSimulator: true, isTestFlight: true, routeTestFlightToTest: true))
        XCTAssertTrue(TestModeResolver.routesToTest(.forceTest, isDebug: false, isSimulator: false, isTestFlight: false, routeTestFlightToTest: false))
        // automatic: DEBUG or simulator route to test.
        XCTAssertTrue(TestModeResolver.routesToTest(.automatic, isDebug: true, isSimulator: false, isTestFlight: false, routeTestFlightToTest: false))
        XCTAssertFalse(TestModeResolver.routesToTest(.automatic, isDebug: false, isSimulator: false, isTestFlight: false, routeTestFlightToTest: false))
        // automatic + TestFlight: only routes to test when opted in.
        XCTAssertFalse(TestModeResolver.routesToTest(.automatic, isDebug: false, isSimulator: false, isTestFlight: true, routeTestFlightToTest: false))
        XCTAssertTrue(TestModeResolver.routesToTest(.automatic, isDebug: false, isSimulator: false, isTestFlight: true, routeTestFlightToTest: true))
    }
}
