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
    /// Test seam: where `logger` writes. `nil` uses the default stdout sink.
    private let logSink: ((String) -> Void)?

    private var configuration: Configuration?
    private var transport: Transport?
    private var logger = Logger(enabled: false, sink: { _ in })
    private var siteToken: String?
    private var environment: [String: String] = [:]
    private var routesToTest = false
    private var queue_: EventQueue?
    private var flushTimer: DispatchSourceTimer?
    private var flushing = false
    private var outstandingNetworkOps = 0
    private var stoppedForAuth = false
    private var retryCount = 0
    private var retryTimer: DispatchSourceTimer?
    private var sessionManager: SessionManager?
    private var reachability: Reachability?
    private let reachabilityFactory: (DispatchQueue) -> Reachability?
    private let lifecycleObserver: LifecycleObserver
    private var lifecycleStarted = false

    init(store: SecureStore = FallbackSecureStore(
             primary: KeychainSecureStore(),
             isPrimaryAvailable: { KeychainSecureStore.probeAvailability() },
             fallback: { InMemorySecureStore() }),
         clock: Clock = SystemClock(),
         sessionProvider: @escaping (Configuration) -> URLSession = { _ in URLSession(configuration: .default) },
         bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "unknown",
         sdkVersion: String = BeaconstatVersion.current,
         queueFileURL: URL = BeaconstatCore.defaultQueueFileURL(),
         reachabilityFactory: @escaping (DispatchQueue) -> Reachability? = { queue in
             #if canImport(Network)
             return NWPathReachability(queue: queue)
             #else
             return nil
             #endif
         },
         lifecycleObserver: LifecycleObserver = LifecycleObserver(),
         logSink: ((String) -> Void)? = nil) {
        self.store = store
        self.clock = clock
        self.sessionProvider = sessionProvider
        self.bundleIdentifier = bundleIdentifier
        self.sdkVersion = sdkVersion
        self.queueFileURL = queueFileURL
        self.reachabilityFactory = reachabilityFactory
        self.lifecycleObserver = lifecycleObserver
        self.logSink = logSink
    }

    private func makeLogger(debugLogging: Bool) -> Logger {
        let enabled = debugLogging || Self.isDebugBuild
        guard let logSink else { return Logger(enabled: enabled) }
        return Logger(enabled: enabled, sink: logSink)
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
            // Build a logger up front so opt-out / bad-key diagnostics actually emit.
            self.logger = self.makeLogger(debugLogging: options.debugLogging)
            guard self.store.string(forKey: .optedOut) == nil else {
                self.logger.debug("opted out — collecting/sending nothing")
                return
            }
            do {
                let config = try Configuration(publicKey: publicKey, hmacSecret: hmacSecret, options: options)
                // Out-of-range numerics are clamped, never rejected (H4) — but
                // say so, or a host debugging "why isn't it flushing every
                // second" has nothing to go on.
                for notice in config.clampNotices { self.logger.debug("options: \(notice)") }
                self.configuration = config
                self.environment = environment
                self.stoppedForAuth = false   // reconfigure recovers from a prior 401
                self.retryCount = 0
                self.retryTimer?.cancel()
                self.retryTimer = nil
                // Everything below reads `config.options` — the CLAMPED copy —
                // never the raw `options` the host passed in (H4).
                let opts = config.options
                self.routesToTest = TestModeResolver.routesToTest(
                    opts.testMode, isDebug: Self.isDebugBuild, isSimulator: Self.isSimulator,
                    isTestFlight: environment["run_context.is_testflight"] == "true",
                    routeTestFlightToTest: opts.routeTestFlightToTest)
                self.transport = Transport(session: self.sessionProvider(config),
                                           baseURL: config.baseURL, logger: self.logger)
                // Reuse existing queue/session on reconfigure so an in-flight flush
                // completion never operates on a replaced queue (same file path).
                if self.queue_ == nil {
                    self.queue_ = EventQueue(store: FileEventStore(fileURL: self.queueFileURL),
                                             maxQueued: opts.maxQueuedEvents, logger: self.logger)
                }
                if self.sessionManager == nil {
                    self.sessionManager = SessionManager(store: self.store, clock: self.clock,
                                                         timeout: opts.sessionTimeout)
                }
                self.startFlushTimer(interval: opts.flushInterval)
                if self.reachability == nil {
                    let r = self.reachabilityFactory(self.queue)
                    r?.onReconnect = { [weak self] in self?.queue.async { self?.flushInternal() } }
                    r?.start()
                    self.reachability = r
                }
                if !self.lifecycleStarted {
                    self.lifecycleObserver.onBackground = { [weak self] in
                        self?.queue.async { self?.handleBackground() }
                    }
                    self.lifecycleObserver.onForeground = { [weak self] in
                        self?.queue.async { self?.handleForeground() }
                    }
                    self.lifecycleObserver.start()
                    self.lifecycleStarted = true
                }
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
        outstandingNetworkOps += 1
        transport.handshake(apiKey: config.publicKey, fingerprint: fingerprint,
                            productVersion: config.options.productVersionOrDefault,
                            environmentType: environmentType) { [weak self] result in
            self?.queue.async {
                guard let self else { return }
                self.outstandingNetworkOps -= 1
                switch result {
                case .success(let resp):
                    self.siteToken = resp.siteToken
                    self.store.set(resp.siteToken, forKey: .siteToken)
                    self.clock.applyServerTime(resp.serverTime)
                    self.startSessionThenInstall()
                case .failure(let error):
                    self.logger.debug("handshake failed: \(error)")
                }
            }
        }
    }

    private func startSessionThenInstall() {
        startSessionIfNeeded()
        checkAppUpdate()
        emitInstallDetectedIfNeeded()
    }

    /// Starts a new session if needed (emitting `_bcs.session_started`), and
    /// returns the current session id (existing or newly-started).
    @discardableResult
    private func startSessionIfNeeded() -> String? {
        guard let sessionManager else { return nil }
        if let start = sessionManager.startIfNeeded() {
            var props: [String: String] = ["_bcs.session.id": start.id]
            if start.isFirst { props["_bcs.is_first_session"] = "true" }
            if let prev = start.previousAt { props["_bcs.previous_session_at"] = prev }
            enqueue(Event(name: "_bcs.session_started", time: clock.nowISO8601(), properties: props))
        }
        return sessionManager.currentSessionId()
    }

    private func emitInstallDetectedIfNeeded() {
        guard store.string(forKey: .hasEmittedInstall) == nil else { return }
        store.set("1", forKey: .hasEmittedInstall)
        var props: [String: String] = [:]
        if let sid = sessionManager?.currentSessionId() { props["_bcs.session.id"] = sid }
        let event = Event(name: "_bcs.install_detected", time: clock.nowISO8601(), properties: props.isEmpty ? nil : props)
        enqueue(event)
        // The install event is high-value and time-sensitive: don't wait for
        // batchSize or the periodic timer — attempt to send it right away.
        // (Later track() calls in Task 11 rely on the batch-size/timer path.)
        flushInternal()
    }

    /// Emits `_bcs.apple.app_updated` when the app version/build changed since the
    /// last recorded run. Never on first install (no prior version recorded).
    private func checkAppUpdate() {
        let currentVersion = environment["app.version"] ?? ""
        let currentBuild = environment["app.build"] ?? ""
        let storedVersion = store.string(forKey: .lastKnownVersion)
        let storedBuild = store.string(forKey: .lastKnownBuild)
        if let storedVersion, storedVersion != currentVersion || storedBuild != currentBuild {
            var props: [String: String] = [:]
            if let sid = sessionManager?.currentSessionId() { props["_bcs.session.id"] = sid }
            props["_bcs.apple.previous_version"] = storedVersion
            if let storedBuild { props["_bcs.apple.previous_build"] = storedBuild }
            enqueue(Event(name: "_bcs.apple.app_updated", time: clock.nowISO8601(), properties: props))
            // Like install_detected, this is high-value and time-sensitive: send it
            // right away rather than waiting for batchSize or the periodic timer —
            // otherwise it would never flush on a non-first-install run where
            // emitInstallDetectedIfNeeded's guard short-circuits before flushing.
            flushInternal()
        }
        store.set(currentVersion, forKey: .lastKnownVersion)
        store.set(currentBuild, forKey: .lastKnownBuild)
    }

    private func handleBackground() {
        guard let config = configuration, !isOptedOut else { return }
        var props: [String: String] = [:]
        if let sid = startSessionIfNeeded() { props["_bcs.session.id"] = sid }
        enqueue(Event(name: "_bcs.apple.app_backgrounded", time: clock.nowISO8601(),
                      properties: props.isEmpty ? nil : props))
        if config.options.flushOnBackground { flushInternal() }
    }

    private func handleForeground() {
        guard configuration != nil, !isOptedOut else { return }
        startSessionIfNeeded() // resumes: emits session_started only if the timeout was exceeded
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
        // Belt and braces behind Configuration's clamp (H4): `repeating: 0` here
        // is a ~345k-fires-per-second runaway, so never trust a bare interval.
        let safe = min(max(interval.isFinite ? interval : BeaconstatOptions.Limits.flushInterval.lowerBound,
                           BeaconstatOptions.Limits.flushInterval.lowerBound),
                       BeaconstatOptions.Limits.flushInterval.upperBound)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + safe, repeating: safe)
        timer.setEventHandler { [weak self] in self?.flushInternal() }
        timer.resume()
        flushTimer = timer
    }

    /// Sends one batch (≤100). One in-flight flush at a time.
    private func flushInternal() {
        guard !flushing, !stoppedForAuth, !isOptedOut,
              let config = configuration, let transport = transport, let siteToken = siteToken,
              let queue_ = queue_ else { return }
        let batch = queue_.dequeueBatch(max: 100)
        guard !batch.isEmpty else { return }
        let body = EventBatch(productVersion: config.options.productVersionOrDefault,
                              environment: environment, events: batch)
        guard let bodyData = try? PayloadEncoder.encode(body) else { return }
        let timestamp = clock.nowISO8601()
        let signature = Signer.sign(body: bodyData, publicKey: config.publicKey,
                                    hmacSecret: config.hmacSecret, timestamp: timestamp)
        flushing = true
        outstandingNetworkOps += 1
        transport.sendBatch(bodyData: bodyData, apiKey: config.publicKey, siteToken: siteToken,
                            signature: signature, timestamp: timestamp, isTest: routesToTest) { [weak self] result in
            self?.queue.async {
                guard let self else { return }
                self.outstandingNetworkOps -= 1
                self.flushing = false
                guard !self.isOptedOut else { return } // opted out mid-flight -> discard this batch
                switch result {
                case .success:
                    self.retryCount = 0
                    self.retryTimer?.cancel(); self.retryTimer = nil
                    if let count = self.queue_?.count, count > 0 { self.flushInternal() } // drain
                case .failure(.badRequest):
                    self.logger.debug("batch rejected (400) — dropping poison batch")
                    self.retryCount = 0
                    if let count = self.queue_?.count, count > 0 { self.flushInternal() }
                case .failure(.unauthorized):
                    self.logger.debug("unauthorized — requeueing and halting until reconfigured")
                    self.queue_?.prepend(batch)
                    self.stoppedForAuth = true
                case .failure(let e):
                    self.logger.debug("flush failed (\(e)) — requeueing for retry")
                    self.queue_?.prepend(batch)
                    self.scheduleRetry()
                }
            }
        }
    }

    private func scheduleRetry() {
        guard let maxRetries = configuration?.options.maxRetries else { return }
        retryCount += 1
        guard let delay = RetryPolicy.delay(forAttempt: retryCount, maxRetries: maxRetries) else {
            retryCount = 0 // give up this round; periodic timer / next event / reconnect will retry
            return
        }
        retryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.flushInternal() }
        timer.resume()
        retryTimer = timer
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

    // MARK: - Public tracking (M5)

    func track(_ name: String, properties: [String: String]) {
        queue.async {
            guard !self.isOptedOut, self.configuration != nil else { return }
            guard EventValidation.isValidUserEventName(name) else {
                self.logger.debug("dropping invalid event name: \(name)"); return
            }
            var clean: [String: String] = [:]
            for (k, v) in properties {
                guard EventValidation.isValidUserKey(k) else {
                    self.logger.debug("dropping invalid property key: \(k)"); continue
                }
                guard v.count <= 1024 else {
                    self.logger.debug("dropping oversized property value for key: \(k)"); continue
                }
                guard clean.count < 49 else { // leave room for _bcs.session.id (server caps 50 keys/event)
                    self.logger.debug("property count limit reached — dropping key: \(k)"); continue
                }
                clean[k] = v
            }
            let sid = self.startSessionIfNeeded()
            if let sid { clean["_bcs.session.id"] = sid }
            self.enqueue(Event(name: name, time: self.clock.nowISO8601(),
                               properties: clean.isEmpty ? nil : clean))
        }
    }

    // MARK: - Apple entry-point events (M6)

    func trackOpenURL(_ url: URL) {
        queue.async {
            guard !self.isOptedOut, self.configuration != nil else { return }
            let scheme = url.scheme?.lowercased()
            let entryType = (scheme == "http" || scheme == "https") ? "universal_link" : "url_scheme"
            var props: [String: String] = ["_bcs.apple.entry_type": entryType]
            if let scheme { props["_bcs.apple.url_scheme"] = scheme }
            if let host = url.host?.lowercased() { props["_bcs.apple.url_host"] = host }
            // NEVER include path / query / fragment.
            self.emitAppleEntry(name: "_bcs.apple.opened_from_url", props: props)
        }
    }

    func trackOpenActivity(_ webpageURL: URL?) {
        queue.async {
            guard !self.isOptedOut, self.configuration != nil else { return }
            var props: [String: String] = ["_bcs.apple.entry_type": "activity"]
            if let scheme = webpageURL?.scheme?.lowercased() { props["_bcs.apple.url_scheme"] = scheme }
            if let host = webpageURL?.host?.lowercased() { props["_bcs.apple.url_host"] = host }
            self.emitAppleEntry(name: "_bcs.apple.opened_from_url", props: props)
        }
    }

    /// Shared tail for Apple entry-point events: ensure a session, tag it, enqueue.
    private func emitAppleEntry(name: String, props: [String: String]) {
        var props = props
        if let sid = startSessionIfNeeded() { props["_bcs.session.id"] = sid }
        enqueue(Event(name: name, time: clock.nowISO8601(), properties: props))
    }

    func trackShortcut(_ type: String) {
        queue.async {
            guard !self.isOptedOut, self.configuration != nil else { return }
            self.emitAppleEntry(name: "_bcs.apple.opened_from_shortcut",
                                props: ["_bcs.apple.shortcut_type": type])
        }
    }

    func trackWidget(kind: String?, family: String?) {
        queue.async {
            guard !self.isOptedOut, self.configuration != nil else { return }
            var props: [String: String] = [:]
            if let kind { props["_bcs.apple.widget_kind"] = kind }
            if let family { props["_bcs.apple.widget_family"] = family }
            self.emitAppleEntry(name: "_bcs.apple.opened_from_widget", props: props)
        }
    }

    func trackPushReceived(category: String?, wasSilent: Bool) {
        queue.async {
            guard !self.isOptedOut, self.configuration != nil else { return }
            var props: [String: String] = ["_bcs.apple.push_was_silent": wasSilent ? "true" : "false"]
            if let category { props["_bcs.apple.push_category"] = category }
            // Only category + was_silent — NEVER the notification body/title/userInfo.
            self.emitAppleEntry(name: "_bcs.apple.push_received", props: props)
        }
    }

    func trackPushOpened(category: String?, actionId: String?) {
        queue.async {
            guard !self.isOptedOut, self.configuration != nil else { return }
            var props: [String: String] = [:]
            if let category { props["_bcs.apple.push_category"] = category }
            if let actionId { props["_bcs.apple.push_action_id"] = actionId }
            // Only category + action id — NEVER the notification body/title/userInfo.
            self.emitAppleEntry(name: "_bcs.apple.push_opened", props: props)
        }
    }

    func optOut() {
        queue.async {
            self.store.set("1", forKey: .optedOut)
            self.queue_?.clear()
            self.flushTimer?.cancel(); self.flushTimer = nil
            self.retryTimer?.cancel(); self.retryTimer = nil
            self.logger.debug("opted out — purged queue, cancelled timers")
        }
    }

    func optIn() {
        queue.async {
            self.store.set(nil, forKey: .optedOut)
            if let interval = self.configuration?.options.flushInterval {
                self.startFlushTimer(interval: interval) // resume periodic flush
            }
        }
    }
    var isOptedOut: Bool { store.string(forKey: .optedOut) != nil }

    // MARK: - Test hook

    #if DEBUG
    /// Fires `block` on main once all in-flight network work has drained
    /// (deterministic — no fixed delay). Test-only.
    func onQuiescent(_ block: @escaping () -> Void) {
        queue.async { self.pollQuiescent(block) }
    }
    private func pollQuiescent(_ block: @escaping () -> Void) {
        if outstandingNetworkOps == 0 && !flushing {
            DispatchQueue.main.async(execute: block)
        } else {
            queue.asyncAfter(deadline: .now() + 0.005) { self.pollQuiescent(block) }
        }
    }
    #endif
}
