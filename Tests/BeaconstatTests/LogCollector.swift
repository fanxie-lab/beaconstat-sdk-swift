import Foundation

/// Thread-safe collector for `BeaconstatCore`'s injected log sink.
///
/// The core logs from its serial queue, so tests must not read a bare array
/// from the XCTest thread while the queue is still appending to it.
final class LogCollector {
    private var storage: [String] = []
    private let lock = NSLock()

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(line)
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// Every collected line joined, for substring assertions.
    var joined: String { lines.joined(separator: "\n") }

    func contains(_ needle: String) -> Bool { joined.contains(needle) }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
