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
                    Log.warning("possible PII: prop '\(key)' dropped")
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

    /// Règles exactes de C02 §3.1, identiques au backend (table de référence : docs/history/events.md).
    /// Recherche (pas correspondance complète) : une valeur qui *contient* un motif est droppée. Chaque
    /// expression, compilée une fois, a un caractère déclencheur (pré-filtre bon marché). Les lookbehind
    /// traduisent les bornes « non précédé de » du contrat ; pour l'email, la borne ne change pas le
    /// résultat (une correspondance en milieu de partie locale s'étend à son début) mais évite un coût
    /// quadratique.
    private static let piiPatterns: [(trigger: UInt8, regex: NSRegularExpression)] = [
        // email
        (UInt8(ascii: "@"), #"(?<![A-Za-z0-9._%+\-])[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),
        // E.164 : « + », un chiffre 1-9, 6 à 14 chiffres précédés chacun d'un espace/point/tiret facultatif, pas de chiffre après
        (UInt8(ascii: "+"), #"\+[1-9](?:[ .\-]?[0-9]){6,14}(?![0-9])"#),
        // IPv4 : octets 0-255 sans zéro non significatif, ni précédés de chiffre/point, ni suivis de chiffre/« .chiffre »
        (
            UInt8(ascii: "."),
            #"(?<![0-9.])(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?![0-9]|\.[0-9])"#
        ),
    ].compactMap { trigger, pattern in (try? NSRegularExpression(pattern: pattern)).map { (trigger, $0) } }

    /// Suites maximales de `[0-9A-Fa-f:.]` contenant au moins deux « : » (le lookbehind impose le début de la
    /// suite, les `*` gourmands sa fin), confirmées ensuite par `inet_pton`.
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

    /// La suite maximale entière doit être une IPv6 valide : pas de nettoyage (un « . » final l'invalide).
    private static func isIPv6(_ run: String) -> Bool {
        var address = in6_addr()
        return run.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }

    private static func isIdentifier(_ text: Substring, maxLength: Int) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maxLength else { return false }
        return text.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x5F
        }
    }
}
