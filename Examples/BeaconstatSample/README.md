# Beaconstat sample

A minimal SwiftUI app showing `Beaconstat.configure` + `track` + `flush` and a
URL entry-point hook. It depends on the SDK via a local path (`../..`).

## Build

```bash
swift build --package-path .
```

## Run in a real app

Copy `Sources/BeaconstatSample/BeaconstatSampleApp.swift` into an Xcode app
target that has the `Beaconstat` package added, and replace the placeholder keys.
