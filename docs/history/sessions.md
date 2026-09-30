# Identité, sessions, fins anormales
Dernière mise à jour : 2026-09-30 (ticket #5)

## Rôle
Donne à chaque appareil un identifiant anonyme stable et découpe l'usage en sessions (`$session_start`,
`$session_end`), sans rien demander au développeur. Signale au lancement suivant une session qui ne s'est
pas terminée proprement (`$crash`, « taux de fin anormale »).

## Règles métier
- `device_id` : UUID v4 en Keychain (`kSecClassGenericPassword`, service `com.platform.analytics`, account
  `device_id`, `AfterFirstUnlockThisDeviceOnly`, non synchronisé). Une valeur stockée qui n'est pas un UUID
  est remplacée. Si l'écriture échoue, l'identifiant vit en mémoire le temps du lancement (log `error`). (#2)
- `$session_start` au `configure`, puis au retour au premier plan après **plus de** 30 s en arrière-plan
  (30 s pile = reprise). `first = true` seulement si le `device_id` vient d'être créé (premier lancement ou
  reset). (#2)
- `$session_end` à chaque passage en arrière-plan, `duration_ms` = temps **cumulé au premier plan** de la
  session. Après une reprise (< 30 s), la même session émet donc un second `$session_end`, avec la durée
  cumulée : côté serveur, la durée d'une session est celle de son **dernier** `$session_end` (règle
  inscrite dans C05 v1.2 §2.2, #5). (#2)
- Marqueur `session.active` (JSON : session, versions app/build/OS) écrit au démarrage et à la reprise,
  supprimé au passage en arrière-plan. Resté présent au lancement suivant → `$crash`
  `{signal: "unknown", top_frame: ""}` rattaché à la session interrompue, avant le nouveau `$session_start` ;
  sauf si la version de l'app, le build ou l'OS a changé (mise à jour), auquel cas rien n'est émis. (#2)
- `resetDeviceID()` : nouvel identifiant visible immédiatement par `deviceID` ; les événements pas encore
  envoyés sont purgés ; nouvelle session `first = true` tout de suite si l'app est active, sinon au prochain
  retour au premier plan. (#2)
- `configure` est un no-op silencieux si le bundle principal est un `.appex`. (#2)

## Décisions
- 2026-09-30 #2 — Purge de la queue au reset : envoyer les anciens événements sous le nouvel identifiant
  relierait les deux, ce que « oublie-moi » interdit. Alternative écartée : stocker le `device_id` par événement.
- 2026-09-30 #2 — `willTerminate` (UIKit et AppKit) est traité comme un passage en arrière-plan, en plus des
  notifications listées par C05 §2.2 : un Cmd-Q sur macOS ne doit pas compter comme fin anormale.
- 2026-09-30 #2 — Les notifications de cycle de vie passent par la même file de commandes que les appels
  publics, horodatées à la réception : l'ordre `track` / `$session_end` est conservé.
- 2026-09-30 #2 — `Batch.Device` (bloc `device` de C02 §3.1) est créé dès ce ticket : ses versions servent
  au marqueur de crash. Le reste de `Batch` arrive avec le transport (#3).
- 2026-09-30 #2 — `deviceID` (getter synchrone) peut lire le Keychain s'il est appelé avant que l'actor ne
  l'ait chargé : seule exception à « aucune I/O synchrone », inévitable avec un getter `String`. Admise
  par C05 v1.2 §0.4, comme la lecture `UserDefaults` d'`optOut` (#5).
- 2026-09-30 #5 — La purge de la queue au reset est inscrite dans C05 v1.2 §2.7.

## Points techniques
- L'actor garde sa propre copie de `Batch.Device` (avec l'id) : elle ne change qu'au traitement de
  `resetDeviceID`, dans l'ordre des commandes, même si la façade a déjà fait `rotate()` (mémoire seule).
- `DeviceIdentity.load()` consomme l'indicateur « créé » ; `current` ne le consomme pas (un getter appelé
  avant `configure` ne fait pas perdre `first = true`).
- Modèle : `SIMULATOR_MODEL_IDENTIFIER` sur simulateur, sinon `sysctl hw.machine` (iOS, visionOS) ou
  `hw.model` (macOS). Locale réduite à `langue_RÉGION`.
- Keychain réel non testable en `swift test` ni dans un bundle de tests SPM sur simulateur
  (`errSecMissingEntitlement`, -34018, faute d'app hôte) : les tests passent par un stockage mémoire. Sur
  macOS, repli sur le trousseau classique si le trousseau « data protection » est refusé (app non signée).

## Tickets
- #2 — Identité, sessions, crash, cycle de vie — 2026-09-30
- #5 — contrat C05 v1.2 : règles ratifiées, marqueur sous `<bundle id>` sur macOS — 2026-09-30
