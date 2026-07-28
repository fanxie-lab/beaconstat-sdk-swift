// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Beaconstat",
    // Declared to match what the README and CHANGELOG advertise and what the
    // code actually contains (L9). Only iOS and macOS were declared, so tvOS,
    // watchOS and visionOS silently inherited the toolchain's *default*
    // deployment target rather than the advertised minimum — and none of them
    // was in CI, which is how watchOS shipped 1.0.0 with no lifecycle events at
    // all.
    //
    // watchOS 8 rather than 7: `WKExtension.applicationDidEnterBackgroundNotification`
    // needs 7, but 8 is what the README promises and it lets
    // `LifecycleObserver.transitions()` drop a runtime `#available` check that
    // can no longer fail.
    //
    // Every one of these is built in CI, per platform, in Release.
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "Beaconstat",
            targets: ["Beaconstat"]
        ),
    ],
    targets: [
        .target(
            name: "Beaconstat",
            // `PrivacyInfo.xcprivacy` must end up at the ROOT of the resource
            // bundle SwiftPM generates for this target — that is where Xcode's
            // privacy-report aggregation and App Store Connect's processing
            // look for it. Two things follow from that:
            //
            // * the file lives at the target root, NOT in a `Resources/`
            //   subdirectory. `.copy` preserves the path it is given, so
            //   `.copy("Resources/PrivacyInfo.xcprivacy")` would bundle it one
            //   directory down, where nothing reads it.
            // * `.copy`, not `.process`. `.process` applies whatever platform
            //   rule matches and is free to rewrite or relocate the file; a
            //   privacy manifest has to ship byte-for-byte as authored.
            //
            // Declaring resources at all is what makes the manifest reach the
            // adopter's app: a Swift package's manifest is otherwise just a
            // file sitting in a source directory that nothing copies anywhere.
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "BeaconstatTests",
            dependencies: ["Beaconstat"]
        ),
    ]
)
