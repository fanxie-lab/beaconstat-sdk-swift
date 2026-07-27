import SwiftUI
import Beaconstat

/// A buildable copy of the README's quick start, plus the options, consent and
/// entry-point snippets it documents.
///
/// CI builds this on every push. That is the point: the first thing an adopter
/// does is copy the README, so the README's code has to compile against the
/// shipped API or the very first step is wrong. It also pins the `@MainActor`
/// requirement on `configure` at the exact call site the docs recommend.
@main
struct BeaconstatSampleApp: App {
    init() {
        // `App.init` is a main-actor context, which is what `configure`
        // requires (M1). Replace with your real keys; `hmacSecret` is the
        // 64-char hex signing secret, NOT the `bcs_sec_` key.
        var options = BeaconstatOptions()
        options.debugLogging = true          // → log stream --predicate 'subsystem == "com.beaconstat.sdk"'
        options.flushInterval = 60           // clamped into BeaconstatOptions.Limits
        options.collectAccessibility = false // the default since 2.0.0; opt in deliberately

        // Only needed if an extension target also calls the SDK. Both targets
        // need the Keychain Sharing entitlement for this group.
        // options.keychainAccessGroup = "ABCDE12345.com.example.app.shared"

        Beaconstat.configure(
            publicKey: "bcs_pub_replace_me",
            hmacSecret: "0000000000000000000000000000000000000000000000000000000000000000",
            options: options
        )
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var count = 0
    @State private var optedOut = Beaconstat.isOptedOut

    var body: some View {
        VStack(spacing: 16) {
            Text("Beaconstat sample")
                .font(.headline)

            Button("Track feature_used") {
                count += 1
                // Callable from anywhere — only `configure` is main-actor-bound.
                Beaconstat.track("feature_used", properties: [
                    "feature": "sample_button",
                    "count": String(count),
                ])
            }

            Button("Flush") { Beaconstat.flush() }

            // The documented consent flow. `optOut()` also purges local
            // identity, so a later `optIn()` is a new anonymous install.
            Toggle("Opt out of analytics", isOn: Binding(
                get: { optedOut },
                set: { newValue in
                    newValue ? Beaconstat.optOut() : Beaconstat.optIn()
                    // Safe to read straight back: the getter never lags the
                    // call, and it reads memory rather than the Keychain (M4/M5).
                    optedOut = Beaconstat.isOptedOut
                }
            ))

            // Optional. Releases the timers, the network-path monitor, the
            // lifecycle observers and the URLSession. `configure()` revives it.
            Button("Shut down the SDK") { Beaconstat.shutdown() }
        }
        .padding()
        // Entry points. Only scheme + host reach the wire — never the path,
        // query or fragment.
        .onOpenURL { url in Beaconstat.opened(from: url) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            Beaconstat.openedFromActivity(webpageURL: activity.webpageURL)
        }
    }
}
