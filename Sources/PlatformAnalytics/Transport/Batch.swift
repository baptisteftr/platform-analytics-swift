import Foundation

/// Corps de `POST /v1/ingest/events` (C02 §3.1).
struct Batch {
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
