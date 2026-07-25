import SwiftUI
import Beaconstat

@main
struct BeaconstatSampleApp: App {
    init() {
        // Replace with your real keys. hmacSecret is the 64-char hex signing secret.
        Beaconstat.configure(
            publicKey: "bcs_pub_replace_me",
            hmacSecret: "0000000000000000000000000000000000000000000000000000000000000000"
        )
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var count = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Beaconstat sample")
                .font(.headline)
            Button("Track feature_used") {
                count += 1
                Beaconstat.track("feature_used", properties: [
                    "feature": "sample_button",
                    "count": String(count)
                ])
            }
            Button("Flush") { Beaconstat.flush() }
        }
        .padding()
        // Report a URL entry point (scheme + host only are recorded).
        .onOpenURL { url in Beaconstat.opened(from: url) }
    }
}
