# Beaconstat Swift SDK

Usage analytics for iOS, iPadOS, macOS, tvOS, watchOS and visionOS apps.
Lightweight, offline-first, zero third-party dependencies.

## Requirements

- iOS 15+ · macOS 12+ · tvOS 15+ · watchOS 8+ · visionOS 1+
- Swift 5.9+ (the package also builds clean in Swift 6 language mode)

## Installation (Swift Package Manager)

Xcode → **File → Add Package Dependencies…** and enter:

```
https://github.com/fanxie-lab/beaconstat-sdk-swift
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/fanxie-lab/beaconstat-sdk-swift", from: "1.1.0")
]
```

**Upgrading from 1.0.0?** 1.1.0 contains breaking changes — read
[MIGRATION.md](MIGRATION.md) first. `configure` is now `@MainActor` (the only
change that breaks a build), and several defaults and behaviours changed.

## Quick start

```swift
import Beaconstat

@main
struct MyApp: App {
    init() {
        // `configure` is @MainActor — call it from App.init,
        // didFinishLaunching, or any other main-actor context.
        Beaconstat.configure(
            publicKey: "bcs_pub_…",
            hmacSecret: "…64-char-hex…"   // the hmacSecret, NOT the bcs_sec_ key
        )
    }

    var body: some Scene { WindowGroup { ContentView() } }
}

// Anywhere, on any thread:
Beaconstat.track("feature_used", properties: ["feature": "export", "format": "pdf"])
```

The SDK automatically emits `_bcs.install_detected`, `_bcs.session_started`,
`_bcs.apple.app_updated` and `_bcs.apple.app_backgrounded`.

## API

| Call | Purpose |
|---|---|
| `configure(publicKey:hmacSecret:)` / `configure(…options:)` | Initialise. **`@MainActor`.** |
| `track(_:properties:)` | Custom event (string values). |
| `flush()` | Force-send queued events (best-effort, async). |
| `shutdown()` | Release timers, the path monitor, the observers and the `URLSession`. |
| `optOut()` / `optIn()` / `isOptedOut` | Host-controlled kill switch. |
| `opened(from: URL)` / `openedFromActivity(webpageURL:)` | URL / universal-link / Handoff entry. Scheme + host only. |
| `openedFromShortcut(type:)` | Home-screen quick action. |
| `openedFromWidget(kind:family:)` | WidgetKit / complication / Live Activity launch. |
| `pushReceived(category:wasSilent:)` / `pushOpened(category:actionId:)` | Opt-in notification events. Never records body/title/userInfo. |

Only `configure` is main-actor-bound. Everything else is callable from any
thread or actor — deliberately, so a `UNNotificationServiceExtension` can report
`pushReceived` from a synchronous delegate callback.

Curious what happens after `track()` returns? [ARCHITECTURE.md](ARCHITECTURE.md)
walks the data flow, storage and flush triggers in a page.

## Options

```swift
var options = BeaconstatOptions()
options.flushInterval = 60
options.collectAccessibility = false   // the default; see Privacy
Beaconstat.configure(publicKey: "bcs_pub_…", hmacSecret: "…", options: options)
```

| Option | Default | Accepted range |
|---|---|---|
| `batchSize` | `50` | `1 … 10_000`, and never above `maxQueuedEvents` |
| `flushInterval` | 30 s DEBUG / 4 h release | `5 … 86_400` s |
| `flushOnBackground` | `true` | — |
| `sessionTimeout` | `300` s | `1 … 86_400` s |
| `maxQueuedEvents` | `500` | `1 … 10_000` |
| `maxRetries` | `3` | `0 … 10` (`0` disables the backoff timer) |
| `testMode` | `.automatic` | `.automatic` / `.forceProduction` / `.forceTest` |
| `routeTestFlightToTest` | `false` | — |
| `debugLogging` | `false` | — |
| `collectAccessibility` | `false` | — |
| `endpoint` | production | must be `https` unless `allowInsecureEndpoint` |
| `allowInsecureEndpoint` | `false` | — |
| `keychainAccessGroup` | `nil` | — |
| `productVersion` | `CFBundleShortVersionString` | — |
| `sendEventIds` | `false` | leave off unless ingest declares the field |

