import Foundation

/// Serial-queue orchestrator behind the public facade. All mutable state is
/// touched only on `queue`. Never throws into the host.
final class BeaconstatCore {
    static let shared = BeaconstatCore()

    private let queue = DispatchQueue(label: "com.beaconstat.sdk.core")
    private let store: SecureStore
    private let clock: Clock
    private let sessionProvider: (Configuration) -> URLSession
    private let bundleIdentifier: String
    private let sdkVersion: String
    private let queueFileURL: URL

    private var configuration: Configuration?
    private var transport: Transport?
    private var logger = Logger(enabled: false, sink: { _ in })
    private var siteToken: String?
    private var environment: [String: String] = [:]
    private var routesToTest = false
    private var queue_: EventQueue?
    private var flushTimer: DispatchSourceTimer?
    private var flushing = false
    private var stoppedForAuth = false

    init(store: SecureStore = KeychainSecureStore(),
         clock: Clock = SystemClock(),
         sessionProvider: @escaping (Configuration) -> URLSession = { _ in URLSession(configuration: .default) },
         bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "unknown",
         sdkVersion: String = BeaconstatVersion.current,
         queueFileURL: URL = BeaconstatCore.defaultQueueFileURL()) {
        self.store = store
        self.clock = clock
        self.sessionProvider = sessionProvider
        self.bundleIdentifier = bundleIdentifier
        self.sdkVersion = sdkVersion
        self.queueFileURL = queueFileURL
    }

    /// Default on-disk location for the persisted event queue.
    static func defaultQueueFileURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Beaconstat/queue.json")
    }

    // MARK: - Public entry points (hop onto the serial queue)

    func configure(publicKey: String, hmacSecret: String, options: BeaconstatOptions,
                   environment: [String: String]) {
        queue.async {
            do {
                let config = try Configuration(publicKey: publicKey, hmacSecret: hmacSecret, options: options)
                self.configuration = config
                self.environment = environment
                let debugBuild = Self.isDebugBuild
                self.logger = Logger(enabled: options.debugLogging || debugBuild)
                self.routesToTest = TestModeResolver.routesToTest(
                    options.testMode, isDebug: debugBuild, isSimulator: Self.isSimulator)
                self.transport = Transport(session: self.sessionProvider(config),
                                           baseURL: config.baseURL, logger: self.logger)
                self.queue_ = EventQueue(store: FileEventStore(fileURL: self.queueFileURL),
                                         maxQueued: options.maxQueuedEvents, logger: self.logger)
                self.startFlushTimer(interval: options.flushInterval)
                self.performHandshakeAndInstall()
            } catch {
                self.logger.debug("configure rejected: \(error)")
            }
        }
    }

    // MARK: - Handshake + install (M3)

    private func performHandshakeAndInstall() {
        guard let config = configuration, let transport = transport else { return }
        let installId = Fingerprint.installId(store: store)
        let fingerprint = Fingerprint.compute(bundleIdentifier: bundleIdentifier, installId: installId)
        let environmentType = routesToTest ? "development" : "production"
        transport.handshake(apiKey: config.publicKey, fingerprint: fingerprint,
                            productVersion: config.options.productVersionOrDefault,
                            environmentType: environmentType) { [weak self] result in
            self?.queue.async {
                guard let self else { return }
                switch result {
                case .success(let resp):
                    self.siteToken = resp.siteToken
                    self.store.set(resp.siteToken, forKey: .siteToken)
                    self.clock.applyServerTime(resp.serverTime)
                    self.emitInstallDetectedIfNeeded()
                case .failure(let error):
                    self.logger.debug("handshake failed: \(error)")
                }
            }
        }
    }

    private func emitInstallDetectedIfNeeded() {
        guard store.string(forKey: .hasEmittedInstall) == nil else { return }
        store.set("1", forKey: .hasEmittedInstall)
        let event = Event(name: "_bcs.install_detected", time: clock.nowISO8601(),
                          properties: ["_bcs.install.source": "app_store"])
        enqueue(event)
        // The install event is high-value and time-sensitive: don't wait for
        // batchSize or the periodic timer — attempt to send it right away.
        // (Later track() calls in Task 11 rely on the batch-size/timer path.)
        flushInternal()
    }

    // MARK: - Queue + flush (M4)

    private func enqueue(_ event: Event) {
        guard !isOptedOut else { return }
        queue_?.enqueue(event)
        if let count = queue_?.count, let size = configuration?.options.batchSize, count >= size {
            flushInternal()
        }
    }

    func flush() { queue.async { self.flushInternal() } }

    private func startFlushTimer(interval: TimeInterval) {
        flushTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.flushInternal() }
        timer.resume()
        flushTimer = timer
    }

    /// Sends one batch (≤100). One in-flight flush at a time.
    private func flushInternal() {
        guard !flushing, !stoppedForAuth, !isOptedOut,
              let config = configuration, let transport = transport, let siteToken = siteToken,
              let queue_ = queue_ else { return }
        let batch = queue_.peekBatch(max: 100)
        guard !batch.isEmpty else { return }
        let body = EventBatch(productVersion: config.options.productVersionOrDefault,
                              environment: environment, events: batch)
        guard let bodyData = try? PayloadEncoder.encode(body) else { return }
        let timestamp = clock.nowISO8601()
        let signature = Signer.sign(body: bodyData, publicKey: config.publicKey,
                                    hmacSecret: config.hmacSecret, timestamp: timestamp)
        flushing = true
        transport.sendBatch(bodyData: bodyData, apiKey: config.publicKey, siteToken: siteToken,
                            signature: signature, timestamp: timestamp, isTest: routesToTest) { [weak self] result in
            self?.queue.async {
                guard let self else { return }
                self.flushing = false
                switch result {
                case .success:
                    self.queue_?.removeFirst(batch.count)
                case .failure(.badRequest):
                    self.logger.debug("batch rejected (400) — dropping poison batch")
                    self.queue_?.removeFirst(batch.count)
                case .failure(.unauthorized):
                    self.logger.debug("unauthorized — halting sends until reconfigured")
                    self.stoppedForAuth = true
                case .failure(let e):
                    self.logger.debug("flush failed (\(e)) — keeping events for retry")
                }
            }
        }
    }

    // MARK: - Run context

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Facade stubs (real bodies land in Task 11)

    func track(_ name: String, properties: [String: String]) { /* Task 11 */ }
    func optOut() { queue.async { self.store.set("1", forKey: .optedOut) } }
    func optIn() { queue.async { self.store.set(nil, forKey: .optedOut) } }
    var isOptedOut: Bool { store.string(forKey: .optedOut) != nil }

    // MARK: - Test hook

    /// Fires `block` once the serial queue has drained the currently-enqueued
    /// work (including the async completion re-hops). Test-only convenience.
    func onQuiescent(_ block: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async { self.settle(block) } }
    }
    private func settle(_ block: @escaping () -> Void) {
        // Two more hops let handshake completion + follow-up send enqueue and run.
        queue.async { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { block() } }
    }
}
