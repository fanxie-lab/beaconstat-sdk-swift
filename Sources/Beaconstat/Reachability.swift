import Foundation

/// Network reachability seam. `onReconnect` fires on an unsatisfied→satisfied transition.
///
/// `Sendable`, with a `@Sendable` callback: the core stores one of these and
/// assigns the callback from its serial queue, while the implementation invokes
/// it from wherever the system delivers path updates (M13).
protocol Reachability: AnyObject, Sendable {
    var onReconnect: (@Sendable () -> Void)? { get set }
    func start()
    func stop()
}

#if canImport(Network)
import Network

/// `@unchecked Sendable`, justified by a single fact: **every** mutable member —
/// `onReconnect` and `wasSatisfied` — is touched only on the `DispatchQueue`
/// handed to `init`, which is the core's own serial queue.
///
/// `onReconnect` is assigned in `startCollection()`, on that queue.
/// `wasSatisfied` is read and written only inside `pathUpdateHandler`, and
/// `monitor.start(queue:)` is given the same queue, so the system delivers path
/// updates there too. The monitor itself is immutable after construction.
///
/// That confinement is what the review's "no data races" finding rests on, and
/// it is why an actor rewrite here would buy nothing: the queue already *is* the
/// isolation domain, it is shared with the code that reads the callback's
/// effects, and hopping through an actor would only add a suspension point
/// between "path became satisfied" and "flush".
final class NWPathReachability: Reachability, @unchecked Sendable {
    var onReconnect: (@Sendable () -> Void)?
    private let monitor = NWPathMonitor()
    private let queue: DispatchQueue
    private var wasSatisfied = true

    init(queue: DispatchQueue) { self.queue = queue }

    func start() {
        // `[weak self]` and then a strong `self` inside: `pathUpdateHandler` is
        // `@Sendable`, so capturing the non-Sendable `self` directly is a hard
        // error in Swift 6 rather than a warning. The capture is sound because
        // of the queue confinement documented above.
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            if satisfied && !self.wasSatisfied { self.onReconnect?() }
            self.wasSatisfied = satisfied
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }

    deinit { monitor.cancel() } // don't leak the system monitor when the core is released
}
#endif
