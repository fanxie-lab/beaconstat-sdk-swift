import Foundation

/// Serial-queue orchestrator behind the public facade. All mutable state is
/// touched only on `queue`. Never throws into the host.
///
/// ## Sendability (M13)
///
/// `@unchecked Sendable`, declared **once, here**, because that is where the
/// invariant lives. The SDK could not be built in Swift 6 language mode at all
/// (`static let shared` is a shared mutable global of a non-`Sendable` type), and
/// under `-strict-concurrency=complete` 22 of the ~178 warnings were the single
/// diagnostic "capture of 'self' with non-Sendable type 'BeaconstatCore' in a
/// '@Sendable' closure", one per `queue.async` in this file. Annotating the 22
/// sites would have been noise; annotating the type collapses all of them.
///
/// The invariant the annotation stands on, in full:
///
/// - **Every** mutable stored property below — `configuration`, `transport`,
///   `session`, `collecting`, `logger`, `siteToken`, `handshaking`,
///   `environment`, `volatileEnvironment`, `routesToTest`, `queue_`,
///   `flushTimer`, `flushing`, `outstandingNetworkOps`, `stoppedForAuth`,
///   `retryCount`, `retryTimer`, `sessionManager`, `reachability`,
///   `lifecycleStarted`, `inBackground`, `reportedStoreDegradation`,
///   `holdingBackgroundActivity`, `batchByteBudget` — is read and written only
///   inside a block running on `queue`. Network completions re-hop before
///   touching anything. There is not one `queue.sync` in the SDK.
/// - The immutable `let`s are all of `Sendable` type: `store`, `clock`,
///   `optOutFlag`, `backgroundActivity` and `lifecycleObserver` are each
///   internally synchronised; the injected closures are `@Sendable`.
/// - The two members deliberately reachable from *off* the queue are
///   `optOutFlag` (M4 requires the consent getter not to lag, so it is
///   lock-protected and read on the caller's thread) and `backgroundActivity`
///   (H2 requires the assertion to be taken on the notification thread, before
///   the hop). Both are internally synchronised; neither is core state.
///
/// This is why the type is not an `actor`. Actor isolation would replace a
/// design the review verified as race-free with one that inserts a suspension
/// point between, say, `dequeue → encode → sign → checkout` — the straight-line
/// sequence whose atomicity is exactly what prevents double-send. It would also
/// make every public entry point `async`, which a `UNNotificationServiceExtension`
/// calling `pushReceived` from a synchronous delegate cannot use. The serial
/// queue *is* the isolation domain; `@unchecked` says the compiler cannot see
/// that, not that nobody checked.
final class BeaconstatCore: @unchecked Sendable {
    static let shared = BeaconstatCore()

    private let queue = DispatchQueue(label: "com.beaconstat.sdk.core")
    private let store: SecureStore
    /// Internal (not private) only so `BeaconstatCore+Collection.swift` can
    /// timestamp events; still written once, in `init`.
    let clock: Clock
    private let sessionProvider: @Sendable (Configuration) -> URLSession
    private let bundleIdentifier: String
    // No `sdkVersion` here. It was stored and never read: the value on the wire
    // is `sdk.version`, which `EnvironmentCollector` fills from
    // `BeaconstatVersion.current` in the facade. Every core test passed
    // `sdkVersion: "9.9.9"` believing it mattered, so a reader could reasonably
    // conclude the wire carried 9.9.9 (L5).
    private let queueFileURL: URL
    /// Test seam: where `logger` writes. `nil` uses unified logging (L6).
    private let logSink: (@Sendable (String) -> Void)?

    private var configuration: Configuration?
    private var transport: Transport?
    /// Held so it can be invalidated on reconfigure/shutdown (M7).
    private var session: URLSession?
    /// Whether timers/monitors/observers are currently running.
    private var collecting = false
    /// Internal getter only so `BeaconstatCore+Collection.swift` can log a
    /// dropped key; the setter stays private to `configure()`.
    private(set) var logger = Logger(enabled: false, sink: { _ in })
    private var siteToken: String?
    /// At most one handshake in flight, so the many flush triggers that can now
    /// ask for one collapse into a single request (C1).
    private var handshaking = false
    private var environment: [String: String] = [:]
    /// Re-collects the volatile (main-thread) half of `environment`. Called on
    /// the main thread, once per foreground transition (L1).
    private var volatileEnvironment: (@Sendable () -> [String: String])?
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
    private let reachabilityFactory: @Sendable (DispatchQueue) -> Reachability?
    private let lifecycleObserver: LifecycleObserver
    private var lifecycleStarted = false
    /// Whether the app is currently outside the foreground, so `app_backgrounded`
    /// fires once per departure even when the OS signals it twice (M3).
    private var inBackground = false
    private var reportedStoreDegradation = false
    /// How a batch becomes wire bytes. Injectable purely so the encode-failure
    /// path is reachable in a test (L2) — production always uses
    /// `PayloadEncoder.encode`.
    private let payloadEncoder: BatchEncoder
    /// Holds off suspension while a background flush is in flight (H2).
    /// Internally synchronised, because the assertion is taken on the
    /// notification thread; the `holdingBackgroundActivity` flag tracking it is
    /// queue-confined like every other piece of core state.
    private let backgroundActivity: BackgroundActivity
    private var holdingBackgroundActivity = false
    /// Encoded-size budget for one batch (H3). Starts from
    /// `EventQueue.defaultMaxBatchBytes` minus the environment map, which
    /// shares the same request body, and halves on a 413 so a deployment with a
    /// smaller body limit than ours converges instead of looping.
    private var batchByteBudget = EventQueue.defaultMaxBatchBytes
    /// The consent decision. Held in memory rather than re-read per event, and
    /// updated on the caller's thread so the public getter can't lag the call
    /// that changed it (M4, M5).
    private let optOutFlag: OptOutFlag

