import Foundation
import os

@testable import PlatformAnalytics

/// Stockage mémoire pour `DeviceIdentity` (pas de Keychain dans `swift test`).
final class MemoryStore: DeviceIdentity.Store {
    private let value: OSAllocatedUnfairLock<String?>
    init(_ initial: String? = nil) { value = OSAllocatedUnfairLock(initialState: initial) }
    var stored: String? { value.withLock { $0 } }
    func read() -> String? { stored }
    func write(_ newValue: String) -> Bool {
        value.withLock { $0 = newValue }
        return true
    }
}

func temporaryDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
}

extension Batch.Device {
    static func fixture(appVersion: String = "2.1.0", osVersion: String = "26.0") -> Batch.Device {
        Batch.Device(
            id: "", model: "iPhone16,1", osVersion: osVersion, appVersion: appVersion, buildNumber: "214",
            locale: "fr_FR")
    }
}

extension AnalyticsCore {
    static func make(
        directory: URL, store: MemoryStore = MemoryStore(), device: Batch.Device = .fixture()
    ) -> AnalyticsCore {
        AnalyticsCore(
            environment: .init(
                queueDirectory: { directory }, now: { Date() }, identity: DeviceIdentity(store: store),
                device: { device }))
    }

    func configureForTests(at date: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        handle(.configure(ingestKey: "ik_test", endpoint: URL(filePath: "/dev/null"), options: .init(), at: date))
    }
}
