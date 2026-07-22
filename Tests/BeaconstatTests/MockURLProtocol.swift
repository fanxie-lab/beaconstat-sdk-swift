import Foundation

/// URLProtocol mock: captures requests + bodies, returns stubbed responses.
/// URLSession moves `httpBody` into `httpBodyStream`, so we drain the stream.
final class MockURLProtocol: URLProtocol {
    struct Stub { let statusCode: Int; let data: Data; let error: Error?
        init(statusCode: Int, data: Data = Data(), error: Error? = nil) {
            self.statusCode = statusCode; self.data = data; self.error = error
        }
    }

    static var handler: ((URLRequest) -> Stub)?
    static var capturedRequests: [URLRequest] = []
    static var capturedBodies: [Data] = []

    static func reset() {
        handler = nil; capturedRequests = []; capturedBodies = []
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
        guard let stub = MockURLProtocol.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.statusCode,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
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
