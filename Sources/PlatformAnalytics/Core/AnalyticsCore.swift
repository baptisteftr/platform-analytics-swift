import Foundation

/// Cœur du SDK : reçoit les commandes de la façade dans l'ordre, valide, met en queue, décide des flush.
/// Toute I/O (disque, Keychain, réseau) se fait ici, jamais sur le thread appelant.
actor AnalyticsCore {
    enum Command: Sendable {
        case configure(ingestKey: String, endpoint: URL, options: Analytics.Options)
        case track(name: String, props: [String: PropValue], at: Date)
        case screen(name: String, props: [String: PropValue], at: Date)
        case flush
    }

    /// Dépendances injectables (tests).
    struct Environment: Sendable {
        var queueDirectory: @Sendable () -> URL?
        var now: @Sendable () -> Date

        static let live = Environment(queueDirectory: { EventQueue.defaultDirectory() }, now: { Date() })
    }

    static let maxPendingBeforeConfigure = 100

    private let environment: Environment
    private(set) var isConfigured = false
    private(set) var options = Analytics.Options()
    private var ingestKey = ""
    private var endpoint: URL?
    private var queue: EventQueue?
    private var pending: [Command] = []
    private var sessionID = UUID().uuidString

    init(environment: Environment = .live) {
        self.environment = environment
    }

    func handle(_ command: Command) {
        switch command {
        case .configure(let key, let url, let options):
            configure(ingestKey: key, endpoint: url, options: options)
        case .track, .screen:
            guard isConfigured else {
                bufferBeforeConfigure(command)
                return
            }
            record(command)
        case .flush:
            guard isConfigured else { return }
            queue?.sync()
        }
    }

    /// Nombre d'événements en attente sur disque (tests, diagnostic).
    var queuedCount: Int { queue?.count ?? 0 }

    /// Les événements en attente, sans les retirer (tests, diagnostic).
    func queuedEvents(limit: Int = 500) -> [QueuedEvent] { queue?.peek(limit).events ?? [] }

    // MARK: - Configuration

    private func configure(ingestKey: String, endpoint: URL, options: Analytics.Options) {
        guard !isConfigured else { return }
        self.ingestKey = ingestKey
        self.endpoint = endpoint
        self.options = options
        Log.currentLevel = options.logLevel
        if options.trackScreensAutomatically {
            Log.warning("trackScreensAutomatically: not implemented in 1.x, use .analyticsScreen(_:)")
        }
        if let directory = environment.queueDirectory() {
            queue = EventQueue(directory: directory, maxEvents: options.maxQueuedEvents)
        } else {
            Log.error("no Application Support directory, events will be dropped")
        }
        isConfigured = true
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
        case .configure, .flush:
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

    /// Met un événement en queue, sans validation du nom (événements internes `$…` compris).
    func enqueue(name: String, props: [String: PropValue], at date: Date) {
        guard let queue else { return }
        queue.append(QueuedEvent(name: name, occurredAt: date, sessionID: sessionID, props: props))
    }
}
