import Foundation

/// Événement tel que stocké dans la queue et envoyé dans un batch (objet `events[]` de C02 §3.1).
struct QueuedEvent: Codable, Equatable, Sendable {
    var name: String
    var occurredAt: Date
    var sessionID: String
    var props: [String: PropValue]

    enum CodingKeys: String, CodingKey {
        case name
        case occurredAt = "occurred_at"
        case sessionID = "session_id"
        case props
    }

    /// Horodatage RFC 3339 UTC avec millisecondes (`2026-09-30T14:03:00.120Z`), format de C02 §1.5 / §3.1.
    static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)

    static func timestamp(_ date: Date) -> String { date.formatted(timestampStyle) }

    init(name: String, occurredAt: Date, sessionID: String, props: [String: PropValue]) {
        self.name = name
        self.occurredAt = occurredAt
        self.sessionID = sessionID
        self.props = props
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        props = try container.decodeIfPresent([String: PropValue].self, forKey: .props) ?? [:]
        let raw = try container.decode(String.self, forKey: .occurredAt)
        guard let date = try? Date(raw, strategy: Self.timestampStyle) else {
            throw DecodingError.dataCorruptedError(
                forKey: .occurredAt, in: container, debugDescription: "invalid RFC 3339 timestamp")
        }
        occurredAt = date
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(Self.timestamp(occurredAt), forKey: .occurredAt)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(props, forKey: .props)
    }
}
