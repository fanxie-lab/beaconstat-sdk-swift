import Foundation

/// Validated SDK configuration. `init` throws on bad credentials; the public
/// facade catches and disables the SDK rather than surfacing the error.
struct Configuration {
    let publicKey: String
    let hmacSecret: String
    let baseURL: URL
    let options: BeaconstatOptions

    enum ValidationError: Error, Equatable {
        case invalidPublicKey
        case invalidHmacSecret
    }

    static let defaultBaseURL = URL(string: "https://ingest.beaconstat.com")!

    init(publicKey: String, hmacSecret: String, options: BeaconstatOptions) throws {
        // Public key: "bcs_pub_" prefix with a non-empty body.
        let prefix = "bcs_pub_"
        guard publicKey.hasPrefix(prefix), publicKey.count > prefix.count else {
            throw ValidationError.invalidPublicKey
        }
        // HMAC secret: exactly 64 hex characters.
        guard hmacSecret.count == 64, hmacSecret.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw ValidationError.invalidHmacSecret
        }
        self.publicKey = publicKey
        self.hmacSecret = hmacSecret
        self.options = options
        self.baseURL = options.endpoint ?? Configuration.defaultBaseURL
    }
}
