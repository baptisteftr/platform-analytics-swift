# Migrer entre versions de PlatformAnalytics

L'API publique suit SemVer strictement : une version mineure ou corrective ne casse jamais le code
appelant ; un changement cassant ne peut arriver qu'avec une version majeure, documentée ici avec les
étapes de migration.

## Vers 1.0.0

Première version publique : rien à migrer.

Pour démarrer :

1. Ajouter le package (`from: "1.0.0"`) au target de l'app, pas aux extensions ni aux widgets.
2. Appeler `Analytics.configure(ingestKey:)` une fois dans `App.init`.
3. Poser `.analyticsScreen("<Écran>")` sur chaque écran à mesurer.
4. Remplir le formulaire App Privacy (voir le README).
