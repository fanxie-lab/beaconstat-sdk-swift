# Migrating from 1.0.0 to 2.0.0

Every item below was verified against the shipped 2.0.0 source, not against a
plan. Items are ordered by how likely they are to affect you.

**Summary for the impatient:** if you call `Beaconstat.configure(...)` from
`App.init` or `didFinishLaunching`, use the default options, and don't call
`optOut()`, you need **no source changes at all** — but read
[§7](#7-behaviour-changes-that-affect-your-data) before you compare 2.0.0 data
with 1.0.0 data.

---

## 1. `configure` is now `@MainActor` — a hard compile error off main

This is the only change that can break a build.

```swift
// 1.0.0 — compiled, and silently produced wrong values
Task.detached {
    Beaconstat.configure(publicKey: "bcs_pub_…", hmacSecret: "…")
}
DispatchQueue.global().async {
    Beaconstat.configure(publicKey: "bcs_pub_…", hmacSecret: "…")
}
```

```swift
// 2.0.0 — call it from a main-actor context
@main
struct MyApp: App {
    init() {                                   // App.init is main-actor
        Beaconstat.configure(publicKey: "bcs_pub_…", hmacSecret: "…")
    }
    var body: some Scene { WindowGroup { ContentView() } }
}

// or, from somewhere that isn't:
Task { @MainActor in
    Beaconstat.configure(publicKey: "bcs_pub_…", hmacSecret: "…")
}
```

**Why.** `configure` snapshots main-thread-only UI state — `UIScreen.main`,
`UITraitCollection.current`, the `UIAccessibility` flags. Off the main thread
those trip the Main Thread Checker and yield defaults, so `device.screen_*`,
`device.orientation`, `user_preference.color_scheme` and every `accessibility.*`
key were quietly wrong for any host that deferred setup. It was already
effectively main-thread-only; now it says so.

**Only `configure` is affected.** Every other entry point — `track`, `flush`,
`optOut`, `optIn`, `isOptedOut`, `shutdown`, `opened(from:)`,
`openedFromActivity`, `openedFromShortcut`, `openedFromWidget`, `pushReceived`,
`pushOpened` — is callable from any thread or actor, deliberately: a
`UNNotificationServiceExtension` reporting `pushReceived` has no main actor.

---

## 2. `BeaconstatOptions.init` gained three parameters

All three have defaults, so **only fully-positional or exhaustive memberwise
calls break.** If you construct options with `var options = BeaconstatOptions()`
and assign properties — the documented pattern — nothing changes.

```swift
// 2.0.0 memberwise signature, in order:
BeaconstatOptions(
    testMode:               TestMode        = .automatic,
    batchSize:              Int             = 50,
    flushInterval:          TimeInterval    = BeaconstatOptions.defaultFlushInterval,
    flushOnBackground:      Bool            = true,
    sessionTimeout:         TimeInterval    = 300,
    maxQueuedEvents:        Int             = 500,
    maxRetries:             Int             = 3,
    debugLogging:           Bool            = false,
    collectAccessibility:   Bool            = false,   // ← default changed, see §3
    endpoint:               URL?            = nil,
    keychainAccessGroup:    String?         = nil,     // ← new
    productVersion:         String?         = nil,
    routeTestFlightToTest:  Bool            = false,
    sendEventIds:           Bool            = false,   // ← new
    allowInsecureEndpoint:  Bool            = false    // ← new
)
```

Note `keychainAccessGroup` is inserted **after `endpoint` and before
`productVersion`**, so a positional call that passed `productVersion` in that
slot will now either fail to compile or bind to the wrong parameter. Use
argument labels.

---

## 3. `collectAccessibility` now defaults to `false`

```swift
// 2.0.0 — opt in explicitly if you want these keys back
var options = BeaconstatOptions()
options.collectAccessibility = true
```

Turning it on collects seven disability-adjacent settings (bold text, reduce
motion, reduce transparency, invert colours, increased contrast, differentiate
without colour, preferred content size). They are not prohibited and the SDK
collects no IDFA/IDFV, but combined with device model, screen metrics, timezone,
locale and OS version they sharpen the fingerprint materially — and collecting
them puts a disclosure obligation in **your** privacy manifest. Turn it on when
you are actually going to act on the data.

**Data impact:** if you leave it off, `accessibility.*` stops arriving. Any
dashboard segment built on those keys goes empty for 2.0.0 installs.

---

## 4. Non-`https` endpoints are rejected

```swift
// 1.0.0 — accepted silently
options.endpoint = URL(string: "http://localhost:3000")

// 2.0.0 — the SDK refuses to configure and logs `insecureEndpoint`
options.endpoint = URL(string: "http://localhost:3000")
options.allowInsecureEndpoint = true          // required, and logged as a warning
```

The site token and the HMAC request signature travel in headers; over `http`
they are readable and replayable by anything on the path. The opt-in relaxes the
check to `http` only — not `file`, `ftp`, or anything else that happens to parse
as a URL. Never ship it.

---

## 5. `optOut()` now purges local identity

```swift
Beaconstat.optOut()
// 1.0.0: stopped sending. install_id, site token and session history stayed.
// 2.0.0: also deletes install_id, the site token and session history, stops the
//        network-path monitor, removes the lifecycle observers, cancels timers,
//        and clears the on-disk queue.
Beaconstat.optIn()
// 2.0.0: this is a NEW anonymous install. It emits _bcs.install_detected and
//        _bcs.is_first_session=true, with a different fingerprint.
```

The opt-out flag itself is deliberately **not** purged — it is the consent
record, and losing it would silently re-enable collection on the next launch.

**Data impact:** an opt-out → opt-in round trip now inflates your install count
by one and starts a fresh session lineage. That is the correct behaviour for a
"delete my data" request, but if you were using `optOut()`/`optIn()` as a cheap
pause/resume, use `shutdown()` + `configure()` instead — that releases resources
without destroying identity.

---

## 6. Out-of-range option numerics are clamped

Previously accepted verbatim; now clamped into `BeaconstatOptions.Limits`, with
one log line per clamp. Nothing is rejected — a bad number costs you tuning, not
analytics.

| Option | Accepted range | What the old value did |
|---|---|---|
| `flushInterval` | `5 … 86_400` s | `0` scheduled `repeating: 0` — ~345,000 timer fires per second, each pinning a core and issuing a Keychain read |
| `sessionTimeout` | `1 … 86_400` s | `≤ 0` started a new session per event: two Keychain writes and a `session_started` apiece |
| `maxQueuedEvents` | `1 … 10_000` | unbounded resident queue, rewritten in full on every enqueue |
| `maxRetries` | `0 … 10` | negative values disabled retries in a way nothing documented |
| `batchSize` | `1 … 10_000`, and never above the effective `maxQueuedEvents` | `0` made `count >= batchSize` always true — a flush per event; above `maxQueuedEvents` the size trigger could never fire at all |

Non-finite `TimeInterval`s (`nan`, `±infinity`) fall back to the range floor —
`min`/`max` propagate NaN, so an ordinary clamp would have let them through.

---

## 7. Behaviour changes that affect your data

No code change needed, but your dashboards will notice.

### macOS `app_backgrounded` means something different

1.0.0 mapped it to `NSApplication.didResignActiveNotification`, which fires on
⌘-Tab, on clicking another window, and on Mission Control. A Mac user switching
apps 200×/day produced 200 `_bcs.apple.app_backgrounded` events and 200 HTTP
POSTs. 2.0.0 emits it on `didHide` (⌘H) and `willTerminate` only; losing focus
flushes and emits nothing.

**Historic macOS `app_backgrounded` counts are not comparable with 2.0.0
counts** — expect them to fall by an order of magnitude. That is the bug being
fixed, not a regression.

### watchOS now emits lifecycle events at all

1.0.0 emitted **none** on watchOS: the UIKit branch excluded it and the AppKit
branch didn't match. `_bcs.apple.app_backgrounded` and foreground session resume
now fire, so watchOS session counts will rise from artificially low numbers.

### visionOS now compiles, and reports no screen metrics

1.0.0 advertised visionOS but did not build for it (`UIScreen` is unavailable
there). 2.0.0 builds, and deliberately omits `device.screen_width`,
`_height` and `_scale` on visionOS — a visionOS app has no screen, it has
volumes and windows the user resizes in space.

### Install counts should fall

If you saw implausible install growth on macOS or from background launches,
that was 1.0.0 minting a fresh install id whenever the Keychain refused a write.
2.0.0 keeps a durable on-disk mirror and stays silent rather than reporting a
phantom install. Expect *lower*, more accurate install and first-session counts.

### Reserved Apple values may be truncated or dropped

`openedFromShortcut(type:)`, `openedFromWidget(kind:family:)`,
`pushReceived(category:)` and `pushOpened(actionId:)` now sanitise their input
before it reaches a reserved `_bcs.apple.*` dimension. The rule, exactly:

1. keep only the prefix up to the first `:`, `/`, `?` or `#`;
2. trim surrounding whitespace;
3. **drop the property entirely** — it is not truncated — if what remains is
   empty, longer than 64 characters, or contains any character outside
   `A–Z a–z 0–9 . _ -`.

```
"openChat:user@example.com"   →  "openChat"
"openDoc:9F2A-…"              →  "openDoc"
"com.example.newItem"         →  "com.example.newItem"   (unchanged)
"user@example.com"            →  dropped (no delimiter, and '@' is not allowed)
"Ünicode-Kind"                →  dropped (non-ASCII)
<65+ characters, no delimiter> →  dropped
```

A dropped value is logged **by key only**, never by value. The event itself is
still sent, without that property.

This does not apply to `_bcs.apple.url_scheme` / `url_host`, which the SDK
derives itself from `URL` components and which legitimately contain non-ASCII
(IDN) hosts.

If you were deliberately encoding a target in a quick-action type and reading it
back out of analytics, that stops working — by design. It was a PII leak and an
unbounded-cardinality problem on a reserved dimension. Put the safe part in a
custom `track()` property instead.

### The environment snapshot is refreshed on foreground

`device.orientation`, `device.screen_*`, `user_preference.color_scheme` and the
`accessibility.*` keys were snapshotted once at `configure()` and reported for
the life of the process. They are now re-read on the main thread at every
foreground transition. A change made while the app is frontmost (rotating
without leaving) is reported from the next foreground onwards; everything else —
`device.model`, `device.os_version`, `locale`, `timezone`, `app.version`,
`sdk.*`, `run_context.*` — is still collected once per process.

---

## 8. New on-disk and Keychain state

- **Keychain items moved** to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  (was `…AfterFirstUnlock`). Identity no longer rides an encrypted backup onto a
  second device, where it would merge two installs into one. Existing items are
  rewritten with the new attribute on the next write; nothing is lost.
- **A new file, `identity.json`**, appears next to `queue.json` in Application
  Support. It is the durable mirror for the SDK's anonymous local state — install
  id, the exactly-once markers, session bookkeeping. It deliberately **never**
  holds the site token, which is a bearer credential and costs one handshake to
  replace.
- **`queue.json` is now excluded from iCloud/iTunes backups.** Transient
  telemetry shouldn't ride along in user backups. `identity.json` is *not*
  excluded — its whole job is to survive.

---

## 9. New API you may want

### `shutdown()`

```swift
Beaconstat.flush()      // optional: one last send attempt
Beaconstat.shutdown()   // cancels timers, stops the path monitor, removes the
                        // lifecycle observers, invalidates the URLSession
```

Not required for normal use — configure once at launch and forget it. It exists
so a host *can* release everything, and so integration tests can tear the SDK
down deterministically. Idempotent; `configure()` afterwards brings it back.
Queued events stay on disk.

### `keychainAccessGroup` — for app extensions

Without it, a `UNNotificationServiceExtension` calling `pushReceived` resolves to
a **different** install, with its own `install_detected` and
`is_first_session=true`. Same for a widget extension.

```swift
// Add the Keychain Sharing capability with the SAME group to the app target
// AND every extension target that calls the SDK:
//   $(AppIdentifierPrefix)com.example.app.shared
var options = BeaconstatOptions()
options.keychainAccessGroup = "ABCDE12345.com.example.app.shared"  // team-id prefixed
```

Existing installs migrate automatically: reads and deletes are deliberately
*not* scoped to the group, so an `install_id` already in the app's private group
is still found and is rewritten into the shared group on the next write. Adopting
the option does not mint a new install.

Leave it `nil` — the default — and every target keeps its own identity, in which
case call the SDK only from the app target.

### `sendEventIds` — leave it off

Every event now carries a stable idempotency id. It is sent as the
`x-idempotency-key` **header**, which needs no server change. `sendEventIds`
additionally puts the id in the request *body*, and **must stay `false` until
your ingest deployment declares the field**: the reference API validates with
`forbidNonWhitelisted: true`, so an undeclared `id` is not stripped — it returns
`400 property id should not exist` and rejects the **entire batch**, all 100
events. That is a total ingest outage, not a degradation.

---

## 10. Logging moved to unified logging

`print("[Beaconstat] …")` → `os.Logger(subsystem: "com.beaconstat.sdk", category:
"Beaconstat")` at `.debug` level. If you were grepping stdout for `[Beaconstat]`,
use:

```
log stream --predicate 'subsystem == "com.beaconstat.sdk"' --level debug
```

Still gated on `debugLogging` (or a DEBUG build), and still carries no property
values, no environment values, no credentials and no site token — an invariant a
test now enforces rather than a comment asserting it.

---

## 11. Swift 6

The package builds clean in Swift 6 language mode and under
`-strict-concurrency=complete`. The manifest stays at
`swift-tools-version: 5.9`, so **nothing is required of you** — this only means
that if *your* app has migrated to Swift 6, this dependency no longer blocks you.
