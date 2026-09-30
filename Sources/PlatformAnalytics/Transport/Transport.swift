import Foundation

/// Envoi d'un batch à `POST /v1/ingest/events`. Injecté : `URLSessionTransport` en production,
/// un transport simulé dans les tests.
protocol Transport: Sendable {
    func send(_ batch: Batch) async -> TransportResult
}

/// Issue d'un envoi, déjà traduite selon la table de C05 §2.6.
enum TransportResult: Sendable, Equatable {
    /// `202` : batch reçu (`rejected` = événements refusés par le serveur, horloge ou validation).
    case accepted(accepted: Int, rejected: Int)
    /// `429` : attendre `Retry-After` secondes (défaut 60 s) avant tout nouvel envoi.
    case rateLimited(retryAfter: TimeInterval?)
    /// `401` / `403` : clé révoquée ou ingestion désactivée ; ne jamais réessayer avec cette clé.
    case unauthorized(status: Int)
    /// Autre `4xx` (dont `413`, `422`, `426`) : le batch ne repartira jamais, il est droppé.
    case rejected(status: Int, detail: String?)
    /// `5xx`, timeout, pas de réseau : garder le batch et réessayer plus tard.
    case retryable(reason: String)
}
