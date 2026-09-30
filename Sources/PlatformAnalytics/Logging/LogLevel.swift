extension Analytics {
    /// Niveau de log du SDK (`os.Logger`, subsystem `com.platform.analytics`).
    public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
        case off = 0
        case error = 1
        case warning = 2
        case info = 3
        case debug = 4

        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
    }
}
