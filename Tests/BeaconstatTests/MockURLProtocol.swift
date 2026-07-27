import Foundation

/// URLProtocol mock: captures requests + bodies, returns stubbed responses.
/// URLSession moves `httpBody` into `httpBodyStream`, so we drain the stream.
///
/// ## Thread safety
///
/// `URLProtocol.startLoading()` runs on a URLSession loading thread, and there
/// is more than one of them. Everything mutable here therefore lives behind
/// `stateLock`, and a request and its body are stored as **one pair** rather
/// than appended to two arrays.
///
/// Both mattered. The unsynchronised `static var`s were a data race the moment a
/// test issued two requests at once — which the concurrency soak (test gap 8)
/// does by design. And the split arrays were a latent index crash even at low
/// concurrency: every `sentBodies()` helper in the suite reads
/// `capturedRequests` and then indexes `capturedBodies` with the enumeration
/// offset, so a request landing between the two reads could leave
/// `capturedBodies` one element short. Deriving both snapshots from a single
/// locked array of pairs makes the indices align by construction.
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

    /// One captured exchange. Request and body are stored together so a reader
    /// can never see one without the other.
    struct Captured {
        let request: URLRequest
        let body: Data
    }

    private static let stateLock = NSLock()
    private static var _handler: ((URLRequest) -> Stub)?
    private static var _captured: [Captured] = []
    private static var _holdEventsUntilReleased = false

    /// The stub source. Called on a URLSession loading thread, possibly
    /// concurrently, so it must be safe to invoke from anywhere.
    static var handler: ((URLRequest) -> Stub)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _handler }
        set { stateLock.lock(); _handler = newValue; stateLock.unlock() }
    }

    /// Every exchange so far, oldest first.
    static var captured: [Captured] {
        stateLock.lock(); defer { stateLock.unlock() }
        return _captured
    }

    static var capturedRequests: [URLRequest] { captured.map(\.request) }
    static var capturedBodies: [Data] { captured.map(\.body) }

    /// When true, the response to any `/events` request is held back after it's
    /// captured — until `releaseHeldEventsRequest()` is called — so tests can
    /// interleave work (e.g. `optOut()`) between "request received" and
    /// "response delivered" to reproduce in-flight-flush races deterministically.
    static var holdEventsUntilReleased: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _holdEventsUntilReleased }
        set { stateLock.lock(); _holdEventsUntilReleased = newValue; stateLock.unlock() }
    }

    private static var releaseSemaphore = DispatchSemaphore(value: 0)
    private static var receivedSemaphore = DispatchSemaphore(value: 0)

    // MARK: - Convenience readers

    /// Bodies of the captured requests whose path ends in `suffix`, decoded as
    /// UTF-8. Replaces the `capturedRequests.enumerated() { capturedBodies[i] }`
    /// idiom that was copied into a dozen test files and could index out of
    /// range under concurrency.
    static func bodies(forPathSuffix suffix: String) -> [String] {
        captured
            .filter { $0.request.url?.path.hasSuffix(suffix) ?? false }
            .compactMap { String(data: $0.body, encoding: .utf8) }
    }

    /// Every `/events` body concatenated — what the suite's `sentBodies()`
    /// helpers want.
    static func eventBodies() -> String { bodies(forPathSuffix: "/events").joined() }

    static func requests(forPathSuffix suffix: String) -> [URLRequest] {
        captured.map(\.request).filter { $0.url?.path.hasSuffix(suffix) ?? false }
    }

    static func reset() {
        stateLock.lock()
        _handler = nil
        _captured = []
        let wasHolding = _holdEventsUntilReleased
        _holdEventsUntilReleased = false
        stateLock.unlock()
        // If a previous test left a request parked (forgot to release, or bailed
        // out early via a failed assertion), wake it now instead of leaving it to
        // block for up to 5s on a semaphore instance we're about to discard — a
        // late-released thread could otherwise run `startLoading()`'s tail (using
        // whatever `handler` the *next* test installs) and append into that next
        // test's freshly-reset capture list, polluting it.
        if wasHolding { releaseSemaphore.signal() }
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

    private static func capture(_ request: URLRequest, body: Data) {
        stateLock.lock(); defer { stateLock.unlock() }
        _captured.append(Captured(request: request, body: body))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body: Data
        if let stream = request.httpBodyStream {
            body = Data(draining: stream)
        } else if let requestBody = request.httpBody {
            body = requestBody
        } else {
            body = Data()
        }
        MockURLProtocol.capture(request, body: body)
        if MockURLProtocol.holdEventsUntilReleased, request.url?.path.hasSuffix("/events") == true {
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