    init(store: SecureStore = LayeredSecureStore(
             primary: KeychainSecureStore(),
             mirror: FileSecureStore(fileURL: BeaconstatCore.defaultIdentityFileURL())),
         clock: Clock = SystemClock(),
         sessionProvider: @escaping @Sendable (Configuration) -> URLSession = { _ in TelemetrySession.make() },
         bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "unknown",
         queueFileURL: URL = BeaconstatCore.defaultQueueFileURL(),
         reachabilityFactory: @escaping @Sendable (DispatchQueue) -> Reachability? = { queue in
             #if canImport(Network)
             return NWPathReachability(queue: queue)
             #else
             return nil
             #endif
         },
         lifecycleObserver: LifecycleObserver = LifecycleObserver(),
         backgroundActivity: BackgroundActivity = BackgroundActivityFactory.make(),
         payloadEncoder: @escaping BatchEncoder = { batch, includeEventIds in
             try PayloadEncoder.encode(batch, includeEventIds: includeEventIds)
         },
         logSink: (@Sendable (String) -> Void)? = nil) {
        self.backgroundActivity = backgroundActivity
        self.payloadEncoder = payloadEncoder
        self.store = store
        self.clock = clock
        self.sessionProvider = sessionProvider
        self.bundleIdentifier = bundleIdentifier
        self.queueFileURL = queueFileURL
        self.reachabilityFactory = reachabilityFactory
        self.lifecycleObserver = lifecycleObserver
        self.logSink = logSink
        self.optOutFlag = OptOutFlag(store: store)
        // Load the persisted decision off the caller's thread. `configure()` and
        // every entry point run on this queue, so they are ordered behind it;
        // only a host reading `isOptedOut` in the same instant could beat it,
        // and `OptOutFlag` loads on demand for exactly that case.
        queue.async { [optOutFlag] in optOutFlag.prime() }
    }

    private func makeLogger(debugLogging: Bool) -> Logger {
        let enabled = debugLogging || Self.isDebugBuild
        guard let logSink else { return Logger(enabled: enabled) }
        return Logger(enabled: enabled, sink: logSink)
    }

    /// Default on-disk location for the persisted event queue.
    static func defaultQueueFileURL() -> URL {
        supportDirectory().appendingPathComponent("Beaconstat/queue.json")
    }

    /// Default on-disk location for the durable identity mirror (H5).
    static func defaultIdentityFileURL() -> URL {
        supportDirectory().appendingPathComponent("Beaconstat/identity.json")
    }

