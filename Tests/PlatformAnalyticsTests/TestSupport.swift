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

/// Horloge manipulable.
final class TestClock: Sendable {
    private let date = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_790_000_000))
    var now: Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
}

/// Transport simulé : rejoue une suite de résultats (puis `202`) et enregistre les batches reçus.
actor MockTransport: Transport {
    private var script: [TransportResult]
    private let fallback: TransportResult?
    private(set) var batches: [Batch] = []

    /// `fallback` : résultat une fois le script épuisé (`nil` = `202` avec tous les événements acceptés).
    init(_ script: [TransportResult] = [], fallback: TransportResult? = nil) {
        self.script = script
        self.fallback = fallback
    }

    /// Toujours hors ligne : les événements restent en queue.
    static var offline: MockTransport { MockTransport(fallback: .retryable(reason: "offline")) }

    func send(_ batch: Batch) async -> TransportResult {
        batches.append(batch)
        if !script.isEmpty { return script.removeFirst() }
        return fallback ?? .accepted(accepted: batch.eventCount, rejected: 0)
    }

    func enqueue(_ results: TransportResult...) { script += results }

    var payloads: [Batch.Payload] {
        batches.compactMap { try? JSONDecoder().decode(Batch.Payload.self, from: $0.body) }
    }
}

extension AnalyticsCore {
    static func make(
        directory: URL, store: MemoryStore = MemoryStore(), device: Batch.Device = .fixture(),
        identity: DeviceIdentity? = nil, transport: MockTransport = .offline, clock: TestClock = TestClock()
    ) -> AnalyticsCore {
        AnalyticsCore(
            environment: .init(
                queueDirectory: { directory }, now: { clock.now }, identity: identity ?? DeviceIdentity(store: store),
                device: { device }, makeTransport: { _, _ in transport }))
    }

    func configureForTests(
        at date: Date = Date(timeIntervalSince1970: 1_790_000_000), options: Analytics.Options = .init(),
        optedOut: Bool = false
    ) {
        handle(
            .configure(
                ingestKey: "ik_test", endpoint: URL(filePath: "/dev/null"), options: options, optedOut: optedOut,
                at: date))
    }
}
