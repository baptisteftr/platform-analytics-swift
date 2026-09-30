extension Analytics {
    /// Niveau de log du SDK (`os.Logger`, subsystem `com.platform.analytics`).
    public enum LogLevel: Sendable {
        case off, error, warning, info, debug

        /// Ordre de verbosité croissante (`off` < `error` < … < `debug`).
        var rank: Int {
            switch self {
            case .off: 0
            case .error: 1
            case .warning: 2
            case .info: 3
            case .debug: 4
            }
        }
    }
}
