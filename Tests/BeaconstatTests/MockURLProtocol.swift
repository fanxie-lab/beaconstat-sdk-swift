import Foundation

/// URLProtocol mock: captures requests + bodies, returns stubbed responses.
/// URLSession moves `httpBody` into `httpBodyStream`, so we drain the stream.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let error: Error?
        /// Response headers. Needed to exercise `Retry-After` (M9); the mock
        /// used to hard-code `headerFields: nil`.
        let headers: [String: String]?
        init(statusCode: Int, data: Data = Data(), error: Error? = nil,
             headers: [String: String]? = nil) {
            self.statusCode = statusCode; self.data = data; self.error = error
            self.headers = headers
        }
    }

    static var handler: ((URLRequest) -> Stub)?
    static var capturedRequests: [URLRequest] = []
    static var capturedBodies: [Data] = []

    /// When true, the response to any `/events` request is held back after it's
    /// captured — until `releaseHeldEventsRequest()` is called — so tests can
    /// interleave work (e.g. `optOut()`) between "request received" and
    /// "response delivered" to reproduce in-flight-flush races deterministically.
    static var holdEventsUntilReleased = false
    private static var releaseSemaphore = DispatchSemaphore(value: 0)
    private static var receivedSemaphore = DispatchSemaphore(value: 0)

    static func reset() {
        handler = nil; capturedRequests = []; capturedBodies = []
        // If a previous test left a request parked (forgot to release, or bailed
        // out early via a failed assertion), wake it now instead of leaving it to
        // block for up to 5s on a semaphore instance we're about to discard — a
        // late-released thread could otherwise run `startLoading()`'s tail (using
        // whatever `handler` the *next* test installs) and append into that next
        // test's freshly-reset `capturedRequests`/`capturedBodies`, polluting it.
        if holdEventsUntilReleased { releaseSemaphore.signal() }
        holdEventsUntilReleased = false
        releaseSemaphore = DispatchSemaphore(value: 0)
        receivedSemaphore = DispatchSemaphore(value: 0)
    }

    /// Blocks (with a timeout) until a held `/events` request has been captured
    /// and is parked waiting on `releaseHeldEventsRequest()`.
    static func waitForHeldEventsRequest(timeout: TimeInterval = 2) {
        _ = receivedSemaphore.wait(timeout: .now() + timeout)
    }

    /// Lets a request parked by `holdEventsUntilReleased` proceed to its stubbed response.
    static func releaseHeldEventsRequest() {
        releaseSemaphore.signal()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.capturedRequests.append(request)
        if let stream = request.httpBodyStream {
            MockURLProtocol.capturedBodies.append(Data(draining: stream))
        } else if let body = request.httpBody {
            MockURLProtocol.capturedBodies.append(body)
        } else {
            MockURLProtocol.capturedBodies.append(Data())
        }
        if MockURLProtocol.holdEventsUntilReleased, request.url!.path.hasSuffix("/events") {
            MockURLProtocol.receivedSemaphore.signal()
            _ = MockURLProtocol.releaseSemaphore.wait(timeout: .now() + 5)
        }
        guard let stub = MockURLProtocol.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.statusCode,
                                           httpVersion: "HTTP/1.1", headerFields: stub.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Data {
    init(draining stream: InputStream) {
        self.init()
        stream.open(); defer { stream.close() }
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read > 0 { append(buffer, count: read) } else { break }
        }
    }
}

extension URLSession {
    static func mocked() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
