import Foundation

/// Network reachability seam. `onReconnect` fires on an unsatisfied→satisfied transition.
protocol Reachability: AnyObject {
    var onReconnect: (() -> Void)? { get set }
    func start()
    func stop()
}

#if canImport(Network)
import Network

final class NWPathReachability: Reachability {
    var onReconnect: (() -> Void)?
    private let monitor = NWPathMonitor()
    private let queue: DispatchQueue
    private var wasSatisfied = true

    init(queue: DispatchQueue) { self.queue = queue }

    func start() {
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
