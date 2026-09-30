import Foundation

/// Un envoi : corps JSON de `POST /v1/ingest/events` (C02 §3.1) **figé** à la création, et sa clé
/// d'idempotence. Un retry renvoie exactement les mêmes octets avec la même clé (sinon `409`, C02 §1.4).
struct Batch: Sendable {
    static let maxEvents = 500
    static let maxBodyBytes = 1_000_000
    static let sdk = SDK(name: "swift", version: Analytics.sdkVersion)

    let idempotencyKey: String
    let body: Data
    /// Portion de la queue couverte, à acquitter après l'envoi.
    let peek: EventQueue.Peek

    var eventCount: Int { peek.events.count }

    /// `nil` si l'encodage échoue ou si le corps dépasse 1 Mo avec plus d'un événement (l'appelant
    /// recommence avec un peek plus petit).
    init?(peek: EventQueue.Peek, device: Device, sentAt: Date) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let payload = Payload(sdk: Self.sdk, sentAt: QueuedEvent.timestamp(sentAt), device: device, events: peek.events)
        guard let body = try? encoder.encode(payload), body.count <= Self.maxBodyBytes || peek.events.count <= 1
        else { return nil }
        self.peek = peek
        self.body = body
        self.idempotencyKey = UUID().uuidString
    }

    struct SDK: Codable, Equatable, Sendable {
        var name: String
        var version: String
    }

    struct Payload: Codable, Equatable {
        var sdk: SDK
        var sentAt: String
        var device: Device
        var events: [QueuedEvent]

        enum CodingKeys: String, CodingKey {
            case sdk, device, events
            case sentAt = "sent_at"
        }
    }

    /// Bloc `device` : identifiant anonyme et caractéristiques non identifiantes de l'appareil.
    struct Device: Codable, Equatable, Sendable {
        var id: String
        var model: String
        var osVersion: String
        var appVersion: String
        var buildNumber: String
        var locale: String

        enum CodingKeys: String, CodingKey {
            case id, model, locale
            case osVersion = "os_version"
            case appVersion = "app_version"
            case buildNumber = "build_number"
        }

        /// Valeurs de l'appareil courant ; `id` est renseigné au moment de l'envoi.
        static func current(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) -> Device {
            let version = processInfo.operatingSystemVersion
            var osVersion = "\(version.majorVersion).\(version.minorVersion)"
            if version.patchVersion > 0 { osVersion += ".\(version.patchVersion)" }
            let info = bundle.infoDictionary ?? [:]
            return Device(
                id: "",
                model: processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardwareModel(),
                osVersion: osVersion,
                appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
                buildNumber: info["CFBundleVersion"] as? String ?? "",
                locale: localeIdentifier(.current))
        }

        /// `fr_FR` : langue et région seulement (pas de calendrier, de script ni de variante).
        static func localeIdentifier(_ locale: Locale) -> String {
            let language = locale.language.languageCode?.identifier ?? "und"
            guard let region = locale.region?.identifier else { return language }
            return "\(language)_\(region)"
        }

        /// `iPhone16,1`, `Mac14,2`, `RealityDevice14,1`.
        private static func hardwareModel() -> String {
            #if os(macOS)
                let key = "hw.model"
            #else
                let key = "hw.machine"
            #endif
            var size = 0
            guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return "unknown" }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}
