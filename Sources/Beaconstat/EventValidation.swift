import Foundation

/// Client-side validation for USER events/keys (reserved `_bcs.*` names are
/// produced by the SDK itself and are not routed through this).
enum EventValidation {
    private static let nameRegex = try! NSRegularExpression(
        pattern: "\\A[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)*\\z")

    static func isValidUserEventName(_ name: String) -> Bool {
        if name.hasPrefix("_bcs.") { return false }
        return matches(nameRegex, name) && name.count <= 100
    }

    static func isValidUserKey(_ key: String) -> Bool {
        if key.hasPrefix("_bcs.") { return false }
        return matches(nameRegex, key) && key.count <= 100
    }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return regex.firstMatch(in: s, range: range) != nil
    }
}
