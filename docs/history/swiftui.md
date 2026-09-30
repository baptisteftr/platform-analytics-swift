# Intégration SwiftUI et distribution
Dernière mise à jour : 2026-09-30 (ticket #5)

## Rôle
Le modificateur `.analyticsScreen(_:)` permet au développeur de mesurer un écran en une ligne ; le README,
le `CHANGELOG`, le `MIGRATING` et la CI font du package une dépendance publique utilisable telle quelle.

## Règles métier
- `.analyticsScreen(name, props:)` émet `$screen` à chaque `onAppear` ; un même nom émis deux fois **de
  suite** en moins d'1 s ne compte qu'une fois. La fenêtre part de la dernière émission comptée ;
  `A, B, A` en 0,2 s compte trois écrans ; une horloge qui recule n'avale rien. (#4)
- Le dédoublonnage ne s'applique qu'au modificateur : `Analytics.screen(_:)` émet toujours. (#4)
- `trackScreensAutomatically = true` : log `warning` « not implemented in 1.x », aucun effet (#1, confirmé #4).
- Version du SDK dans chaque batch : `sdk = {name: "swift", version: "1.0.0"}` ; à incrémenter à chaque tag. (#4)

## Décisions
- 2026-09-30 #4 — Dédoublonnage global (dernier écran émis par le modificateur) plutôt que par instance de
  vue : un rafraîchissement recrée la vue et son état, un état par instance ne dédoublonnerait rien.
  C05 §1 dit « dédupliqué tant que la vue reste visible », §3.2 et le ticket fixent la règle « < 1 s » :
  c'est elle qui est implémentée.
- 2026-09-30 #4 — Licence MIT (C05 §6), titulaire « Baptcave » à confirmer par l'humain.
- 2026-09-30 #4 — Release = tag + `gh release create --generate-notes` dans la CI, sur tag uniquement.

## Points techniques
- Taille : 1 726 lignes de Swift après #5 (1 696 en #4) ; objet Release arm64 iOS ≈ 279 Ko (segments TEXT + DATA, sans
  instrumentation de couverture ; avec la couverture activée par le scheme généré, ≈ 341 Ko).
- `PrivacyInfo.xcprivacy` copié dans `PlatformAnalytics_PlatformAnalytics.bundle` (vérifié sur le build
  iOS). Pas de `NSPrivacyAccessedAPICategoryFileTimestamp` : le SDK ne lit aucune date de fichier.
- CI (`.github/workflows/ci.yml`) : lint `swift format --strict`, build macOS en `-warnings-as-errors`,
  `swift test`, plafond de 2 000 lignes, builds iOS et visionOS, release sur tag. Non exécutée localement
  (pas de remote) ; les mêmes commandes passent en local.

## Tickets
- #4 — SwiftUI, doc, release 1.0 — 2026-09-30
- #5 — tag `1.0.0` local reposé après la mise en conformité C05 v1.2 — 2026-09-30