    /// `create: false` on purpose: both callers run on the main thread while
    /// `BeaconstatCore.shared` is being built, and creating the directory there
    /// is synchronous disk I/O before first frame (M6). `FileEventStore` and
    /// `FileSecureStore` each create it lazily, off the main thread.
    private static func supportDirectory() -> URL {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: false))
            ?? FileManager.default.temporaryDirectory
    }

    // MARK: - Public entry points (hop onto the serial queue)

    /// - Parameters:
    ///   - environment: wire keys already collected by the caller, on main.
    ///     Wins any collision with `deferredEnvironment`.
    ///   - deferredEnvironment: the rest of the snapshot, evaluated here on the
    ///     serial queue so it never costs main-thread time at launch (M6). It
    ///     runs at the top of this block, so routing and the handshake always
    ///     see the merged snapshot.
    ///   - volatileEnvironment: re-collects the main-thread half on every
    ///     foreground transition (L1). Invoked on the main thread, never on the
    ///     per-event path.
    func configure(publicKey: String, hmacSecret: String, options: BeaconstatOptions,
                   environment: [String: String],
                   deferredEnvironment: (@Sendable () -> [String: String])? = nil,
                   volatileEnvironment: (@Sendable () -> [String: String])? = nil) {
        queue.async {
            self.volatileEnvironment = volatileEnvironment
            // Build a logger up front so opt-out / bad-key diagnostics actually emit.
            self.logger = self.makeLogger(debugLogging: options.debugLogging)
            // Finish the snapshot before anything reads it: routing consumes
            // `run_context.is_testflight`, which lives in the deferred half.
            var environment = environment
            if let deferredEnvironment {
                environment.merge(deferredEnvironment()) { eager, _ in eager }
            }
            do {
                let config = try Configuration(publicKey: publicKey, hmacSecret: hmacSecret, options: options)
                // Out-of-range numerics are clamped, never rejected (H4) — but
                // say so, or a host debugging "why isn't it flushing every
                // second" has nothing to go on.
                for notice in config.clampNotices { self.logger.debug("options: \(notice)") }
                self.configuration = config
                self.environment = environment
                // `environment` and `productVersion` ride in the same request
                // body as the events, so the events' share of the budget is
                // what is left after them (H3). Recomputed here so a
                // reconfigure also resets a budget an earlier 413 had shrunk.
                let environmentBytes = (try? JSONEncoder().encode(environment).count) ?? 0
                self.batchByteBudget = max(EventQueue.minimumBatchBytes,
                                           EventQueue.defaultMaxBatchBytes - environmentBytes)
                // Read back the token persisted by an earlier successful
                // handshake. Nothing used to read this key, so a launch with no
                // connectivity disabled the SDK for the whole run even though
                // the credential to keep sending was sitting in the store (C1).
                self.siteToken = self.store.string(forKey: .siteToken)
                self.stoppedForAuth = false   // reconfigure recovers from a prior 401
                self.retryCount = 0
                self.retryTimer?.cancel()
                self.retryTimer = nil
                // Everything below reads `config.options` — the CLAMPED copy —
                // never the raw `options` the host passed in (H4).
                let opts = config.options
                // Before the first store access, so app and extension resolve to
                // one identity from the very first read (M12).
                (self.store as? KeychainAccessGroupConfigurable)?
                    .setKeychainAccessGroup(opts.keychainAccessGroup)
                self.routesToTest = TestModeResolver.routesToTest(
                    opts.testMode, isDebug: Self.isDebugBuild, isSimulator: Self.isSimulator,
                    isTestFlight: environment["run_context.is_testflight"] == "true",
                    routeTestFlightToTest: opts.routeTestFlightToTest)
                // A fresh URLSession per configure, and the previous one is
                // released rather than leaked: URLSession retains itself until
                // invalidated, so each reconfigure used to strand a session plus
                // its delegate operation queue for the process lifetime (M7).
                let session = self.sessionProvider(config)
                self.invalidatePreviousSession()
                self.session = session
                self.transport = Transport(session: session, baseURL: config.baseURL,
                                           logger: self.logger)
                // Keep the same queue and session-manager *instances* across a
                // reconfigure — an in-flight flush completion must never operate
                // on a replaced queue — but apply the new options in place, so a
                // second configure() is no longer silently ignored (M7).
                if let queue_ = self.queue_ {
                    queue_.setMaxQueued(opts.maxQueuedEvents)
                } else {
                    self.queue_ = EventQueue(store: FileEventStore(fileURL: self.queueFileURL,
                                                                  logger: self.logger),
                                             maxQueued: opts.maxQueuedEvents, logger: self.logger)
                }
                if let sessionManager = self.sessionManager {
                    sessionManager.setTimeout(opts.sessionTimeout)
                } else {
                    self.sessionManager = SessionManager(store: self.store, clock: self.clock,
                                                         timeout: opts.sessionTimeout)
                }
                // Configuration is now stored BEFORE the opt-out check, so a
                // later optIn() has everything it needs to start collecting.
                // Previously configure() returned before assigning it, and
                // optIn() found nil and silently did nothing (H1).
                guard !self.isOptedOut else {
                    // Belt and braces: if a crash landed between optOut()'s flag
                    // write and its purge, drop those events now rather than
                    // transmitting them at the next opt-in.
                    self.queue_?.clear()
                    self.logger.debug("opted out — configured, but collecting and sending "
                                      + "nothing until optIn()")
                    return
                }
                self.collecting = false // reconfigure restarts with the new options
                self.startCollection()
            } catch {
                self.logger.debug("configure rejected: \(error)")
            }
        }
    }

    /// Stops all SDK activity and releases the OS resources it holds: cancels
    /// the periodic flush and retry timers, cancels the reachability monitor,
    /// removes the lifecycle observers, and invalidates the `URLSession`.
    ///
    /// Queued events stay on disk — call `flush()` first if you want a final
    /// send attempt. Not required for normal use (configure once at launch and
    /// leave it); it exists so a host *can* release everything, and so tests can
    /// tear the SDK down deterministically. Safe to call more than once, and
    /// `configure()` afterwards brings the SDK back.
    func shutdown() {
        queue.async {
            self.stopCollection()
            self.invalidatePreviousSession()
            self.configuration = nil
            self.transport = nil
            self.siteToken = nil
            self.logger.debug("shutdown — timers cancelled, monitors stopped, session invalidated")
        }
    }

    // MARK: - Collection lifecycle

    /// Starts everything that observes or transmits: the periodic flush, the
    /// reachability monitor, the OS lifecycle observers, and the handshake.
    /// Idempotent — a second call while already collecting does nothing.
    private func startCollection() {
        guard let config = configuration, !isOptedOut, !collecting else { return }
        collecting = true
        startFlushTimer(interval: config.options.flushInterval)
        if reachability == nil {
            let monitor = reachabilityFactory(queue)
            // `guard let self` and then a *strong* capture in the hop, rather
            // than `self?.queue.async { self?.… }`. The nested optional capture
            // warns under strict concurrency ("reference to captured var
            // 'self'"), and it bought nothing: the monitor is owned by the core,
            // so if the core is gone this closure is gone too. Holding the core
            // for the length of a queue hop cannot cycle — the stored closure
            // itself still only holds a weak reference.
            monitor?.onReconnect = { [weak self] in
                guard let self else { return }
                self.queue.async { self.flushInternal() }
            }
            monitor?.start()
            reachability = monitor
        }
        if !lifecycleStarted {
            lifecycleObserver.onBackground = { [weak self] in
                guard let self else { return }
                // Take the assertion HERE, on the notification thread, before
                // hopping onto the serial queue. The OS starts counting down at
                // the notification, so the hop and the `app_backgrounded`
                // enqueue would otherwise be spent from a ~5 s budget (H2).
                // `begin` is idempotent and internally synchronised.
                self.backgroundActivity.begin(expiration: { [weak self] in
                    guard let self else { return }
                    self.queue.async { self.handleBackgroundActivityExpiry() }
                })
                self.queue.async { self.handleBackground() }
            }
            // macOS only, and no background assertion: losing focus doesn't
            // start a suspension countdown, and the Mac has no assertion to
            // take (M3).
            lifecycleObserver.onResignActive = { [weak self] in
                guard let self else { return }
                self.queue.async { self.handleResignActive() }
            }
            lifecycleObserver.onForeground = { [weak self] in
                guard let self else { return }
                self.queue.async { self.handleForeground() }
            }
            lifecycleObserver.start()
            lifecycleStarted = true
        }
        performHandshakeAndInstall()
    }

    /// Stops everything that observes or transmits.
    ///
    /// `configuration` is deliberately left intact so `optIn()` can resume
    /// without the host reconfiguring. Before this existed, `optOut()` left the
    /// `NWPathMonitor` running and the `NotificationCenter` observers registered
    /// for the app's lifetime, so every path flap and app switch still cost a
    /// Keychain read (M14).
    private func stopCollection() {
        collecting = false
        flushTimer?.cancel(); flushTimer = nil
        retryTimer?.cancel(); retryTimer = nil
        retryCount = 0
        reachability?.stop(); reachability = nil
        if lifecycleStarted {
            lifecycleObserver.stop()
            lifecycleStarted = false
        }
        // While the observers are off, foreground transitions go unseen, so the
        // flag would still say "backgrounded" when collection resumes and would
        // swallow the next real departure (M3). Arm it instead.
        inBackground = false
        endBackgroundActivity()
    }

    // MARK: - Background assertion (H2)

    /// Releases the assertion once nothing is in flight. Called from every
    /// network completion, so the process is held for exactly as long as a
    /// background flush actually needs and not a moment longer.
    private func endBackgroundActivityIfIdle() {
        guard holdingBackgroundActivity, !flushing, outstandingNetworkOps == 0 else { return }
        endBackgroundActivity()
    }

    private func endBackgroundActivity() {
        guard holdingBackgroundActivity else { return }
        holdingBackgroundActivity = false
        backgroundActivity.end()
    }

    /// The OS reclaimed the time before the flush finished. Nothing to undo:
    /// the batch is still on disk because it was never acknowledged, so it
    /// replays on the next launch instead of being lost.
    private func handleBackgroundActivityExpiry() {
        guard holdingBackgroundActivity else { return }
        holdingBackgroundActivity = false
        logger.debug("background time expired with a send still in flight — the batch stays "
                     + "queued and will be resent")
    }

    /// `URLSession` retains itself until invalidated. `finishTasksAndInvalidate`
    /// lets an in-flight send complete first, so this never drops a batch.
    private func invalidatePreviousSession() {
        session?.finishTasksAndInvalidate()
        session = nil
    }

    // MARK: - Handshake + install (M3)

    private func performHandshakeAndInstall() {
        guard configuration != nil, transport != nil, !isOptedOut else { return }
        guard Fingerprint.installId(store: store) != nil else {
            // No durable install id: the Keychain refused the write and no
            // on-disk mirror accepted it either. Handshaking now would register a
            // fingerprint that changes on the next launch — one install counted
            // many times (H5). Stay silent; the queue is durable, so a later run
            // with working storage sends what accumulated here.
            logger.debug("no durable install id — secure storage is unavailable; "
                         + "skipping handshake this run rather than reporting a phantom install")
            reportStoreDegradation()
            return
        }
        reportStoreDegradation()
        // Enqueue the launch events BEFORE the network call, not in its success
        // branch. They used to be stranded behind handshake success, so an
        // offline launch never even recorded `session_started`,
        // `install_detected` or `app_updated` — they were lost outright rather
        // than waiting on disk for a flush that works (C1).
        startSessionThenInstall()
        requestHandshake(force: true)
    }

    /// Obtains a site token.
    ///
    /// Safe to call from any flush trigger: at most one handshake is in flight,
    /// and without `force` it is a no-op while a token is already held. This is
    /// what makes a launch-time failure recoverable — previously the handshake
    /// ran exactly once per `configure()`, so a single failure disabled the SDK
    /// for the entire process (C1).
    ///
    /// - Parameter force: the once-per-`configure()` handshake, which runs even
    ///   with a cached token so server time is synced and the fingerprint is
    ///   re-registered.
    private func requestHandshake(force: Bool = false) {
        guard !handshaking, !stoppedForAuth, !isOptedOut,
              force || siteToken == nil,
              let config = configuration, let transport = transport,
              let installId = Fingerprint.installId(store: store) else { return }
        let fingerprint = Fingerprint.compute(bundleIdentifier: bundleIdentifier, installId: installId)
        let environmentType = routesToTest ? "development" : "production"
        handshaking = true
        outstandingNetworkOps += 1
        transport.handshake(apiKey: config.publicKey, fingerprint: fingerprint,
                            productVersion: config.options.productVersionOrDefault,
                            environmentType: environmentType) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.outstandingNetworkOps -= 1
                self.handshaking = false
                defer { self.endBackgroundActivityIfIdle() }
                guard !self.isOptedOut else { return } // opted out mid-handshake
                switch result {
                case .success(let resp):
                    self.siteToken = resp.siteToken
                    self.store.set(resp.siteToken, forKey: .siteToken)
                    self.clock.applyServerTime(resp.serverTime)
                    self.retryCount = 0
                    self.retryTimer?.cancel(); self.retryTimer = nil
                    // A token just arrived: send whatever accumulated while there
                    // wasn't one. Without this the token would sit unused until
                    // the next trigger — 4 hours away in Release.
                    self.flushInternal()
                case .failure(.unauthorized):
                    // Bad key. Retrying cannot help, and `configure()` clears it.
                    self.logger.debug("handshake unauthorized — halting until reconfigured")
                    self.stoppedForAuth = true
                case .failure(let error):
                    self.logger.debug("handshake failed (\(error)) — will retry on backoff, "
                                      + "the periodic flush, reconnect, or the next batch")
                    self.scheduleRetry()
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

    // MARK: - Collection entry points

    /// Runs `body` on the serial queue if the SDK is configured and not opted
    /// out. Every public collection entry point goes through this one door, so
    /// the guard cannot drift between them.
    ///
    /// Internal rather than private because the entry points themselves live in
    /// `BeaconstatCore+Collection.swift`.
    func onQueueIfCollecting(_ body: @escaping @Sendable () -> Void) {
        queue.async {
            guard !self.isOptedOut, self.configuration != nil else { return }
            body()
        }
    }

    func optOut() {
        // Record the decision on the CALLER's thread, before the hop. The
        // observable flag used to be written from inside the block below while
        // `isOptedOut` read the store synchronously here, so
        // `optOut(); assert(isOptedOut)` failed intermittently (M4). This also
        // shuts collection off strictly earlier than before.
        optOutFlag.record(true)
        queue.async {
            // Persist first: the in-flight flush completion re-checks the flag
            // before deciding to re-queue a batch, and this block is ordered
            // ahead of that completion on this serial queue.
            self.optOutFlag.persist()
            self.queue_?.clear()
            self.stopCollection()
            self.purgeLocalIdentity()
            self.logger.debug("opted out — purged queue and local identity, "
                              + "stopped timers, monitors and observers")
        }
    }

    /// Drops every locally stored identifier, so a "delete my data" request
    /// clears the device and not just the server (M14). The `optedOut` flag
    /// itself is kept — it *is* the consent record, and losing it would silently
    /// re-enable collection on the next launch.
    ///
    /// A later `optIn()` therefore starts a brand-new anonymous install rather
    /// than resurrecting the deleted one.
    private func purgeLocalIdentity() {
        siteToken = nil
        sessionManager?.reset()
        for key in SecureStoreKey.allCases where key != .optedOut {
            store.set(nil, forKey: key)
        }
    }

    func optIn() {
        optOutFlag.record(false) // see optOut() — the getter must not lag (M4)
        queue.async {
            self.optOutFlag.persist()
            guard self.configuration != nil else {
                // Nothing to resume yet; configure() will start collection.
                self.logger.debug("opted in before configure — collection starts at configure()")
                return
            }
            // Restart everything opt-out tore down — and, when configure() ran
            // while opted out, start it for the first time. This used to only
            // restart a flush timer that could never have any configuration
            // behind it, so every later track() was dropped (H1).
            self.startCollection()
        }
    }
    /// Non-blocking, and consistent with the last `optOut()` / `optIn()` the
    /// host made — including from another thread, and including before the
    /// serial queue has got round to persisting it (M4).
    ///
    /// Reads an in-memory flag, so the ~9 internal consultations per event no
    /// longer cost a Keychain round trip each (M5) and a SwiftUI `body` can read
    /// `Beaconstat.isOptedOut` freely.
    var isOptedOut: Bool { optOutFlag.value }

    // MARK: - Test seam

    /// Fires `block` on main once all in-flight network work has drained
    /// (deterministic — no fixed delay).
    ///
    /// `internal`, so it is invisible to hosts, but **not** `#if DEBUG`. It used
    /// to be, and the consequence was that `swift test -c release` did not
    /// compile at all: forty-odd call sites across the suite failed with "value
    /// of type 'BeaconstatCore' has no member 'onQuiescent'". Release-only
    /// behaviour — `routesToTest == false` so batches go to `/v1/events`, and a
    /// 4-hour default `flushInterval` — was therefore never executed by any test,
    /// in CI or locally (test gap 6).
    ///
    /// The cost of compiling it into Release is one method that nothing outside
    /// the module can name and nothing inside the module calls, so it is
    /// dead-stripped from a shipping binary.
    func onQuiescent(_ block: @escaping @Sendable () -> Void) {
        queue.async { self.pollQuiescent(block) }
    }

    private func pollQuiescent(_ block: @escaping @Sendable () -> Void) {
        if outstandingNetworkOps == 0 && !flushing {
            DispatchQueue.main.async(execute: block)
        } else {
            queue.asyncAfter(deadline: .now() + 0.005) { self.pollQuiescent(block) }
        }
    }
}

// MARK: - Delivery: batching, sending, acknowledging, retrying

/// Split into an extension so the orchestrator stays inside its
/// `type_body_length` budget. Kept in this file so the core's `private` state
/// stays private. Everything here runs on the core's serial queue, called only
/// from code already on it.
extension BeaconstatCore {
    /// Internal (not private) so `BeaconstatCore+Collection.swift` can reach
    /// it. Must be called on the serial queue.
    func enqueue(_ event: Event) {
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
              let config = configuration, let transport = transport,
              let queue_ = queue_ else { return }
        guard let siteToken = siteToken else {
            // No token: this launch's handshake failed, or hasn't happened yet.
            // Re-handshake on *this* trigger — the periodic timer, reconnect, the
            // retry backoff, a batch-size trip — instead of silently giving up
            // for the rest of the process, which is what C1 described. Only when
            // there is something to send: an idle offline app shouldn't poll.
            if !queue_.isEmpty { requestHandshake() }
            return
        }
        // Select, encode and sign BEFORE committing to the batch (L2). The old
        // order dequeued first and bailed on an encode failure, silently
        // destroying the batch it had just removed from disk.
        let batch = queue_.nextBatch(max: EventQueue.maxEventsPerBatch, maxBytes: batchByteBudget)
        guard !batch.isEmpty else { return }
        let body = EventBatch(productVersion: config.options.productVersionOrDefault,
                              environment: environment, events: batch)
        guard let bodyData = try? payloadEncoder(body, config.options.sendEventIds) else {
            // Nothing has been checked out yet, so the batch is untouched and
            // fully on disk. The old order dequeued first and returned here,
            // silently destroying the batch it had just removed (L2).
            logger.debug("could not encode a batch of \(batch.count) event(s) — leaving it queued")
            return
        }
        // Derived from the events' own ids, which never change, so a retry of
        // this batch presents the same key and the server can suppress the
        // replay caused by a lost 202 (H6).
        let idempotencyKey = IdempotencyKey.forBatch(batch)
        let timestamp = clock.nowISO8601()
        // Sign the exact bytes that will be transmitted; Transport never
        // re-encodes. Do not move either of these across the other.
        let signature = Signer.sign(body: bodyData, publicKey: config.publicKey,
                                    hmacSecret: config.hmacSecret, timestamp: timestamp)
        // Now the batch is definitely going out: mark it in flight. This writes
        // nothing — the events stay on disk until the server acknowledges them,
        // so a suspension or crash from here on replays rather than loses (H2).
        queue_.checkout(batch.count)
        flushing = true
        outstandingNetworkOps += 1
        transport.sendBatch(bodyData: bodyData, apiKey: config.publicKey, siteToken: siteToken,
                            signature: signature, timestamp: timestamp, isTest: routesToTest,
                            idempotencyKey: idempotencyKey) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.outstandingNetworkOps -= 1
                self.flushing = false
                // Opted out mid-flight: `optOut()`'s purge is ordered ahead of
                // this on the same serial queue and already cleared the
                // in-flight batch, so there is nothing to acknowledge.
                guard !self.isOptedOut else { self.endBackgroundActivityIfIdle(); return }
                self.handleFlushResult(result, batchCount: batch.count)
                self.endBackgroundActivityIfIdle()
            }
        }
    }

    /// Runs on the serial queue, with the batch still marked in flight.
    /// Every path must either `acknowledge()` (gone for good) or `release()`
    /// (selectable again) — leaving it marked would wedge the queue.
    ///
    /// - Parameter batchCount: how many events were sent, for the 413 decision.
    private func handleFlushResult(_ result: Result<Void, TransportError>, batchCount: Int) {
        switch result {
        case .success:
            queue_?.acknowledge()
            retryCount = 0
            retryTimer?.cancel(); retryTimer = nil
            if let pending = queue_?.pendingCount, pending > 0 { flushInternal() } // drain
        case .failure(.badRequest):
            // 400, and now every other non-retryable 4xx: 403 from a proxy or a
            // revoked key, 404 from a misconfigured endpoint, 422, 451… These
            // used to become `.unexpected` and be retried at the head of the
            // queue forever, blocking everything behind them (H3).
            dropPoisonBatch(reason: "was rejected and retrying cannot help")
        case .failure(.unexpected(let status)):
            dropPoisonBatch(reason: "got an unexpected status (\(status))")
        case .failure(.payloadTooLarge):
            handlePayloadTooLarge(batchCount: batchCount)
        case .failure(.unauthorized):
            logger.debug("unauthorized — requeueing and halting until reconfigured")
            queue_?.release()
            stoppedForAuth = true
        case .failure(let error):
            logger.debug("flush failed (\(error)) — requeueing for retry")
            queue_?.release()
            scheduleRetry(retryAfter: error.retryAfter)
        }
    }

    private func dropPoisonBatch(reason: String) {
        logger.debug("batch \(reason) — dropping it rather than blocking every event behind it")
        queue_?.acknowledge()
        retryCount = 0
        if let pending = queue_?.pendingCount, pending > 0 { flushInternal() }
    }

    /// 413 is neither poison nor plainly retryable: the same events in a
    /// smaller batch may well be accepted, so shrink and try again rather than
    /// throwing real data away.
    ///
    /// This converges on whatever body limit the deployment actually has, which
    /// is the point: the reference API now pins its own JSON limit at 256 KB
    /// (`JSON_BODY_LIMIT_BYTES`), but `endpoint` is host-overridable and the
    /// thing that answers 413 may be a reverse proxy, an API gateway or a
    /// self-hosted build that inherited body-parser's 100 KB default. The SDK
    /// does not get to know which, so it discovers it.
    private func handlePayloadTooLarge(batchCount: Int) {
        // Two ways out, and between them they GUARANTEE termination: the budget
        // strictly halves toward a floor, and once it can shrink no further —
        // or the batch is already a single event — the batch is dropped.
        // Without the floor case, a server that answers 413 to everything
        // (a misconfigured proxy) would loop on the head of the queue forever,
        // which is the exact bug H3 is about.
        guard batchCount > 1, batchByteBudget > EventQueue.minimumBatchBytes else {
            dropPoisonBatch(reason: "was rejected as too large (413) and cannot be made smaller")
            return
        }
        batchByteBudget = max(EventQueue.minimumBatchBytes, batchByteBudget / 2)
        logger.debug("batch too large (413) — halving the budget to \(batchByteBudget) bytes "
                     + "and retrying the same events in smaller pieces")
        queue_?.release()
        scheduleRetry()
    }

    /// - Parameter retryAfter: the server's own instruction, parsed from the
    ///   `Retry-After` header. Honoured over the local schedule.
    private func scheduleRetry(retryAfter: TimeInterval? = nil) {
        guard let options = configuration?.options else { return }
        retryCount += 1
        guard let delay = RetryPolicy.delay(forAttempt: retryCount, maxRetries: options.maxRetries,
                                            retryAfter: retryAfter) else {
            retryCount = 0
            scheduleNextRound(flushInterval: options.flushInterval, maxRetries: options.maxRetries)
            return
        }
        scheduleRetryTimer(after: delay)
    }

    /// The attempt budget for this round is spent.
    ///
    /// This used to just reset `retryCount` and leave a comment saying the
    /// periodic timer would retry — but in Release `flushInterval` is 14,400 s,
    /// so a queue could sit for four hours after fourteen seconds of trying
    /// while the cap evicted underneath it (M9). Start a fresh round in minutes
    /// instead, jittered so a whole fleet doesn't come back together, and never
    /// later than the host's own flush interval.
    private func scheduleNextRound(flushInterval: TimeInterval, maxRetries: Int) {
        // `maxRetries: 0` is documented as "no retry timer" — respect it and
        // leave the work to the periodic flush, the next event, and reconnect.
        guard maxRetries > 0, let queue_ = queue_, !queue_.isEmpty else { return }
        let delay = RetryPolicy.exhaustedRoundDelay(cappedBy: flushInterval)
        logger.debug("retries exhausted with \(queue_.count) event(s) queued — trying again in "
                     + "\(Int(delay))s rather than waiting for the periodic flush")
        scheduleRetryTimer(after: delay)
    }

    private func scheduleRetryTimer(after delay: TimeInterval) {
        retryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.flushInternal() }
        timer.resume()
        retryTimer = timer
    }
}

