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

/// Sanitizer for host-supplied scalars that land on **reserved** `_bcs.apple.*`
/// dimensions: a quick-action `type`, a widget `kind`/`family`, a push
/// `category`/`actionId` (M2).
///
/// These bypassed `track()`'s validation entirely and went onto the wire
/// verbatim. That matters because dynamic quick actions and widget deep links
/// conventionally encode their *target* in the identifier —
/// `UIApplicationShortcutItem(type: "openChat:user@example.com")`,
/// `"openDoc:\(documentUUID)"` — which made a reserved dimension both a PII
/// channel and unbounded in cardinality. The deep-link path already refused to
/// carry anything but a scheme and a host; this is the same rule for the rest
/// of the entry-point family.
///
/// A reserved dimension is a *label*: short, low-cardinality, safe to group by.
/// So:
///
/// 1. Truncate at the first structural delimiter (`:` `/` `?` `#`). Everything
///    before it is the action; everything after it is the instance.
/// 2. Trim surrounding whitespace.
/// 3. Reject what is left unless it is a non-empty ASCII label of at most 64
///    characters drawn from `A-Z a-z 0-9 . _ -`.
///
/// Rejection drops the *property*, never the event: "the app was opened from a
/// quick action" is the signal worth reporting, and the SDK should not silently
/// substitute a mangled label for a real one.
///
/// Not applied to `_bcs.apple.url_scheme` / `url_host`, which the SDK derives
/// itself from `URL` components and which legitimately contain non-ASCII (IDN)
/// hosts.
enum ReservedValue {
    /// Longest label kept. Real quick-action types, widget kinds and
    /// notification categories are reverse-DNS identifiers well inside this;
    /// anything longer is carrying a payload.
    static let maxLength = 64

    private static let delimiters: Set<Character> = [":", "/", "?", "#"]

    static func sanitize(_ raw: String) -> String? {
        let head = raw.prefix { !delimiters.contains($0) }
        let label = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= maxLength, label.allSatisfy(isLabelCharacter) else {
            return nil
        }
        return label
    }

    private static func isLabelCharacter(_ c: Character) -> Bool {
        guard let ascii = c.asciiValue else { return false }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        default:
            return c == "." || c == "_" || c == "-"
        }
    }
}
