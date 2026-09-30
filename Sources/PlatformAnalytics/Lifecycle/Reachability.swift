import Foundation
import Network
import os

/// Signale le retour du réseau (`NWPathMonitor`) : chemin redevenu `satisfied` après ne plus l'avoir été.
final class Reachability: Sendable {
    private let monitor = NWPathMonitor()

    init(onRestore: @escaping @Sendable () -> Void) {
        let wasUnsatisfied = OSAllocatedUnfairLock(initialState: false)
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            let restored = wasUnsatisfied.withLock { previous in
                defer { previous = !satisfied }
                return previous && satisfied
            }
            if restored { onRestore() }
        }
        monitor.start(queue: DispatchQueue(label: "com.platform.analytics.reachability", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }
}
