# Changelog

## 1.1.0

> ## ⚠️ THIS RELEASE CONTAINS BREAKING CHANGES
>
> Do not upgrade without reading [MIGRATION.md](MIGRATION.md). Despite the minor
> version number, **this release can break your build and will change your
> data.**
>
> **Breaks the build** (one item, and the compiler will point at it):
>
> 1. **`configure` is now `@MainActor`.** Any call from a background thread or a
>    detached task no longer compiles.
>
> **Breaks silently at runtime** — these compile fine and behave differently:
>
> 2. **`collectAccessibility` now defaults to `false`.** The `accessibility.*`
>    keys stop arriving unless you opt in.
> 3. **A non-`https` `endpoint` is now rejected.** The SDK refuses to configure
>    unless you also set `allowInsecureEndpoint = true`.
> 4. **`optOut()` now deletes local identity.** A later `optIn()` is a brand-new
>    anonymous install, with a new `install_detected` and
>    `is_first_session=true`.
> 5. **Out-of-range `BeaconstatOptions` numerics are clamped**, not used as
>    given.
> 6. **`BeaconstatOptions.init` gained three parameters**
>    (`keychainAccessGroup`, `sendEventIds`, `allowInsecureEndpoint`), one of
>    them inserted mid-list, so a fully positional memberwise call binds
>    differently.
> 7. **Reserved Apple-entry values are sanitised** — a quick-action type, widget
>    kind, push category or action id may now be truncated at a delimiter or
>    dropped entirely.
> 8. **macOS `app_backgrounded` means something different**, and historic macOS
>    data is not comparable. watchOS now emits lifecycle events where it emitted
>    none.
> 9. **Keychain items moved** to `…ThisDeviceOnly`, and a new `identity.json`
>    file appears alongside `queue.json`.
>
> All nine are covered with before/after code in
> [MIGRATION.md](MIGRATION.md).

A correctness release. An adversarial review of 1.0.0 found 1 Critical, 6 High,
14 Medium and 10 Low issues; all of them are fixed here, along with the review's
eleven test gaps. **Every adopter should upgrade** — 1.0.0 could silently stop
sending for an entire app run, and silently lose data in several ordinary
situations.

### Fixed — data loss and delivery

- **A single failed handshake no longer disables the SDK for the whole app
  run.** The handshake ran exactly once, from `configure()`; on failure
  `siteToken` stayed `nil`, every flush path bailed on it, and nothing ever
  retried. A cold launch with no signal meant zero events sent for the entire
  session — and the site token that would have kept it working was written to
  secure storage but never read back. The token is now loaded at `configure()`,
  and any flush trigger re-attempts the handshake.
- **A background flush can no longer lose the batch.** The queue used to delete
  events from disk at checkout and re-add them if the send failed, so for the
  duration of a request they existed only in a closure's capture list. iOS
  suspends roughly 5 s after backgrounding and `flushOnBackground` is on by
  default, so this was the most likely real-world loss path. The model is now
  mark-in-flight / delete-on-ack: an unacknowledged batch stays on disk and
  replays after termination. A `ProcessInfo.performExpiringActivity` assertion
  (extension-safe, unlike `UIApplication.beginBackgroundTask`) holds the process
  while a background flush is in flight.
- **A permanently-rejected batch no longer blocks every event behind it.** Only
  202/401/400/429/5xx were classified; everything else — including 403, 404, 413
  and a captive portal's 200 — was re-queued at the *front* forever. 4xx is now
  dropped as poison, non-202 2xx is accepted with a warning, and 413 halves an
  adaptive batch-size budget and retries rather than discarding real data.
- **Overflow eviction no longer sacrifices the events the SDK exists to
  report.** `_bcs.install_detected`, `_bcs.session_started` and
  `_bcs.apple.app_updated` are enqueued first, so front-eviction dropped them
  first. They are now evicted last, and an in-flight batch is never a candidate.
- **Retries have jitter and honour `Retry-After`.** The schedule was a fixed
  2 s / 4 s / 8 s across every install, so a recovering server got a synchronised
  thundering herd. After the attempt budget is spent, a fresh jittered round is
  scheduled in minutes — previously the code deferred to the periodic timer,
  which in Release is four hours away while the queue cap evicts underneath it.
