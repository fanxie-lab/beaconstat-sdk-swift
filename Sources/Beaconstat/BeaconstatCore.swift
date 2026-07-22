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

    private var configuration: Configuration?
    private var transport: Transport?
    private var logger = Logger(enabled: false, sink: { _ in })
    private var siteToken: String?
    private var environment: [String: String] = [:]
    private var routesToTest = false

    init(store: SecureStore = KeychainSecureStore(),
         clock: Clock = SystemClock(),
         sessionProvider: @escaping (Configuration) -> URLSession = { _ in URLSession(configuration: .default) },
         bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "unknown",
         sdkVersion: String = BeaconstatVersion.current) {
        self.store = store
        self.clock = clock
        self.sessionProvider = sessionProvider
        self.bundleIdentifier = bundleIdentifier
        self.sdkVersion = sdkVersion
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
        sendImmediately([event]) // Task 9 replaces this with the persistent queue
    }

    /// Ad-hoc single-batch send (M3). Superseded by EventQueue/flush in Task 9.
    private func sendImmediately(_ events: [Event]) {
        guard let config = configuration, let transport = transport, let siteToken = siteToken else { return }
        let batch = EventBatch(productVersion: config.options.productVersionOrDefault,
                               environment: environment, events: events)
        guard let bodyData = try? PayloadEncoder.encode(batch) else { return }
        let timestamp = clock.nowISO8601()
        let signature = Signer.sign(body: bodyData, publicKey: config.publicKey,
                                    hmacSecret: config.hmacSecret, timestamp: timestamp)
        transport.sendBatch(bodyData: bodyData, apiKey: config.publicKey, siteToken: siteToken,
                            signature: signature, timestamp: timestamp, isTest: routesToTest) { [weak self] result in
            self?.queue.async {
                if case .failure(let e) = result { self?.logger.debug("send failed: \(e)") }
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

    // MARK: - Facade stubs (real bodies land in Tasks 9/11)

    func track(_ name: String, properties: [String: String]) { /* Task 11 */ }
    func flush() { /* Task 9 */ }
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
