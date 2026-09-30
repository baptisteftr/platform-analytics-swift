# AGENTS.md — platform-analytics-swift

Package SPM public `PlatformAnalytics` : SDK analytics anonyme pour apps SwiftUI, intégré par les tenants dans leurs apps publiées. Contrat : `../platform-contracts/contracts/05-sdk-swift.md` (API publique, comportement, garanties) et 02 §2.6/§3.1 pour le format d'ingestion.

## Règles

- Zéro dépendance. Foundation, Security, SwiftUI, notifications UIKit/AppKit en interne uniquement.
- iOS 17.4, iPadOS 17.4, macOS 14.4, visionOS 1.1. Swift 6, `strict concurrency = complete`, zéro warning.
- Jamais de crash, jamais bloquant : tout part dans l'actor `AnalyticsCore`, toute erreur est absorbée et loggée.
- Aucune donnée personnelle : validation locale identique au serveur (C05 §2.4), regex PII compilées une fois.
- < 2 000 lignes, < 300 Ko compilé. `PrivacyInfo.xcprivacy` embarqué.
- Testable sans réseau : `Transport` est un protocole, `MockTransport` dans les tests, `swift test` sur macOS < 10 s.
- API publique gelée à la 1.0 : SemVer strict, `CHANGELOG.md` et `MIGRATING.md` obligatoires.
- Layout : celui du C05 §4, un fichier par type.

## Ce que tu ne fais pas

- Ajouter `identify`, des propriétés persistantes, du suivi automatique d'écran, une dépendance, un handler de signal.
- Rendre un appel public asynchrone ou throwing.