- **Encode-and-sign now happen before a batch is checked out**, so an encode
  failure leaves the batch queued instead of destroying it.
- Queue write failures are reported instead of silently swallowed.

### Fixed — identity and privacy

- **Secure storage no longer degrades the whole process to memory.** A single
  failed availability probe used to strand the SDK on an in-memory store for its
  entire lifetime, so every launch generated a fresh install id, re-fired
  `install_detected`, and reported `is_first_session=true` — a handful of real
  installs reporting as hundreds. Storage is now a read-through stack (Keychain →
  durable on-disk mirror → memory) that heals as soon as the Keychain works, and
  the degradation is logged. If no tier is durable, the SDK stays silent for that
  run rather than reporting a phantom install.
- **Keychain items moved to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`**,
  so identity cannot ride an encrypted backup onto a second device and merge two
  installs into one.
- **`optOut()` now purges local identity** — install id, site token and session
  history — so it is the device half of a "delete my data" request. It also
  stops the network-path monitor, the lifecycle observers and the timers, which
  previously kept running for the app's lifetime.
- **`collectAccessibility` now defaults to `false`.** Seven disability-adjacent
  settings were collected by default; alongside device model, screen metrics,
  timezone, locale and OS version they sharpen the fingerprint materially, and
  every adopter inherited a privacy-manifest obligation they had not opted into.
- **Host-supplied values on reserved `_bcs.apple.*` dimensions are sanitised.**
  Quick-action types, widget kinds and notification categories went onto the wire
  verbatim while `track()` enforced a key regex and length caps, so
  `UIApplicationShortcutItem(type: "openChat:user@example.com")` leaked PII onto
  a reserved dimension and blew up its cardinality.
- **`optIn()` works.** `configure()` used to return before storing the
  configuration when the opt-out flag was set, so the documented consent
  sequence — `optOut()` → `configure()` → `optIn()` — left every later `track()`
  silently dropped until the next cold launch.
- `isOptedOut` is now consistent with the call that just returned, and is served
  from memory instead of costing a Keychain round trip per read (it was consulted
  around nine times per event).

### Fixed — platforms and lifecycle

- **visionOS now compiles.** `UIScreen` is unavailable there and
  `EnvironmentCollector` referenced it unconditionally. visionOS was advertised
  from 1.0.0 and had never been built. It now reports no `device.screen_*` keys,
  deliberately: a visionOS app has no screen, it has volumes and windows the user
  resizes and moves in space.
- **watchOS now has lifecycle events.** The UIKit branch excluded it and the
  AppKit branch did not match, so `app_backgrounded` and foreground session
  resume silently never fired.
- **macOS no longer reports every app switch as backgrounding.**
  `didResignActive` fires on ⌘-Tab, on clicking another window and on Mission
  Control; a Mac user switching apps 200×/day produced 200
  `_bcs.apple.app_backgrounded` events and 200 POSTs. `app_backgrounded` is now
  `didHide` / `willTerminate`; losing focus flushes and emits nothing.
  **Historic macOS `app_backgrounded` data is not comparable with 1.1.0 data.**
- `Package.swift` declares iOS 15, macOS 12, tvOS 15, watchOS 8 and visionOS 1.
  Undeclared platforms previously inherited the toolchain's default deployment
  target.

### Fixed — configuration and API

- **`BeaconstatOptions` numerics are clamped instead of trusted.**
  `flushInterval: 0` scheduled a `DispatchSourceTimer` with `repeating: 0`, which
  fires roughly 345,000 times a second, each fire pinning a core and issuing a
  synchronous Keychain read. `0` is the natural guess for "flush immediately".
  Clamping degrades tuning; it never disables analytics, and every clamp is
  logged.
- **`configure` is `@MainActor`.** It reads main-thread-only UIKit state, which
  off-main yields defaults and trips the Main Thread Checker.
- **Non-`https` endpoints are rejected** unless `allowInsecureEndpoint` is set.
  The site token and the request signature travel in headers.
- **Analytics no longer share the host app's cookie store or URL cache.** The
  transport uses an ephemeral session with explicit timeouts.
- **A second `configure()` applies the new options** instead of silently keeping
  the old ones, and invalidates the previous `URLSession` instead of stranding
  it.
- Per-event property truncation is deterministic; it previously depended on
  Swift's per-instance hash seed, so two identical `track()` calls could keep
  different columns.

### Added

- `Beaconstat.shutdown()` — releases the timers, the path monitor, the lifecycle
  observers and the `URLSession`. Optional; `configure()` afterwards brings the
  SDK back.
- `BeaconstatOptions.keychainAccessGroup` — share one install identity between an
  app and its extensions, so a `UNNotificationServiceExtension` calling
  `pushReceived` is not attributed to a phantom install. Requires the matching
  **Keychain Sharing** entitlement on both targets.
- `BeaconstatOptions.allowInsecureEndpoint` and `BeaconstatOptions.sendEventIds`.
- `BeaconstatOptions.Limits` — the documented, enforced range of every numeric
  option.
- A stable per-event idempotency id, sent as the `x-idempotency-key` request
  header so a lost 202 does not duplicate events server-side. The id stays out of
  the request *body* by default: the reference ingest API validates with
  `forbidNonWhitelisted`, so an undeclared field rejects the entire batch.
- The environment snapshot is refreshed on every foreground transition, so
  orientation, screen metrics, colour scheme and the accessibility flags no
  longer report launch-time values for the life of the process.
- The queue file is excluded from iCloud/iTunes backups.

### Changed — internals

- Builds clean in Swift 6 language mode and under
  `-strict-concurrency=complete` (previously 4 errors and 178 warnings). The
  package manifest stays at `swift-tools-version: 5.9`, so adopters on older
  toolchains are unaffected.
- Debug logging goes to `os.Logger` (subsystem `com.beaconstat.sdk`, category
  `Beaconstat`) rather than `print`, so it is filterable, cheap, and appears in a
  sysdiagnose. Read it with
  `log stream --predicate 'subsystem == "com.beaconstat.sdk"' --level debug`.

### Testing

- 116 tests at 1.0.0 → 400 at 1.1.0, green in both Debug and Release
  configurations and under ThreadSanitizer.
- `swift test -c release` now compiles at all. It did not at 1.0.0, so the
  Release-only paths — `.automatic` routing to `/v1/events`, and the four-hour
  default flush interval — had never been executed by any test.
- The request body is pinned byte-for-byte against a golden vector asserted from
  **both** sides: `WireGoldenVectorTests` here, and `sdk.wire-contract.spec.ts`
  in the ingest API. The 1.0.0 "golden vector" was a hand-written string the
  encoder never produced, so it pinned the crypto but not the format.
- CI builds every declared platform in Release and runs the suite on the
  simulator platforms, so a platform silently losing lifecycle events fails a
  build.

---

## 1.0.0

First stable release.

> **Superseded, and two of the claims below were not true of the shipped code.**
> Corrected here rather than left to mislead:
>
> - Push events were described as having "strict payload scrubbing". There was
>   no scrubbing code. The API is safe by *construction* — it never accepts
>   `userInfo`, so there is no payload to scrub — but the scalars it does accept
>   (`category`, `actionId`) were **not** sanitised and reached the wire
>   verbatim. 1.1.0 sanitises them.
> - Request signing was described as "wire-verified against the backend".
>   Nothing in the repository evidenced that. 1.1.0 makes it true: a shared
>   golden vector is asserted by tests on both the SDK and the API side.

- Zero-dependency SPM package; iOS 15+ / macOS 12+. tvOS/watchOS/visionOS code
  paths were present but only iOS and macOS were declared or built — watchOS had
  no lifecycle events and visionOS did not compile.
- `configure` + `track`; automatic `_bcs.install_detected` /
  `_bcs.session_started`.
- HMAC-SHA256 request signing; offline-first persistent queue with batching,
  exponential-backoff retry, and reconnect-triggered flush.
- Apple lifecycle events: `app_updated`, `app_backgrounded` (+
  flush-on-background), `opened_from_url` / activity (scheme+host only),
  `opened_from_shortcut`, `opened_from_widget`.
- Opt-in `push_received` / `push_opened`.
- Environment collection (device / run-context / locale / accessibility).
- Host-controlled `optOut()` kill switch; Keychain-backed identity with
  in-memory fallback.
- Automatic test-mode routing (DEBUG / simulator / optional TestFlight).
