import Foundation

/// Validation locale des événements, identique aux règles d'ingestion du serveur (C05 §2.4, C02 §3.1).
/// Ce qui est invalide est droppé (événement ou prop) avec un log ; rien n'est jamais levé.
enum Validator {
    static let maxNameLength = 64
    static let maxProps = 20
    static let maxKeyLength = 32
    static let maxStringLength = 256
    static let maxPropsBytes = 4_096
    /// Seul nom réservé accepté depuis le code applicatif (relais MetricKit, C05 §2.3).
    static let externalReservedNames: Set<String> = ["$crash"]

    /// Nom d'événement valide ? `^[a-z0-9_]{1,64}$` ; les noms `$…` sont réservés au SDK,
    /// sauf `$crash` accepté depuis l'extérieur.
    static func isValidName(_ name: String, allowReserved: Bool) -> Bool {
        if name.hasPrefix("$") {
            let base = name.dropFirst()
            return (allowReserved || externalReservedNames.contains(name))
                && isIdentifier(base, maxLength: maxNameLength - 1)
        }
        return isIdentifier(name[...], maxLength: maxNameLength)
    }

    static func isValidKey(_ key: String) -> Bool {
        isIdentifier(key[...], maxLength: maxKeyLength)
    }

    /// Nettoie les props : clés invalides, valeurs PII et doubles non finis droppés, chaînes tronquées,
    /// `limit` props au plus (20 par défaut, ordre alphabétique des clés), 4 Ko sérialisés au plus
    /// (sinon aucune prop).
    static func sanitize(
        _ props: [String: PropValue], event name: String, limit: Int = maxProps
    ) -> [String: PropValue] {
        var result: [String: PropValue] = [:]
        var dropped = 0
        for key in props.keys.sorted() {
            guard let value = props[key] else { continue }
            guard isValidKey(key) else {
                dropped += 1
                continue
            }
            switch value {
            case .string(let string):
                if containsPII(string) {
                    Log.warning("possible PII: prop '\(key)' of '\(name)' dropped")
                    continue
                }
                result[key] = .string(String(string.prefix(maxStringLength)))
            case .double(let double) where !double.isFinite:
                dropped += 1
            default:
                result[key] = value
            }
        }
        if result.count > limit {
            for key in result.keys.sorted().dropFirst(limit) {
                result[key] = nil
                dropped += 1
            }
        }
        if dropped > 0 {
            Log.warning("\(dropped) invalid or excess prop(s) dropped from '\(name)'")
        }
        if serializedSize(result) > maxPropsBytes {
            Log.warning("props of '\(name)' exceed \(maxPropsBytes) bytes, event kept without props")
            return [:]
        }
        return result
    }

    static func serializedSize(_ props: [String: PropValue]) -> Int {
        (try? JSONEncoder().encode(props).count) ?? Int.max
    }

    // MARK: - PII

    /// Expressions compilées une seule fois, chacune précédée d'un caractère déclencheur (pré-filtre bon
    /// marché). Recherche (pas correspondance exacte) : une valeur qui *contient* un email, un numéro
    /// E.164, une IPv4 ou une IPv6 est droppée. Les lookbehind évitent un coût quadratique.
    private static let piiPatterns: [(trigger: UInt8, regex: NSRegularExpression)] = [
        // email
        (UInt8(ascii: "@"), #"(?<![A-Za-z0-9._%+\-])[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),
        // E.164 : « + » puis 7 à 15 chiffres, séparateurs usuels tolérés (espace, point, tiret)
        (UInt8(ascii: "+"), #"\+[1-9](?:[ .\-]?[0-9]){6,14}(?![0-9])"#),
        // IPv4
        (
            UInt8(ascii: "."),
            #"(?<![0-9.])(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?![0-9]|\.[0-9])"#
        ),
    ].compactMap { trigger, pattern in (try? NSRegularExpression(pattern: pattern)).map { (trigger, $0) } }

    /// Candidats IPv6 (au moins deux « : »), confirmés ensuite par `inet_pton`.
    private static let ipv6Candidate = try? NSRegularExpression(
        pattern: #"(?<![0-9A-Fa-f:.])[0-9A-Fa-f:.]*:[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*"#)

    static func containsPII(_ value: String) -> Bool {
        let bytes = value.utf8
        let range = NSRange(value.startIndex..., in: value)
        for (trigger, regex) in piiPatterns where bytes.contains(trigger) {
            if regex.firstMatch(in: value, range: range) != nil { return true }
        }
        guard let ipv6Candidate, bytes.lazy.filter({ $0 == UInt8(ascii: ":") }).count >= 2 else { return false }
        return ipv6Candidate.matches(in: value, range: range).contains { match in
            guard let swiftRange = Range(match.range, in: value) else { return false }
            return isIPv6(String(value[swiftRange]))
        }
    }

    private static func isIPv6(_ candidate: String) -> Bool {
        let token = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard token.contains(where: \.isHexDigit) else { return false }
        var address = in6_addr()
        return token.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }

    private static func isIdentifier(_ text: Substring, maxLength: Int) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maxLength else { return false }
        return text.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x5F
        }
    }
}
