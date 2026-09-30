import Foundation

/// Transport HTTP : `URLSession` éphémère dédiée, jamais de `waitsForConnectivity`, pas de réseau « économie
/// de données » (le batch reste en queue).
struct URLSessionTransport: Transport {
    let url: URL
    let ingestKey: String
    private let session: URLSession

    /// `protocolClasses` : interception des requêtes dans les tests.
    init(endpoint: URL, ingestKey: String, protocolClasses: [AnyClass]? = nil) {
        self.url = endpoint.appending(path: "ingest/events", directoryHint: .notDirectory)
        self.ingestKey = ingestKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration)
    }

    func send(_ batch: Batch) async -> TransportResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = batch.body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(ingestKey)", forHTTPHeaderField: "Authorization")
        request.setValue(batch.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retryable(reason: "no HTTP response") }
            return Self.result(
                status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"), body: data)
        } catch {
            return .retryable(reason: (error as? URLError).map { "URLError \($0.code.rawValue)" } ?? "network error")
        }
    }

    /// Table de C05 §2.6.
    static func result(status: Int, retryAfter: String?, body: Data) -> TransportResult {
        switch status {
        case 200..<300:
            let counts = try? JSONDecoder().decode(IngestResponse.self, from: body)
            return .accepted(accepted: counts?.accepted ?? 0, rejected: counts?.rejected ?? 0)
        case 429:
            let seconds = retryAfter.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(retryAfter: seconds.map { max(0, $0) })
        case 401, 403:
            return .unauthorized(status: status)
        case 400..<500:
            let problem = try? JSONDecoder().decode(Problem.self, from: body)
            return .rejected(status: status, detail: problem?.detail)
        default:
            return .retryable(reason: "HTTP \(status)")
        }
    }

    private struct IngestResponse: Decodable {
        var accepted: Int
        var rejected: Int
    }

    /// `application/problem+json` (RFC 9457), seul `detail` est utile au log.
    private struct Problem: Decodable {
        var detail: String?
    }
}