**Numeric options are clamped, never rejected** — a nonsensical value costs you
tuning, not analytics — and every clamp is logged. The ranges are published as
`BeaconstatOptions.Limits`. They are not arbitrary: `flushInterval: 0`, the
natural guess for "flush immediately", schedules a `DispatchSourceTimer` with
`repeating: 0`, which fires roughly 345,000 times a second. Use `flush()` for
that instead.

## App extensions

A `UNNotificationServiceExtension` or widget extension has its own Keychain
scope, so by default it resolves to a **different** install — with its own
`install_detected` and `is_first_session=true`. To share one identity:

1. Add the **Keychain Sharing** capability with the same group to the app target
   *and* every extension target that calls the SDK.
2. Pass the fully qualified group (Xcode prefixes it with your team id):

```swift
var options = BeaconstatOptions()
options.keychainAccessGroup = "ABCDE12345.com.example.app.shared"
```

Existing installs migrate automatically — adopting the option does not mint a
new install. Leave it `nil` and every target keeps its own identity, in which
case call the SDK only from the app target.

## Consent

```swift
Beaconstat.optOut()      // before or after configure(); persists across launches
// …user grants consent…
Beaconstat.optIn()
```

`optOut()` is a real kill switch: it collects and sends nothing, **and** it stops
doing work — timers cancelled, network-path monitor stopped, lifecycle observers
removed, queued events purged.

It also **purges local identity** — install id, site token and session history —
so it doubles as the device half of a "delete my data" request. A later
`optIn()` therefore starts a fresh anonymous install. The opt-out flag itself
persists; it is the consent record.

`isOptedOut` reads an in-memory flag, so it is safe to call from a SwiftUI
`body`, and it is always consistent with the `optOut()`/`optIn()` call that just
returned — including from another thread.

If you want to pause collection *without* destroying identity, use `shutdown()`
and `configure()` instead.

## Privacy

No PII by default, no IDFA, no `identifierForVendor`, no advertising framework,
no contacts/location/pasteboard. The install id is a locally generated UUID and
only ever leaves the device as `SHA256(bundleId|installId)`.

- **URL entry points** record scheme + host only — never path, query or
  fragment.
- **Push events** record only `category`, `actionId` and a was-silent flag —
  never the body, title or `userInfo`. The API never accepts `userInfo`, so
  there is no payload to leak.
- **Reserved `_bcs.apple.*` values** supplied by the host (quick-action type,
  widget kind, push category and action id) are sanitised: kept up to the first
  `:`, `/`, `?` or `#`, and dropped outright if what remains is empty, over 64
  characters, or contains anything outside `A–Z a–z 0–9 . _ -`.
- **`collectAccessibility` is off by default.** Turning it on collects seven
  disability-adjacent settings; alongside device model, screen metrics, timezone
  and locale they sharpen the fingerprint, and it adds a declaration you must
  make in *your* privacy manifest — see below.

Consent is developer-managed — gate `configure()` behind your own consent UI, or
use `optOut()`.

### Privacy manifest

The SDK ships its own `PrivacyInfo.xcprivacy`, bundled as an SPM resource, so it
appears in the privacy report Xcode generates for your app (Product → Archive →
Generate Privacy Report). You do not need to re-declare anything below in your
own manifest — Apple aggregates the app's manifest with those of the SDKs it
links.

**No tracking.** `NSPrivacyTracking` is `false` and no tracking domains are
listed. The SDK carries no IDFA, never reads `identifierForVendor`, links no
advertising framework, and posts to one host — yours. The install identifier is
structurally incapable of cross-app linkage: it leaves the device only as
`SHA256(bundleId|installId)`, so one device presents a *different* value to
every app that embeds the SDK. Nothing here obliges you to run an App Tracking
Transparency prompt.

**Collected data types**, all declared unlinked, untracked and for analytics:

| Declared type | What it covers |
|---|---|
| `DeviceID` | The install fingerprint and the per-session `_bcs.session.id` |
| `ProductInteraction` | Event names and properties; session, install, update, background and entry-point events |
| `OtherDiagnosticData` | `device.*`, `app.version`/`app.build`, `sdk.*`, `run_context.*` |
| `OtherDataTypes` | `locale`, `timezone`, `user_preference.*` |

Unlinked is the honest answer, not a convenient one: the SDK exposes no
`identify()`, collects no account, name or email, and the only stable id is a
random UUID minted on device and hashed before transmission — Apple's
de-identification bar is met before collection, not after. Timezone is
deliberately *not* declared as Coarse Location; an IANA timezone is far coarser
than Approximate Location Services and is not derived from it.

