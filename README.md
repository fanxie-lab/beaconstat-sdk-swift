# Beaconstat Swift SDK

Usage analytics for iOS, macOS, tvOS, watchOS, and visionOS apps.
Lightweight, offline-first, zero third-party dependencies.

## Requirements

- iOS 15+ / macOS 12+ (tvOS 15+ / watchOS 8+ / visionOS 1+ code paths present)
- Swift 5.9+

## Installation (Swift Package Manager)

Xcode → **File → Add Package Dependencies…** and enter:

```
https://github.com/fanxie-lab/beaconstat-sdk-swift
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/fanxie-lab/beaconstat-sdk-swift", from: "1.0.0")
]
```

## Quick start

```swift
import Beaconstat

// As early as possible — App.init or didFinishLaunching.
Beaconstat.configure(
    publicKey: "bcs_pub_…",
    hmacSecret: "…64-char-hex…"   // the hmacSecret, NOT the bcs_sec_ key
)

Beaconstat.track("feature_used", properties: ["feature": "export", "format": "pdf"])
```

The SDK automatically emits `_bcs.install_detected`, `_bcs.session_started`,
`_bcs.apple.app_updated`, and `_bcs.apple.app_backgrounded`.

## API

| Call | Purpose |
|---|---|
| `configure(publicKey:hmacSecret:)` / `configure(…options:)` | Initialize. |
| `track(_:properties:)` | Custom event (string values). |
| `flush()` | Force-send queued events. |
| `optOut()` / `optIn()` / `isOptedOut` | Host-controlled kill switch. |
| `opened(from: URL)` / `openedFromActivity(webpageURL:)` | URL / universal-link / Handoff entry. Scheme + host only. |
| `openedFromShortcut(type:)` | Home-screen quick action. |
| `openedFromWidget(kind:family:)` | WidgetKit / complication / Live Activity launch. |
| `pushReceived(category:wasSilent:)` / `pushOpened(category:actionId:)` | Opt-in notification events. Never records body/title/userInfo. |

### Options

`BeaconstatOptions` tunes batching (`batchSize`, `flushInterval` — 4h release / 30s DEBUG),
`flushOnBackground`, `sessionTimeout`, `maxQueuedEvents`, `maxRetries`, `testMode`,
`routeTestFlightToTest`, `debugLogging`, `collectAccessibility`, `productVersion`, and `endpoint`.

## Privacy

No PII by default. URL entry points record scheme + host only (never path/query/fragment).
Push events record only the notification category, action identifier, and a was-silent flag — never the body, title, or userInfo. Consent is developer-managed — gate
`configure()` behind your own consent UI, or use `optOut()`.

## Test mode

Under `DEBUG` or the simulator, events route to a separate test pipeline automatically.
See `BeaconstatOptions.testMode` / `routeTestFlightToTest`.

## License

See LICENSE.