// MARK: - Session lifecycle + exactly-once launch events

/// Split into an extension so the orchestrator stays inside its
/// `type_body_length` budget as the consent/retry machinery grows. Kept in
/// this file so the core's `private` state stays private. Everything here
/// runs on the core's serial queue, called only from code already on it.
extension BeaconstatCore {
    private func startSessionThenInstall() {
        startSessionIfNeeded()
        checkAppUpdate()
        emitInstallDetectedIfNeeded()
    }

    /// Starts a new session if needed (emitting `_bcs.session_started`), and
    /// returns the current session id (existing or newly-started).
    @discardableResult
    func startSessionIfNeeded() -> String? {
        guard let sessionManager else { return nil }
        if let start = sessionManager.startIfNeeded() {
            var props: [String: String] = ["_bcs.session.id": start.id]
            if start.isFirst { props["_bcs.is_first_session"] = "true" }
            if let prev = start.previousAt { props["_bcs.previous_session_at"] = prev }
            enqueue(Event(name: "_bcs.session_started", time: clock.nowISO8601(), properties: props))
        }
        return sessionManager.currentSessionId()
    }

    /// Reports degraded secure storage exactly once per configure. Silent when
    /// storage is healthy — a warning that fires on every launch gets ignored.
    private func reportStoreDegradation() {
        guard let reason = store.degradationDescription, !reportedStoreDegradation else { return }
        reportedStoreDegradation = true
        logger.debug("secure storage degraded: \(reason). "
                     + "Check the app-sandbox / keychain-access-groups entitlement — "
                     + "unsandboxed macOS and pre-first-unlock iOS launches are the usual causes.")
    }

