import Foundation

/// Cœur du SDK : reçoit les commandes de la façade dans l'ordre, valide, met en queue, décide des flush.
/// Toute I/O (disque, Keychain, réseau) se fait ici, jamais sur le thread appelant.
actor AnalyticsCore {
    enum Command: Sendable {
        case configure(ingestKey: String, endpoint: URL, options: Analytics.Options, optedOut: Bool, at: Date)
        case track(name: String, props: [String: PropValue], at: Date)
        case screen(name: String, props: [String: PropValue], at: Date)
        /// `completion` est appelé quand l'envoi en cours (ou demandé) est terminé, réussi ou non.
        case flush(completion: (@Sendable () -> Void)?)
        case lifecycle(LifecycleObserver.Event, at: Date)
        case resetDeviceID(at: Date)
        case setOptOut(Bool, at: Date)
        case networkRestored
    }

    /// Dépendances injectables (tests).
    struct Environment: Sendable {
        var queueDirectory: @Sendable () -> URL?
        var now: @Sendable () -> Date
        var identity: DeviceIdentity
        var device: @Sendable () -> Batch.Device
        var makeTransport: @Sendable (_ endpoint: URL, _ ingestKey: String) -> any Transport

        static let live = Environment(
            queueDirectory: { EventQueue.defaultDirectory() }, now: { Date() }, identity: DeviceIdentity(),
            device: { Batch.Device.current() },
            makeTransport: { URLSessionTransport(endpoint: $0, ingestKey: $1) })
    }

    static let maxPendingBeforeConfigure = 100
    static let defaultRetryAfter: TimeInterval = 60

    private let environment: Environment
    private(set) var isConfigured = false
    private(set) var options = Analytics.Options()
    private var queue: EventQueue?
    private var pending: [Command] = []
    private var sessions = SessionTracker(
        markerDirectory: nil,
        device: .init(id: "", model: "", osVersion: "", appVersion: "", buildNumber: "", locale: ""))
    /// Après un reset d'identité en arrière-plan, la prochaine session porte `first = true`.
    private var nextSessionIsFirst = false
    /// Copie locale de l'identifiant : ne change qu'au traitement de `resetDeviceID`, dans l'ordre des commandes.
    private(set) var device: Batch.Device?

    // Envoi
    private var transport: (any Transport)?
    private(set) var optedOut = false
    /// Clé refusée (401/403) : plus rien jusqu'au prochain lancement.
    private(set) var disabled = false
    private var backoff = Backoff()
    private(set) var backoffUntil: Date?
    private(set) var rateLimitedUntil: Date?
    private var inFlight: Batch?
    private var isFlushing = false
    private var flushWaiters: [@Sendable () -> Void] = []
    /// Incrémenté à chaque purge : un résultat d'envoi reçu après une purge est ignoré.
    private var generation = 0
    private var timer: Task<Void, Never>?
    private var retry: Task<Void, Never>?

    init(environment: Environment = .live) {
        self.environment = environment
    }

    deinit {
        timer?.cancel()
        retry?.cancel()
    }

    func handle(_ command: Command) {
        switch command {
        case .configure(let key, let url, let options, let optedOut, let date):
            configure(ingestKey: key, endpoint: url, options: options, optedOut: optedOut, at: date)
        case .track, .screen:
            guard !optedOut, !disabled else { return }
            guard isConfigured else {
                bufferBeforeConfigure(command)
                return
            }
            record(command)
            flushIfThresholdReached()
        case .flush(let completion):
            guard isConfigured else {
                completion?()
                return
            }
            queue?.sync()
            requestFlush(completion)
        case .lifecycle(let event, let date):
            guard isConfigured, !optedOut, !disabled else { return }
            handleLifecycle(event, at: date)
        case .resetDeviceID(let date):
            guard isConfigured else {
                environment.identity.persist()
                return
            }
            resetDeviceID(at: date)
        case .setOptOut(let value, let date):
            setOptOut(value, at: date)
        case .networkRestored:
            backoff.reset()
            backoffUntil = nil
            requestFlush(nil)
        }
    }

    /// Nombre d'événements en attente sur disque (tests, diagnostic).
    var queuedCount: Int { queue?.count ?? 0 }

    /// Les événements en attente, sans les retirer (tests, diagnostic).
    func queuedEvents(limit: Int = 500) -> [QueuedEvent] { queue?.peek(limit).events ?? [] }

    /// Attend la fin de l'envoi en cours (tests).
    func waitForFlush() async {
        guard isFlushing else { return }
        await withCheckedContinuation { continuation in
            flushWaiters.append { continuation.resume() }
        }
    }

    // MARK: - Configuration

    private func configure(
        ingestKey: String, endpoint: URL, options: Analytics.Options, optedOut: Bool, at date: Date
    ) {
        guard !isConfigured else { return }
        self.options = options
        self.optedOut = optedOut
        Log.currentLevel = options.logLevel
        if options.trackScreensAutomatically {
            Log.warning("trackScreensAutomatically: not implemented in 1.x, use .analyticsScreen(_:)")
        }
        let directory = environment.queueDirectory()
        if let directory {
            queue = EventQueue(directory: directory, maxEvents: options.maxQueuedEvents)
        } else {
            Log.error("no Application Support directory, events will be dropped")
        }
        environment.identity.persist()
        let identity = environment.identity.load()
        var device = environment.device()
        device.id = identity.id
        self.device = device
        sessions = SessionTracker(markerDirectory: directory, device: device)
        transport = environment.makeTransport(endpoint, ingestKey)
        isConfigured = true
        startTimer(interval: options.flushInterval)
        guard !optedOut else {
            purgeQueue()
            sessions.stop()
            pending.removeAll()
            return
        }
        if let crash = sessions.detectAbnormalTermination() {
            enqueue(crash, at: date)
        }
        enqueue(sessions.start(at: date, first: identity.created), at: date)
        let buffered = pending
        pending.removeAll()
        buffered.forEach(record)
        flushIfThresholdReached()
    }

    private func bufferBeforeConfigure(_ command: Command) {
        guard pending.count < Self.maxPendingBeforeConfigure else {
            Log.warning("event tracked before configure dropped (more than \(Self.maxPendingBeforeConfigure) pending)")
            return
        }
        pending.append(command)
    }

    // MARK: - Événements

    private func record(_ command: Command) {
        switch command {
        case .track(let name, let props, let date):
            guard Validator.isValidName(name, allowReserved: false) else {
                Log.warning("invalid event name '\(name.prefix(64))' dropped")
                return
            }
            enqueue(name: name, props: Validator.sanitize(props, event: name), at: date)
        case .screen(let name, let props, let date):
            guard let screenProps = Self.screenProps(name: name, props: props) else { return }
            enqueue(name: "$screen", props: screenProps, at: date)
        default:
            break
        }
    }

    /// Props de `$screen` : `name` (obligatoire, non vide, sans PII, ≤ 256 car.) prime sur une prop `name`
    /// fournie par l'appelant ; les autres props suivent les règles communes (19 au plus).
    static func screenProps(name: String, props: [String: PropValue]) -> [String: PropValue]? {
        let screenName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !screenName.isEmpty else {
            Log.warning("empty screen name dropped")
            return nil
        }
        guard !Validator.containsPII(screenName) else {
            Log.warning("possible PII in screen name, screen dropped")
            return nil
        }
        var extra = props
        extra["name"] = nil
        var result = Validator.sanitize(extra, event: "$screen", limit: Validator.maxProps - 1)
        let nameValue = PropValue.string(String(screenName.prefix(Validator.maxStringLength)))
        result["name"] = nameValue
        if Validator.serializedSize(result) > Validator.maxPropsBytes {
            result = ["name": nameValue]
        }
        return result
    }

    /// Met un événement en queue dans la session courante, sans validation du nom.
    private func enqueue(name: String, props: [String: PropValue], at date: Date) {
        queue?.append(QueuedEvent(name: name, occurredAt: date, sessionID: sessions.sessionID, props: props))
    }

    private func enqueue(_ emission: SessionTracker.Emission, at date: Date) {
        queue?.append(
            QueuedEvent(name: emission.name, occurredAt: date, sessionID: emission.sessionID, props: emission.props))
    }

    private func handleLifecycle(_ event: LifecycleObserver.Event, at date: Date) {
        switch event {
        case .didBecomeActive where nextSessionIsFirst && !sessions.isActive:
            nextSessionIsFirst = false
            enqueue(sessions.start(at: date, first: true), at: date)
        case .didBecomeActive:
            if let emission = sessions.didBecomeActive(at: date) { enqueue(emission, at: date) }
        case .didEnterBackground:
            guard let emission = sessions.didEnterBackground(at: date) else { return }
            enqueue(emission, at: date)
            queue?.sync()
            requestFlush(nil)
        }
    }

    // MARK: - Identité et opt-out

    /// « Oublie-moi » : les événements en attente appartiennent à l'ancien identifiant, ils sont purgés
    /// (les envoyer sous le nouveau relierait les deux) ; une nouvelle session démarre avec `first = true`.
    private func resetDeviceID(at date: Date) {
        environment.identity.persist()
        let identity = environment.identity.load()
        device?.id = identity.id
        purgeQueue()
        let wasActive = sessions.isActive
        sessions.stop()
        guard !optedOut, !disabled else { return }
        if wasActive {
            enqueue(sessions.start(at: date, first: true), at: date)
        } else {
            nextSessionIsFirst = true
        }
    }

    private func setOptOut(_ value: Bool, at date: Date) {
        guard value != optedOut else { return }
        optedOut = value
        if value {
            purgeQueue()
            pending.removeAll()
            sessions.stop()
            retry?.cancel()
        } else if isConfigured, !disabled {
            enqueue(sessions.start(at: date, first: environment.identity.load().created), at: date)
        }
    }

    private func purgeQueue() {
        queue?.purge()
        inFlight = nil
        generation += 1
    }

    // MARK: - Envoi (C05 §2.5, §2.6)

    private func flushIfThresholdReached() {
        if queuedCount >= options.flushThreshold { requestFlush(nil) }
    }

    private var canSend: Bool {
        guard transport != nil, isConfigured, !optedOut, !disabled, inFlight != nil || queuedCount > 0 else {
            return false
        }
        let now = environment.now()
        if let rateLimitedUntil, now < rateLimitedUntil { return false }
        if let backoffUntil, now < backoffUntil { return false }
        return true
    }

    private func requestFlush(_ completion: (@Sendable () -> Void)?) {
        if let completion { flushWaiters.append(completion) }
        guard !isFlushing else { return }
        guard canSend else {
            finishFlush()
            return
        }
        isFlushing = true
        Task { await drain() }
    }

    /// Envoie des batches séquentiels (les plus anciens d'abord) tant qu'il y a des événements et que
    /// rien ne l'interdit.
    private func drain() async {
        while canSend, let transport, let batch = inFlight?.retried(at: environment.now()) ?? makeBatch() {
            inFlight = batch
            let sentGeneration = generation
            let result = await transport.send(batch)
            guard sentGeneration == generation else { continue }
            guard apply(result, to: batch) else { break }
        }
        isFlushing = false
        finishFlush()
    }

    /// Applique la table de C05 §2.6 ; `false` si l'envoi doit s'arrêter là.
    private func apply(_ result: TransportResult, to batch: Batch) -> Bool {
        switch result {
        case .accepted(_, let rejected):
            queue?.ack(batch.peek)
            inFlight = nil
            backoff.reset()
            backoffUntil = nil
            if rejected > 0 { Log.info("ingest: \(rejected) event(s) rejected by the server") }
            return true
        case .rateLimited(let retryAfter):
            let delay = retryAfter ?? Self.defaultRetryAfter
            rateLimitedUntil = environment.now().addingTimeInterval(delay)
            Log.info("ingest rate limited, retry in \(Int(delay)) s")
            scheduleRetry(after: delay)
            return false
        case .unauthorized(let status):
            Log.error("ingest key refused (HTTP \(status)): queue purged, SDK disabled until next launch")
            purgeQueue()
            disabled = true
            sessions.stop()
            timer?.cancel()
            retry?.cancel()
            return false
        case .rejected(let status, let detail):
            Log.error("batch of \(batch.eventCount) event(s) dropped (HTTP \(status)): \(detail ?? "no detail")")
            queue?.ack(batch.peek)
            inFlight = nil
            return true
        case .retryable(let reason):
            let delay = backoff.nextDelay()
            backoffUntil = environment.now().addingTimeInterval(delay)
            Log.info("ingest failed (\(reason)), retry in \(Int(delay)) s")
            scheduleRetry(after: delay)
            return false
        }
    }

    /// Le plus gros batch possible depuis la tête de la queue : ≤ 500 événements, corps ≤ 1 Mo (moitié
    /// moins d'événements tant que ça dépasse). `nil` si la queue est vide.
    private func makeBatch() -> Batch? {
        guard let queue, let device else { return nil }
        var limit = Batch.maxEvents
        while queue.count > 0 {
            let peek = queue.peek(limit)
            if !peek.events.isEmpty, let batch = Batch(peek: peek, device: device, sentAt: environment.now()) {
                return batch
            }
            if peek.events.count <= 1 {
                Log.error("unsendable queue head dropped")
                queue.ack(peek)
            } else {
                limit = peek.events.count / 2
            }
        }
        return nil
    }

    private func finishFlush() {
        let waiters = flushWaiters
        flushWaiters.removeAll()
        waiters.forEach { $0() }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retry?.cancel()
        retry = Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, delay)))
            guard !Task.isCancelled else { return }
            await self?.handle(.flush(completion: nil))
        }
    }

    private func startTimer(interval: TimeInterval) {
        timer?.cancel()
        timer = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let core = self else { return }
                if await core.queuedCount > 0 { await core.handle(.flush(completion: nil)) }
            }
        }
    }
}
