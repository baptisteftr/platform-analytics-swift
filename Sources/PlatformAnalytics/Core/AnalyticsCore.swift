import Foundation

/// Cœur du SDK : reçoit les commandes de la façade dans l'ordre, valide, met en queue, décide des flush.
/// Toute I/O (disque, Keychain, réseau) se fait ici, jamais sur le thread appelant.
actor AnalyticsCore {
    enum Command: Sendable {
        case configure(ingestKey: String, endpoint: URL, options: Analytics.Options, at: Date)
        case track(name: String, props: [String: PropValue], at: Date)
        case screen(name: String, props: [String: PropValue], at: Date)
        case flush
        case lifecycle(LifecycleObserver.Event, at: Date)
        case resetDeviceID(at: Date)
    }

    /// Dépendances injectables (tests).
    struct Environment: Sendable {
        var queueDirectory: @Sendable () -> URL?
        var now: @Sendable () -> Date
        var identity: DeviceIdentity
        var device: @Sendable () -> Batch.Device

        static let live = Environment(
            queueDirectory: { EventQueue.defaultDirectory() }, now: { Date() }, identity: DeviceIdentity(),
            device: { Batch.Device.current() })
    }

    static let maxPendingBeforeConfigure = 100

    private let environment: Environment
    private(set) var isConfigured = false
    private(set) var options = Analytics.Options()
    private var ingestKey = ""
    private var endpoint: URL?
    private var queue: EventQueue?
    private var pending: [Command] = []
    private var sessions = SessionTracker(
        markerDirectory: nil,
        device: .init(id: "", model: "", osVersion: "", appVersion: "", buildNumber: "", locale: ""))
    /// Après un reset d'identité en arrière-plan, la prochaine session porte `first = true`.
    private var nextSessionIsFirst = false
    /// Copie locale de l'identifiant : ne change qu'au traitement de `resetDeviceID`, dans l'ordre des commandes.
    private(set) var device: Batch.Device?

    init(environment: Environment = .live) {
        self.environment = environment
    }

    func handle(_ command: Command) {
        switch command {
        case .configure(let key, let url, let options, let date):
            configure(ingestKey: key, endpoint: url, options: options, at: date)
        case .track, .screen:
            guard isConfigured else {
                bufferBeforeConfigure(command)
                return
            }
            record(command)
        case .flush:
            guard isConfigured else { return }
            queue?.sync()
        case .lifecycle(let event, let date):
            guard isConfigured else { return }
            let emission: SessionTracker.Emission?
            switch event {
            case .didBecomeActive where nextSessionIsFirst && !sessions.isActive:
                nextSessionIsFirst = false
                emission = sessions.start(at: date, first: true)
            case .didBecomeActive: emission = sessions.didBecomeActive(at: date)
            case .didEnterBackground: emission = sessions.didEnterBackground(at: date)
            }
            if let emission { enqueue(emission, at: date) }
        case .resetDeviceID(let date):
            guard isConfigured else {
                environment.identity.persist()
                return
            }
            resetDeviceID(at: date)
        }
    }

    /// Nombre d'événements en attente sur disque (tests, diagnostic).
    var queuedCount: Int { queue?.count ?? 0 }

    /// Les événements en attente, sans les retirer (tests, diagnostic).
    func queuedEvents(limit: Int = 500) -> [QueuedEvent] { queue?.peek(limit).events ?? [] }

    // MARK: - Configuration

    private func configure(ingestKey: String, endpoint: URL, options: Analytics.Options, at date: Date) {
        guard !isConfigured else { return }
        self.ingestKey = ingestKey
        self.endpoint = endpoint
        self.options = options
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
        isConfigured = true
        if let crash = sessions.detectAbnormalTermination() {
            enqueue(crash, at: date)
        }
        enqueue(sessions.start(at: date, first: identity.created), at: date)
        let buffered = pending
        pending.removeAll()
        buffered.forEach(record)
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
        case .configure, .flush, .lifecycle, .resetDeviceID:
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

    // MARK: - Identité

    /// « Oublie-moi » : les événements en attente appartiennent à l'ancien identifiant, ils sont purgés
    /// (les envoyer sous le nouveau relierait les deux) ; une nouvelle session démarre avec `first = true`.
    private func resetDeviceID(at date: Date) {
        environment.identity.persist()
        let identity = environment.identity.load()
        device?.id = identity.id
        queue?.purge()
        let wasActive = sessions.isActive
        sessions.stop()
        if wasActive {
            enqueue(sessions.start(at: date, first: true), at: date)
        } else {
            nextSessionIsFirst = true
        }
    }
}