    private func emitInstallDetectedIfNeeded() {
        guard store.string(forKey: .hasEmittedInstall) == nil else { return }
        // Only claim a first install if we can durably remember having claimed
        // it. Otherwise the claim repeats on every launch — the phantom-install
        // inflation in H5. Better to under-report one install than to invent
        // dozens.
        guard store.set("1", forKey: .hasEmittedInstall) else {
            logger.debug("could not persist the install marker — skipping install_detected "
                         + "rather than re-emitting it on every launch")
            reportStoreDegradation()
            return
        }
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
        // The observer already took a background assertion; adopt it here so
        // the queue-confined flag matches reality, and release it on the way
        // out unless a send is actually in flight (H2).
        holdingBackgroundActivity = true
        defer { endBackgroundActivityIfIdle() }
        guard let config = configuration, !isOptedOut else { return }
        // At most one `app_backgrounded` per foreground period. macOS can
        // signal the transition twice for one departure — hide, then quit —
        // and a duplicate would double-count sessions (M3).
        if !inBackground {
            inBackground = true
            var props: [String: String] = [:]
            if let sid = startSessionIfNeeded() { props["_bcs.session.id"] = sid }
            enqueue(Event(name: "_bcs.apple.app_backgrounded", time: clock.nowISO8601(),
                          properties: props.isEmpty ? nil : props))
        }
        // Still flush on a repeat signal: quitting after hiding is the last
        // chance this process gets.
        if config.options.flushOnBackground { flushInternal() }
    }

