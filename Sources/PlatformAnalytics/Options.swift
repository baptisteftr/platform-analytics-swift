import Foundation

extension Analytics {
    /// Réglages du SDK, tous avec une valeur par défaut. Les valeurs hors bornes sont ramenées dans les bornes.
    public struct Options: Sendable {
        /// Intervalle entre deux flush automatiques, en secondes (défaut 30, minimum 1).
        public var flushInterval: TimeInterval
        /// Nombre d'événements en attente qui déclenche un flush (défaut 30, minimum 1).
        public var flushThreshold: Int
        /// Taille maximale de la queue ; au-delà, les plus anciens sont supprimés (défaut 5 000, minimum 1).
        public var maxQueuedEvents: Int
        /// Réservé : le suivi automatique des écrans n'existe pas en 1.x (log `warning` si `true`).
        public var trackScreensAutomatically: Bool
        /// Niveau de log minimal (défaut `.warning`).
        public var logLevel: LogLevel

        public init(
            flushInterval: TimeInterval = 30,
            flushThreshold: Int = 30,
            maxQueuedEvents: Int = 5_000,
            trackScreensAutomatically: Bool = false,
            logLevel: LogLevel = .warning
        ) {
            self.flushInterval = flushInterval
            self.flushThreshold = flushThreshold
            self.maxQueuedEvents = maxQueuedEvents
            self.trackScreensAutomatically = trackScreensAutomatically
            self.logLevel = logLevel
        }

        /// Copie dont les valeurs sont ramenées dans leurs bornes.
        var sanitized: Options {
            var copy = self
            copy.flushInterval = flushInterval.isFinite ? max(1, flushInterval) : 30
            copy.flushThreshold = max(1, flushThreshold)
            copy.maxQueuedEvents = max(1, maxQueuedEvents)
            return copy
        }
    }
}
