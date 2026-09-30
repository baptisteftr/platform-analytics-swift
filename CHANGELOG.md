# Changelog

Format : [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/). Versionnage : [SemVer](https://semver.org/lang/fr/)
strict, l'API publique est gelée depuis la 1.0 (un changement cassant = 2.0).

## [1.0.0] — 2026-09-30

Première version publique (contrats C02 v1.7, C05 v1.2). À ne publier qu'une fois l'endpoint par défaut
compilé sur le domaine de production (C05 §6).

### Ajouté
- `Analytics.configure(ingestKey:endpoint:options:)`, `track(_:props:)`, `screen(_:props:)`, `flush()`,
  `optOut`, `resetDeviceID()`, `deviceID`, `isConfigured`.
- `Analytics.Options` (`flushInterval`, `flushThreshold`, `maxQueuedEvents`, `trackScreensAutomatically`,
  `logLevel`) et `Analytics.LogLevel`.
- `PropValue` (chaîne, entier, décimal, booléen), constructible par littéral.
- Modificateur SwiftUI `.analyticsScreen(_:props:)`, dédoublonné à 1 s.
- Sessions automatiques (`$session_start` avec `first`, `$session_end` avec `duration_ms`, seuil de 30 s),
  détection heuristique des fins anormales (`$crash`).
- Validation locale identique au serveur, détection de PII (email, E.164, IPv4, IPv6) selon les règles
  exactes du contrat d'ingestion (C02 §3.1 v1.7).
- Queue persistante (`Application Support/com.platform.analytics/queue.jsonl`, sur macOS
  `Application Support/<bundle id>/com.platform.analytics/`, exclue du backup), batches ≤ 500 événements
  / 1 Mo, `Idempotency-Key` stable avec `sent_at` rafraîchi à chaque tentative, backoff exponentiel,
  respect de `Retry-After`, désactivation sur clé révoquée.
- `PrivacyInfo.xcprivacy`.