    /// macOS: the app lost focus (⌘-Tab, another window, Mission Control) but is
    /// still running.
    ///
    /// This used to be mapped to `app_backgrounded`, so an ordinary Mac user
    /// switching apps 200 times a day produced 200 events on a reserved
    /// dimension that meant something entirely different from the iOS one (M3).
    /// The user may not come back, so it is still worth trying to send what has
    /// accumulated — but only that. With nothing queued, `flushInternal()`
    /// returns without a request, so an idle app switch costs nothing.
    private func handleResignActive() {
        guard let config = configuration, !isOptedOut, config.options.flushOnBackground else { return }
        flushInternal()
    }

    private func handleForeground() {
        // Back in the foreground: whatever is in flight no longer needs an
        // assertion to survive, and holding one costs the host background time
        // it may want for its own work.
        endBackgroundActivity()
        inBackground = false
        guard configuration != nil, !isOptedOut else { return }
        startSessionIfNeeded() // resumes: emits session_started only if the timeout was exceeded
        refreshVolatileEnvironment()
    }

    /// Re-reads the volatile half of the environment snapshot.
    ///
    /// The snapshot used to be taken once at `configure()` and reused for every
    /// batch for the process lifetime, so `device.orientation`,
    /// `device.screen_*`, `user_preference.color_scheme` and every
    /// `accessibility.*` value were launch-time values forever — rotate the
    /// device or switch to Dark Mode and the SDK kept reporting otherwise, with
    /// nothing documenting it (L1).
    ///
    /// Foreground is the right and only trigger: it is when those values have
    /// most likely changed (the user was in Settings, or Control Centre, or
    /// turned the device), it is bounded by how often the user leaves and
    /// returns, and it keeps M6's guarantee that the UI reads never touch the
    /// per-event path. In-session changes — rotating while the app is frontmost
    /// — are reported from the next foreground onwards; observing trait changes
    /// continuously would put main-thread work back on the hot path for a
    /// dimension nobody analyses at that resolution.
    ///
    /// `batchByteBudget` is deliberately not recomputed: the key set is fixed
    /// and the values are short tokens, so a refresh cannot meaningfully move
    /// it, and recomputing would undo a shrink an earlier 413 had earned (H3).
    private func refreshVolatileEnvironment() {
        guard let volatileEnvironment else { return }
        DispatchQueue.main.async { [weak self] in
            // On the main thread by construction, which is what
            // `collectMainThreadOnlyAssumingMainThread` needs.
            guard let self else { return }
            let fresh = volatileEnvironment()
            self.queue.async {
                guard !self.isOptedOut else { return }
                self.environment.merge(fresh) { _, new in new }
            }
        }
    }
}