**No required-reason APIs are declared, and that is an audit result.** Apple
scopes required-reason declarations to iOS, iPadOS, tvOS, visionOS and watchOS.
The SDK's whole source touches exactly one covered API — `UserDefaults.standard`
reading `AppleInterfaceStyle` for `user_preference.color_scheme` — and it sits
behind `#elseif os(macOS)`, so it is not compiled into any platform that
requires a declaration. Nothing else qualifies: no file-timestamp read, no
`systemUptime`, no disk-space or active-keyboard API; `sysctlbyname` is used for
`hw.machine`/`hw.model`, which is not covered. `PrivacyManifestTests` re-derives
this from the source on every run, so the empty array cannot go stale.

**If you set `collectAccessibility = true`**, add this to your *own* app's
`PrivacyInfo.xcprivacy` — the SDK cannot declare it for you, because a static
manifest cannot say "only when configured", and declaring it unconditionally
would stamp "collects Sensitive Info" on every adopter:

```xml
<dict>
    <key>NSPrivacyCollectedDataType</key>
    <string>NSPrivacyCollectedDataTypeSensitiveInfo</string>
    <key>NSPrivacyCollectedDataTypeLinked</key>
    <false/>
    <key>NSPrivacyCollectedDataTypeTracking</key>
    <false/>
    <key>NSPrivacyCollectedDataTypePurposes</key>
    <array>
        <string>NSPrivacyCollectedDataTypePurposeAnalytics</string>
    </array>
</dict>
```

Apple's Sensitive Info type enumerates "disability", and the seven settings —
bold text, reduce motion, reduce transparency, invert colours, increased
contrast, differentiate without colour, preferred content size — are disability
proxies. Answer App Store Connect's privacy questions to match. If that
declaration is more than you want to make, leave the flag off; that is why it
defaults to off.

## Environment freshness

The `environment` map sent with every batch is snapshotted at `configure()` and
then refreshed as follows:

- `device.orientation`, `device.screen_width`/`_height`/`_scale`,
  `user_preference.color_scheme` and every `accessibility.*` key are re-read on
  the main thread at **each foreground transition**. A change made while the app
  is frontmost (rotating without leaving) is reported from the next foreground
  onwards.
- Everything else — `device.model`, `device.os_version`, `locale`, `timezone`,
  `app.version`, `sdk.*`, `run_context.*` — is collected once per process.

On visionOS the `device.screen_*` keys are omitted: a visionOS app has no
screen, it has volumes and windows the user resizes in space.

## Reliability

- **Offline-first.** Events are persisted to disk before any send is attempted,
  and a batch stays on disk until the server acknowledges it — so a suspension,
  a crash or a jetsam kill replays it rather than losing it.
- **The queue survives a failed launch handshake.** A cold launch with no signal
  still records `session_started`, `install_detected` and `app_updated`; the
  handshake is retried on reconnect, on the periodic flush, and on backoff.
- **Retries are jittered** and honour `Retry-After`.
- **Nothing wedges the queue.** A permanently-rejected batch is dropped rather
  than blocking everything behind it; an oversized one is split.
- **Every event carries a stable idempotency id**, sent as `x-idempotency-key`,
  so a lost `202` does not duplicate data server-side.

## Platform notes

- **macOS** — `_bcs.apple.app_backgrounded` fires on hide (⌘H) and quit, not on
  losing focus. ⌘-Tab triggers a flush and emits nothing.
- **watchOS** — lifecycle events use WatchKit's notifications.
- **App extensions** — the background assertion uses
  `ProcessInfo.performExpiringActivity`, not `UIApplication.beginBackgroundTask`,
  so the SDK is usable from a target built with
  `APPLICATION_EXTENSION_API_ONLY`.

## Test mode

Under `DEBUG` or the simulator, events route to a separate test pipeline
automatically. See `BeaconstatOptions.testMode` / `routeTestFlightToTest`.

## Debugging

```swift
var options = BeaconstatOptions()
options.debugLogging = true
```

Output goes to unified logging, not stdout:

```
log stream --predicate 'subsystem == "com.beaconstat.sdk"' --level debug
```

Logs carry event names, property *keys*, error cases and clamp notices — never
property values, never credentials, never the site token.

## License

See [LICENSE](LICENSE).
