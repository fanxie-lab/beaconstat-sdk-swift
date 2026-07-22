import Foundation

struct HandshakeResponse: Decodable, Equatable {
    let siteToken: String
    let serverTime: String
}

enum TransportError: Error, Equatable {
    case network        // offline/timeout — retryable
    case unauthorized   // 401 — stop sending
    case badRequest     // 400 — drop the batch (poison)
    case rateLimited    // 429 — back off
    case server         // 5xx — retryable
    case unexpected(Int)
    case decoding
}

/// Thin URLSession transport. Signing/timestamps are computed by the core and
/// passed in — Transport never re-encodes the body.
final class Transport {
    private let session: URLSession
    private let baseURL: URL
    private let logger: Logger

    init(session: URLSession, baseURL: URL, logger: Logger) {
        self.session = session
        self.baseURL = baseURL
        self.logger = logger
    }

    func handshake(apiKey: String, fingerprint: String, productVersion: String,
                   environmentType: String,
                   completion: @escaping (Result<HandshakeResponse, TransportError>) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/handshake"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        let payload: [String: String] = [
            "fingerprint": fingerprint,
            "productVersion": productVersion,
            "environmentType": environmentType,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        session.dataTask(with: request) { [logger] data, response, error in
            if error != nil { completion(.failure(.network)); return }
            guard let http = response as? HTTPURLResponse else { completion(.failure(.network)); return }
            switch http.statusCode {
            case 200:
                guard let data, let decoded = try? JSONDecoder().decode(HandshakeResponse.self, from: data) else {
                    logger.debug("handshake decode failed"); completion(.failure(.decoding)); return
                }
                completion(.success(decoded))
            case 401: completion(.failure(.unauthorized))
            case 400: completion(.failure(.badRequest))
            case 429: completion(.failure(.rateLimited))
            case 500...599: completion(.failure(.server))
            default: completion(.failure(.unexpected(http.statusCode)))
            }
        }.resume()
    }

    func sendBatch(bodyData: Data, apiKey: String, siteToken: String, signature: String,
                   timestamp: String, isTest: Bool,
                   completion: @escaping (Result<Void, TransportError>) -> Void) {
        let path = isTest ? "v1/debug/events" : "v1/events"
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(siteToken, forHTTPHeaderField: "x-site-token")
        request.setValue(signature, forHTTPHeaderField: "x-signature")
        request.setValue(timestamp, forHTTPHeaderField: "x-timestamp")
        request.httpBody = bodyData
        session.dataTask(with: request) { _, response, error in
            if error != nil { completion(.failure(.network)); return }
            guard let http = response as? HTTPURLResponse else { completion(.failure(.network)); return }
            switch http.statusCode {
            case 202: completion(.success(()))
            case 401: completion(.failure(.unauthorized))
            case 400: completion(.failure(.badRequest))
            case 429: completion(.failure(.rateLimited))
            case 500...599: completion(.failure(.server))
            default: completion(.failure(.unexpected(http.statusCode)))
            }
        }.resume()
    }
}
