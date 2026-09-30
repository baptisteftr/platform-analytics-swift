import Foundation
import os

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Observe le cycle de vie de l'app (UIKit ou AppKit) et le traduit en deux événements (C05 §2.2).
/// La session suit l'app, pas la scène : ce sont des notifications d'application, pas de scène.
final class LifecycleObserver: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case didBecomeActive
        case didEnterBackground
    }

    struct Names: Sendable {
        var active: [Notification.Name]
        var background: [Notification.Name]

        /// `willTerminate` s'ajoute au passage en arrière-plan : une fin propre ne doit pas compter comme crash.
        static var system: Names {
            #if canImport(UIKit)
                Names(
                    active: [UIApplication.didBecomeActiveNotification],
                    background: [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification])
            #elseif canImport(AppKit)
                Names(
                    active: [NSApplication.didBecomeActiveNotification],
                    background: [NSApplication.didResignActiveNotification, NSApplication.willTerminateNotification])
            #else
                Names(active: [], background: [])
            #endif
        }
    }

    // Immuables après init : d'où `@unchecked Sendable`.
    private let center: NotificationCenter
    private let tokens: [any NSObjectProtocol]

    init(
        center: NotificationCenter = .default, names: Names = .system,
        handler: @escaping @Sendable (Event) -> Void
    ) {
        self.center = center
        let active = names.active.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in handler(.didBecomeActive) }
        }
        let background = names.background.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in handler(.didEnterBackground) }
        }
        tokens = active + background
    }

    deinit {
        tokens.forEach(center.removeObserver)
    }
}

extension LifecycleObserver {
    /// `beginBackgroundTask` (UIKit) le temps d'envoyer `$session_end` en arrière-plan (budget système ~5 s).
    /// Sans objet sur macOS. Toujours appelé et terminé sur le main thread.
    struct BackgroundTask: Sendable {
        #if canImport(UIKit)
            private let identifier = OSAllocatedUnfairLock(initialState: UIBackgroundTaskIdentifier.invalid)
        #endif

        static func begin() -> BackgroundTask {
            let task = BackgroundTask()
            #if canImport(UIKit)
                onMain {
                    let id = UIApplication.shared.beginBackgroundTask(withName: "com.platform.analytics.flush") {
                        task.end()
                    }
                    task.identifier.withLock { $0 = id }
                }
            #endif
            return task
        }

        func end() {
            #if canImport(UIKit)
                onMain {
                    let id = identifier.withLock { current in
                        defer { current = .invalid }
                        return current
                    }
                    if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
                }
            #endif
        }

        private static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
            if Thread.isMainThread {
                MainActor.assumeIsolated(work)
            } else {
                Task { @MainActor in work() }
            }
        }

        private func onMain(_ work: @escaping @MainActor @Sendable () -> Void) { Self.onMain(work) }
    }
}
