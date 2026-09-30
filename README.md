# PlatformAnalytics

SDK analytics **anonyme** pour apps SwiftUI, qui envoie des événements à l'ingestion Baptcave
(`POST /v1/ingest/events`). Zéro dépendance, jamais bloquant, jamais de crash, aucune donnée personnelle.

- iOS / iPadOS 17.4, macOS 14.4, visionOS 1.1 · Swift 6 (concurrence stricte) · < 2 000 lignes
- Pas d'IDFA, pas d'IDFV, pas de nom d'appareil, pas d'identification utilisateur : un UUID par appareil
- Queue sur disque, envoi par batches, retry avec backoff, opt-out persistant
- Contrat : `platform-contracts/contracts/05-sdk-swift.md`

## Intégration en 10 lignes

Ajouter le package au target de l'app (`https://github.com/baptisteftr/platform-analytics-swift`,
`from: "1.0.0"`), puis :

```swift
import PlatformAnalytics
import SwiftUI

@main struct MyApp: App {
    init() { Analytics.configure(ingestKey: "ik_live_…") }  // une fois, au lancement
    var body: some Scene { WindowGroup { SettingsView() } }
}
struct SettingsView: View {
    var body: some View {
        Button("Passer Pro") { Analytics.track("upgrade_tapped", props: ["plan": "pro_yearly"]) }
            .analyticsScreen("Settings")  // $screen à l'apparition
    }
}
```

Les sessions (`$session_start`, `$session_end`) et les fins anormales (`$crash`) sont suivies
automatiquement : rien à brancher, pas de `scenePhase` à relayer.

## API

```swift
Analytics.configure(ingestKey:endpoint:options:)   // endpoint par défaut compilé ; options toutes avec défaut
Analytics.track("onboarding_step", props: ["step": 3, "skipped": false])
Analytics.screen("Settings")                        // sans vue : navigation programmatique, deep link
view.analyticsScreen("Settings")                   // dédoublonné : même nom deux fois de suite en < 1 s = 1
Analytics.flush()                                   // force un envoi (asynchrone)
Analytics.optOut = true                             // stoppe tout, purge la queue, persiste le choix
Analytics.resetDeviceID()                           // nouvel identifiant anonyme (« oublie-moi »)
Analytics.deviceID                                  // à afficher dans un écran « Confidentialité »
Analytics.isConfigured
```

`Analytics.Options` : `flushInterval` (30 s), `flushThreshold` (30 événements), `maxQueuedEvents`
(5 000, au-delà les plus anciens sont supprimés), `trackScreensAutomatically` (réservé, non implémenté en
1.x), `logLevel` (`.off`, `.error`, `.warning` par défaut, `.info`, `.debug` ; `os.Logger`, subsystem
`com.platform.analytics`).

Tous les appels sont synchrones, non bloquants et ne lèvent jamais. Un `track` avant `configure` est gardé
en mémoire (100 au plus) puis envoyé.

## Règles de validation (appliquées localement, identiques au serveur)

| Règle | Si violée |
|---|---|
| nom `^[a-z0-9_]{1,64}$` (`$…` réservé au SDK, sauf `$crash` pour relayer MetricKit) | événement droppé |
| ≤ 20 props, clés `^[a-z0-9_]{1,32}$`, valeurs `String`/`Int`/`Double`/`Bool` | props en trop ou invalides droppées |
| chaînes ≤ 256 caractères | tronquées |
| valeur contenant un email, un numéro E.164, une IPv4 ou une IPv6 | prop droppée (« possible PII ») |
| props sérialisées ≤ 4 Ko | événement gardé sans props |

## Déclarations App Privacy (App Store Connect)

Le package embarque son `PrivacyInfo.xcprivacy` (aucun tracking, aucun domaine de tracking, API
`UserDefaults` raison `CA92.1`). Dans le formulaire App Privacy, déclarez :

| Type de donnée | Lié à l'utilisateur | Utilisé pour le tracking | Finalité |
|---|---|---|---|
| **Product Interaction** (Usage Data) | Non | Non | Analytics |
| **Crash Data** (Diagnostics) | Non | Non | Analytics |

Aucune réponse *App Tracking Transparency* n'est nécessaire : le SDK ne tracke pas.

## Ce qu'il faut savoir

- **Fins anormales** : `$crash` est une heuristique (session non terminée au lancement suivant, hors mise
  à jour de l'app ou de l'OS). Les kills mémoire et les force-quit comptent aussi : c'est un « taux de fin
  anormale », pas un crash reporter. Avec MetricKit, relayez vous-même `Analytics.track("$crash", props:)`.
- **Extensions et widgets** : `configure` y est un no-op silencieux en 1.x.
- **Réseau** : une requête par flush de 500 événements au plus ; en mode « économie de données », rien ne
  part et tout reste en queue. Pas d'envoi en `background URLSession` : ce qui n'est pas parti attend le
  prochain lancement.
- **Perte possible** : un événement en vol dans les ~10 ms qui suivent `track` est perdu si l'app crashe.
- **Clé révoquée** (`401`/`403`) : la queue est purgée et le SDK se désactive jusqu'au prochain lancement.

## Développement

```sh
swift test                                                            # macOS, sans réseau, < 1 s
swift build -Xswiftc -warnings-as-errors
xcodebuild -scheme PlatformAnalytics -destination 'generic/platform=iOS' build
xcodebuild -scheme PlatformAnalytics -destination 'generic/platform=visionOS' build
swift format lint --strict --recursive Package.swift Sources Tests
```

Architecture et décisions : `docs/history/`. Changements : `CHANGELOG.md`. Montées de version :
`MIGRATING.md`. Licence : MIT.
