import Foundation
import os

/// Façade publique du SDK. Tous les appels sont synchrones, non bloquants et ne lèvent jamais :
/// ils transmettent une commande, dans l'ordre d'appel, à l'actor interne qui fait le travail.
public enum Analytics {
    /// Endpoint compilé utilisé quand `configure` n'en reçoit pas.
    static let defaultEndpoint = URL(string: "https://api.baptcave.example/v1")
    /// Version du SDK envoyée dans chaque batch (`sdk.version`).
    static let sdkVersion = "1.0.0"
    static let optOutKey = "com.platform.analytics.optOut"

    /// À appeler une fois, au lancement (`App.init`). Un second appel est ignoré (log `warning`).
    /// No-op silencieux dans une extension (`.appex`) : pas d'analytics hors de l'app en 1.x.
    public static func configure(ingestKey: String, endpoint: URL? = nil, options: Options = .init()) {
        guard !isAppExtension(bundlePath: Bundle.main.bundlePath) else { return }
        let key = ingestKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            Log.error("configure: empty ingest key, SDK disabled")
            return
        }
        guard let url = endpoint ?? defaultEndpoint else { return }
        guard runtime.markConfigured() else {
            Log.warning("configure called more than once, ignored")
            return
        }
        let sanitized = options.sanitized
        Log.currentLevel = sanitized.logLevel
        runtime.send(
            .configure(ingestKey: key, endpoint: url, options: sanitized, optedOut: optOut, at: Date()))
        runtime.startObserving()
    }

    /// Événement custom. `name` : `^[a-z0-9_]{1,64}$` ; props validées (C05 §2.4) avant mise en queue.
    public static func track(_ name: String, props: [String: PropValue] = [:]) {
        runtime.send(.track(name: name, props: props, at: Date()))
    }

    /// Écran affiché (événement `$screen`), pour les cas sans vue ; sinon `.analyticsScreen(_:)`.
    public static func screen(_ name: String, props: [String: PropValue] = [:]) {
        runtime.send(.screen(name: name, props: props, at: Date()))
    }

    /// Force un envoi (asynchrone, non bloquant).
    public static func flush() {
        runtime.send(.flush(completion: nil))
    }

    /// `true` : plus aucun événement, plus de session ni de réseau, queue purgée. Persisté
    /// (`UserDefaults`, `com.platform.analytics.optOut`). `false` : reprise avec une nouvelle session.
    public static var optOut: Bool {
        get { UserDefaults.standard.bool(forKey: optOutKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: optOutKey)
            runtime.send(.setOptOut(newValue, at: Date()))
        }
    }

    /// Nouveau `device_id` anonyme (« oublie-moi » côté client) : les événements pas encore envoyés
    /// sont purgés et une nouvelle session commence.
    public static func resetDeviceID() {
        runtime.identity.rotate()
        runtime.send(.resetDeviceID(at: Date()))
    }

    /// Identifiant anonyme de l'appareil, à afficher dans un écran « Confidentialité » si besoin.
    public static var deviceID: String { runtime.identity.current }

    /// `true` après un `configure` accepté.
    public static var isConfigured: Bool { runtime.isConfigured }

    static func isAppExtension(bundlePath: String) -> Bool {
        bundlePath.hasSuffix(".appex") || bundlePath.hasSuffix(".appex/")
    }

    // MARK: - Exécution

    static let runtime = Runtime(environment: .live)

    /// Relie la façade à l'actor : une file de commandes ordonnée, consommée par une seule tâche.
    final class Runtime: Sendable {
        let core: AnalyticsCore
        let identity: DeviceIdentity
        private let continuation: AsyncStream<AnalyticsCore.Command>.Continuation
        private let configured = OSAllocatedUnfairLock(initialState: false)
        private let observers = OSAllocatedUnfairLock<(LifecycleObserver, Reachability)?>(initialState: nil)

        init(environment: AnalyticsCore.Environment) {
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyticsCore.Command.self)
            let core = AnalyticsCore(environment: environment)
            self.core = core
            self.identity = environment.identity
            self.continuation = continuation
            Task.detached(priority: .utility) {
                for await command in stream {
                    await core.handle(command)
                }
            }
        }

        var isConfigured: Bool { configured.withLock { $0 } }

        /// Passe à « configuré » ; `false` si c'était déjà le cas.
        func markConfigured() -> Bool {
            configured.withLock { alreadyConfigured in
                defer { alreadyConfigured = true }
                return !alreadyConfigured
            }
        }

        func send(_ command: AnalyticsCore.Command) {
            continuation.yield(command)
        }

        /// Les notifications passent par la même file que les appels publics : l'ordre est conservé.
        /// En arrière-plan, une tâche de fond couvre l'envoi de `$session_end`.
        func startObserving() {
            observers.withLock { observers in
                guard observers == nil else { return }
                let lifecycle = LifecycleObserver { [weak self] event in
                    guard let self else { return }
                    guard event == .didEnterBackground else {
                        self.send(.lifecycle(event, at: Date()))
                        return
                    }
                    let task = LifecycleObserver.BackgroundTask.begin()
                    self.send(.lifecycle(event, at: Date()))
                    self.send(.flush(completion: { task.end() }))
                }
                let reachability = Reachability { [weak self] in self?.send(.networkRestored) }
                observers = (lifecycle, reachability)
            }
        }
    }
}
