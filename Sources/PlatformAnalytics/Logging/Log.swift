import os

/// Journal interne. Les messages ne contiennent jamais de valeur de prop (seulement des noms de clés).
enum Log {
    private static let logger = Logger(subsystem: "com.platform.analytics", category: "sdk")
    private static let level = OSAllocatedUnfairLock(initialState: Analytics.LogLevel.warning)

    static var currentLevel: Analytics.LogLevel {
        get { level.withLock { $0 } }
        set { level.withLock { $0 = newValue } }
    }

    static func error(_ message: @autoclosure () -> String) { emit(.error, message) }
    static func warning(_ message: @autoclosure () -> String) { emit(.warning, message) }
    static func info(_ message: @autoclosure () -> String) { emit(.info, message) }
    static func debug(_ message: @autoclosure () -> String) { emit(.debug, message) }

    private static func emit(_ messageLevel: Analytics.LogLevel, _ message: () -> String) {
        guard messageLevel != .off, messageLevel <= currentLevel else { return }
        let text = message()
        switch messageLevel {
        case .error: logger.error("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .debug, .off: logger.debug("\(text, privacy: .public)")
        }
    }
}
