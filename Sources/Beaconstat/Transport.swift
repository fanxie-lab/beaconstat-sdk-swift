import Foundation

struct HandshakeResponse: Decodable, Equatable {
    let siteToken: String
    let serverTime: String
}

enum TransportError: Error, Equatable {
    case network            // offline / timeout / 408 — retryable
    case unauthorized       // 401 — stop sending
    case badRequest         // 400 and every other non-retryable 4xx — drop the batch
    case payloadTooLarge    // 413 — the batch is too big; a smaller one may work
    case rateLimited        // 429 — back off
    case server             // 5xx — retryable
    case unexpected(Int)    // 1xx/3xx: shouldn't happen, and is NOT retried forever
    case decoding
}

/// Maps an HTTP status onto the delivery decision.
///
/// Previously only 202/401/400/429/5xx were enumerated and everything else fell
/// into `.unexpected`, which the core re-prepended to the front of the queue
/// indefinitely — so a 403 from a proxy, a 404 from a misconfigured endpoint, a
/// captive portal's 200, or a 413 blocked every event behind it for the life of
/// the install (H3).
enum HTTPStatusClassifier {
    static func classifySend(_ status: Int) -> Result<Void, TransportError> {
        switch status {
        // The contract says 202. Anything else in 2xx is not what we asked for,
        // but it is not retryable either — a captive portal's 200 HTML page
        // would otherwise loop forever. Accept and warn.
        case 200...299: return .success(())
        case 401: return .failure(.unauthorized)
        // The only two 4xx that mean "the same request may work later".
        case 408: return .failure(.network)
        case 429: return .failure(.rateLimited)
        case 413: return .failure(.payloadTooLarge)
        // Everything else in 4xx is the client's fault and resending is futile:
        // 403 (revoked key, or a proxy), 404 (wrong endpoint), 422, 451…
        case 400...499: return .failure(.badRequest)
        case 500...599: return .failure(.server)
        default: return .failure(.unexpected(status))
        }
    }
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

    /// - Parameter idempotencyKey: stable across retries of the same batch, so
    ///   the server can suppress a replay caused by a lost 202 (H6). Sent as a
    ///   header rather than a body field because the ingest DTO rejects unknown
    ///   body properties outright — see `PayloadEncoder.encode`. Outside the
    ///   signature's canonical payload, so it cannot invalidate it.
    func sendBatch(bodyData: Data, apiKey: String, siteToken: String, signature: String,
                   timestamp: String, isTest: Bool, idempotencyKey: String,
                   completion: @escaping (Result<Void, TransportError>) -> Void) {
        let path = isTest ? "v1/debug/events" : "v1/events"
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(siteToken, forHTTPHeaderField: "x-site-token")
        request.setValue(signature, forHTTPHeaderField: "x-signature")
        request.setValue(timestamp, forHTTPHeaderField: "x-timestamp")
        request.setValue(idempotencyKey, forHTTPHeaderField: "x-idempotency-key")
        request.httpBody = bodyData
        session.dataTask(with: request) { [logger] _, response, error in
            if error != nil { completion(.failure(.network)); return }
            guard let http = response as? HTTPURLResponse else { completion(.failure(.network)); return }
            if (200...299).contains(http.statusCode), http.statusCode != 202 {
                logger.debug("ingest answered \(http.statusCode) instead of 202 — treating the "
                             + "batch as accepted; check for a captive portal or a proxy")
            }
            completion(HTTPStatusClassifier.classifySend(http.statusCode))
        }.resume()
    }
}
