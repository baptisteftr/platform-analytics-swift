import Foundation

/// Sessions et détection heuristique des fins anormales (C05 §2.2, §2.3). Logique pure, pilotée par
/// l'actor avec des dates explicites ; seule I/O : le marqueur `session.active`.
struct SessionTracker {
    /// Événement à mettre en queue, avec la session à laquelle il appartient.
    struct Emission: Equatable {
        var name: String
        var props: [String: PropValue]
        var sessionID: String
    }

    /// Contenu du marqueur : la session en cours et les versions qui permettent d'exclure une mise à jour.
    struct Marker: Codable, Equatable {
        var sessionID: String
        var appVersion: String
        var buildNumber: String
        var osVersion: String
    }

    /// Au-delà de cette durée en arrière-plan, le retour au premier plan ouvre une nouvelle session.
    static let resumeThreshold: TimeInterval = 30

    private(set) var sessionID = UUID().uuidString
    private(set) var isActive = false
    private var activeSince: Date?
    private var foregroundTime: TimeInterval = 0
    private var backgroundSince: Date?
    private let markerURL: URL?
    private let device: Batch.Device

    init(markerDirectory: URL?, device: Batch.Device) {
        self.markerURL = markerDirectory?.appending(path: "session.active", directoryHint: .notDirectory)
        self.device = device
    }

    /// Au lancement : si le marqueur d'une session précédente est resté (pas de `$session_end` propre)
    /// et que ni l'app ni l'OS n'ont changé de version, `$crash`. Le marqueur est consommé dans tous les cas.
    func detectAbnormalTermination() -> Emission? {
        guard let markerURL, let data = try? Data(contentsOf: markerURL) else { return nil }
        try? FileManager.default.removeItem(at: markerURL)
        guard let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return nil }
        guard marker.appVersion == device.appVersion, marker.buildNumber == device.buildNumber,
            marker.osVersion == device.osVersion
        else {
            Log.info("previous session ended during an update, no $crash")
            return nil
        }
        return Emission(name: "$crash", props: ["signal": "unknown", "top_frame": ""], sessionID: marker.sessionID)
    }

    /// Nouvelle session : nouvel identifiant, marqueur écrit, `$session_start`.
    mutating func start(at date: Date, first: Bool) -> Emission {
        sessionID = UUID().uuidString
        isActive = true
        activeSince = date
        foregroundTime = 0
        backgroundSince = nil
        writeMarker()
        return Emission(name: "$session_start", props: ["first": .bool(first)], sessionID: sessionID)
    }

    /// Retour au premier plan : nouvelle session après plus de 30 s en arrière-plan, sinon reprise de la
    /// session en cours (sans événement).
    mutating func didBecomeActive(at date: Date) -> Emission? {
        guard !isActive else { return nil }
        if let backgroundSince, date.timeIntervalSince(backgroundSince) <= Self.resumeThreshold {
            isActive = true
            activeSince = date
            self.backgroundSince = nil
            writeMarker()
            return nil
        }
        return start(at: date, first: false)
    }

    /// Passage en arrière-plan : `$session_end` avec la durée cumulée au premier plan de la session.
    mutating func didEnterBackground(at date: Date) -> Emission? {
        guard isActive, let activeSince else { return nil }
        foregroundTime += max(0, date.timeIntervalSince(activeSince))
        isActive = false
        self.activeSince = nil
        backgroundSince = date
        removeMarker()
        let durationMS = Int((foregroundTime * 1_000).rounded())
        return Emission(name: "$session_end", props: ["duration_ms": .int(durationMS)], sessionID: sessionID)
    }

    /// Arrêt sans événement (opt-out, reset d'identité) : plus de session ni de marqueur.
    mutating func stop() {
        isActive = false
        activeSince = nil
        backgroundSince = nil
        removeMarker()
    }

    private func writeMarker() {
        guard let markerURL else { return }
        let marker = Marker(
            sessionID: sessionID, appVersion: device.appVersion, buildNumber: device.buildNumber,
            osVersion: device.osVersion)
        do {
            try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
        } catch {
            Log.warning("session marker write failed (\(error.localizedDescription))")
        }
    }

    private func removeMarker() {
        guard let markerURL else { return }
        try? FileManager.default.removeItem(at: markerURL)
    }
}
