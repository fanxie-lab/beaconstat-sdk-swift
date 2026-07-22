import Foundation

/// Debug-gated logger. `sink` defaults to stdout; injectable for tests.
final class Logger {
    private let enabled: Bool
    private let sink: (String) -> Void

    init(enabled: Bool, sink: @escaping (String) -> Void = { print("[Beaconstat] \($0)") }) {
        self.enabled = enabled
        self.sink = sink
    }

    func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        sink(message())
    }
}
