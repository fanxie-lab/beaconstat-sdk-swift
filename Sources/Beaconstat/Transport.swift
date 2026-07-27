import Foundation

struct HandshakeResponse: Decodable, Equatable, Sendable {
    let siteToken: String
    let serverTime: String
}

enum TransportError: Error, Equatable, Sendable {
    case network            // offline / timeout / 408 — retryable
    case unauthorized       // 401 — stop sending
    case badRequest         // 400 and every other non-retryable 4xx — drop the batch
    case payloadTooLarge    // 413 — the batch is too big; a smaller one may work
    /// 429 — back off. Carries a parsed `Retry-After` when the server sent one.
    case rateLimited(retryAfter: TimeInterval?)
    /// 5xx — retryable. 503 commonly carries `Retry-After` during a planned
    /// outage, so it is honoured here too.
    case server(retryAfter: TimeInterval?)
    case unexpected(Int)    // 1xx/3xx: shouldn't happen, and is NOT retried forever
    case decoding

    /// How long the server asked us to wait, if it said anything.
    var retryAfter: TimeInterval? {
        switch self {
        case .rateLimited(let value), .server(let value): return value
        default: return nil
        }
    }
}

/// Maps an HTTP status onto the delivery decision.
///
/// Previously only 202/401/400/429/5xx were enumerated and everything else fell
/// into `.unexpected`, which the core re-prepended to the front of the queue
/// indefinitely — so a 403 from a proxy, a 404 from a misconfigured endpoint, a
/// captive portal's 200, or a 413 blocked every event behind it for the life of
/// the install (H3).
enum HTTPStatusClassifier {
    static func classifySend(_ status: Int,
                             retryAfter: TimeInterval? = nil) -> Result<Void, TransportError> {
        switch status {
        // The contract says 202. Anything else in 2xx is not what we asked for,
        // but it is not retryable either — a captive portal's 200 HTML page
        // would otherwise loop forever. Accept and warn.
        case 200...299: return .success(())
        case 401: return .failure(.unauthorized)
        // The only two 4xx that mean "the same request may work later".
        case 408: return .failure(.network)
        case 429: return .failure(.rateLimited(retryAfter: retryAfter))
        case 413: return .failure(.payloadTooLarge)
        // Everything else in 4xx is the client's fault and resending is futile:
        // 403 (revoked key, or a proxy), 404 (wrong endpoint), 422, 451…
        case 400...499: return .failure(.badRequest)
        case 500...599: return .failure(.server(retryAfter: retryAfter))
        default: return .failure(.unexpected(status))
        }
    }
}

/// The `URLSession` the SDK sends telemetry on (M11).
///
/// `URLSession(configuration: .default)` shares the host app's
/// `HTTPCookieStorage` — so a `Set-Cookie` from the ingest host is stored and
/// replayed on the app's own requests — and its `URLCache`. Neither has any
/// business being touched by an analytics transport.
enum TelemetrySession {
    /// Idle timeout per request. The 60 s default is a long time to hold a
    /// background assertion open for a request that is not going to complete,
    /// and the queue is durable, so giving up early costs nothing (H2).
    static let requestTimeout: TimeInterval = 15
    /// Ceiling on one whole request including retries inside URLSession.
    static let resourceTimeout: TimeInterval = 60

    static func make(timeout: TimeInterval = TelemetrySession.requestTimeout) -> URLSession {
        // `.ephemeral` already keeps cookies and cache in memory; nil-ing them
        // states the intent and removes them entirely.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = resourceTimeout
        // Backoff, reachability and the durable queue are the SDK's own job;
        // letting URLSession park a request indefinitely would sit underneath
        // all three.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

/// Thin URLSession transport. Signing/timestamps are computed by the core and
/// passed in — Transport never re-encodes the body.
/// Genuinely `Sendable`, no escape hatch: every member is an immutable `let` of
/// a `Sendable` type. That only became true once `Logger` was made `Sendable` —
/// the logger is captured by both completion handlers, so a non-`Sendable` one
/// produced a warning in each (M13).
final class Transport: Sendable {
    private let session: URLSession
    private let baseURL: URL
    private let logger: Logger
    /// Wall clock for resolving an HTTP-date `Retry-After`. Injectable so the
    /// parse is testable without waiting.
    private let now: @Sendable () -> Date

    init(session: URLSession, baseURL: URL, logger: Logger,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.baseURL = baseURL
        self.logger = logger
        self.now = now
    }

    /// `Transport` used to discard `allHeaderFields` entirely, so a 429's
    /// `Retry-After` was invisible and the SDK backed off on its own guess
    /// instead of the server's instruction (M9).
    /// A `@Sendable` closure rather than a method, because it is captured by
    /// both completion handlers, which `URLSession` requires to be `@Sendable`.
    /// Capturing `self` there would drag the whole transport across the boundary.
    private var retryAfter: @Sendable (HTTPURLResponse) -> TimeInterval? {
        let now = self.now
        return { http in RetryAfter.parse(http.value(forHTTPHeaderField: "Retry-After"), now: now()) }
    }

    func handshake(apiKey: String, fingerprint: String, productVersion: String,
                   environmentType: String,
                   completion: @escaping @Sendable (Result<HandshakeResponse, TransportError>) -> Void) {
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
        session.dataTask(with: request) { [logger, retryAfter] data, response, error in
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
            case 429: completion(.failure(.rateLimited(retryAfter: retryAfter(http))))
            case 500...599: completion(.failure(.server(retryAfter: retryAfter(http))))
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
                   completion: @escaping @Sendable (Result<Void, TransportError>) -> Void) {
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
        session.dataTask(with: request) { [logger, retryAfter] _, response, error in
            if error != nil { completion(.failure(.network)); return }
            guard let http = response as? HTTPURLResponse else { completion(.failure(.network)); return }
            if (200...299).contains(http.statusCode), http.statusCode != 202 {
                logger.debug("ingest answered \(http.statusCode) instead of 202 — treating the "
                             + "batch as accepted; check for a captive portal or a proxy")
            }
            completion(HTTPStatusClassifier.classifySend(http.statusCode,
                                                         retryAfter: retryAfter(http)))
        }.resume()
    }
}
