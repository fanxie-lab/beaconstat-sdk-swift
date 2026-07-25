# Changelog

## 1.0.0

First stable release.

- Zero-dependency SPM package; iOS 15+ / macOS 12+ (tvOS/watchOS/visionOS code paths present).
- `configure` + `track`; automatic `_bcs.install_detected` / `_bcs.session_started`.
- HMAC-SHA256 request signing (wire-verified against the backend); offline-first
  persistent queue with batching, exponential-backoff retry, and reconnect-triggered flush.
- Apple lifecycle events: `app_updated`, `app_backgrounded` (+ flush-on-background),
  `opened_from_url` / activity (scheme+host only), `opened_from_shortcut`, `opened_from_widget`.
- Opt-in `push_received` / `push_opened` with strict payload scrubbing.
- Full environment collection (device / run-context / locale / accessibility).
- Host-controlled `optOut()` kill switch; Keychain-backed identity with in-memory fallback.
- Automatic test-mode routing (DEBUG / simulator / optional TestFlight).
