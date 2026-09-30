# Événements : façade, validation, queue
Dernière mise à jour : 2026-09-30 (ticket #3)

## Rôle
Point d'entrée du SDK pour l'app hôte (`Analytics.configure/track/screen/flush`) : chaque appel est
validé selon les règles du serveur puis écrit dans une queue disque, sans jamais bloquer ni crasher l'app.

## Règles métier
- Nom d'événement : `^[a-z0-9_]{1,64}$`. Les noms `$…` sont réservés au SDK ; seul `$crash` est accepté
  depuis le code applicatif (relais MetricKit). Nom invalide → événement droppé, log `warning`. (#1)
- Props : clé `^[a-z0-9_]{1,32}$` sinon droppée ; `double` non fini (NaN, ±∞) droppé ; chaîne tronquée à
  256 caractères ; au-delà de 20 props, on garde les 20 premières clés **par ordre alphabétique** ; props
  sérialisées > 4 096 octets → toutes droppées, événement conservé. (#1)
- PII : une chaîne qui **contient** un email, un numéro E.164 (`+` puis 7 à 15 chiffres, espaces/points/
  tirets tolérés), une IPv4 ou une IPv6 (candidat à ≥ 2 « : » confirmé par `inet_pton`) est droppée avec
  un log `warning` qui ne cite que la clé. Test fait sur la valeur complète, avant troncature. (#1)
- `screen(name)` → `$screen` avec `props.name` = nom (espaces retirés). Nom vide ou PII → droppé. Une prop
  `name` fournie par l'appelant est écrasée ; les autres props suivent les règles communes (19 au plus). (#1)
- Avant `configure` : jusqu'à 100 `track`/`screen` gardés en mémoire (au-delà droppés, log `warning`),
  mis en queue au `configure`. `flush` avant `configure` est ignoré. (#1)
- `configure` avec une clé vide → SDK désactivé (log `error`) ; second `configure` → ignoré (log `warning`). (#1)
- Queue : au-delà de `maxQueuedEvents`, les plus anciens sont supprimés (FIFO), nombre loggé. (#1)
- Options hors bornes ramenées : `flushInterval` ≥ 1 s (NaN → 30), `flushThreshold` ≥ 1, `maxQueuedEvents` ≥ 1. (#1)

## Décisions
- 2026-09-30 #1 — Ordre garanti par une `AsyncStream` consommée par une seule tâche détachée : un
  `Task { await core… }` par appel ne garantirait pas l'ordre FIFO exigé par C05 §5.
- 2026-09-30 #1 — L'horodatage `occurred_at` est pris dans la façade au moment de l'appel, pas au
  traitement dans l'actor.
- 2026-09-30 #3 — `ack(_ peek:)` par position absolue remplace `ack(lignes)` (#1) : sûr quand la tête bouge pendant un envoi.
- 2026-09-30 #1 — `head` séparé (`queue.head` = nombre de lignes mortes en tête) plutôt que réécrire le
  fichier à chaque envoi : `queue.jsonl` reste append-only, compaction seulement au-delà de 50 % de lignes mortes.
- 2026-09-30 #1 — Type public `Analytics.LogLevel` (`off/error/warning/info/debug`) : C05 §1 utilise
  `logLevel: .warning` sans nommer le type ; nom à ratifier dans le contrat.
- 2026-09-30 #1 — Recherche PII « contient » plutôt que « correspond exactement » : plus protecteur, au prix
  de faux positifs (ex. une chaîne contenant « 1.2.3.4 »). Le backend (ticket ingest) doit reprendre les
  mêmes expressions pour rester « identique ».
- 2026-09-30 #1 — Endpoint par défaut compilé `https://api.baptcave.example/v1` : le domaine est encore un
  placeholder (PLAN §0), à remplacer avant la 1.0 publique.

## Points techniques
- `EventQueue` n'est pas thread-safe : elle n'est touchée que depuis l'actor `AnalyticsCore`.
- Au chargement, une dernière ligne sans `\n` (écriture interrompue) est retirée ; une ligne illisible est
  sautée par `peek` mais comptée dans `lineCount`, pour être acquittée avec le batch.
- `fsync` (`FileHandle.synchronize`) toutes les 10 lignes et à chaque `flush`.
- Compaction non atomique entre `queue.jsonl` et `queue.head` (deux écritures `.atomic` successives) : un
  crash dans cette fenêtre peut perdre ou renvoyer quelques événements, acceptable (C05 §5).
- Les dates sont sérialisées en RFC 3339 UTC avec millisecondes (troncature, pas arrondi) ; la ligne de
  queue a exactement la forme d'un élément `events[]` de C02 §3.1 (clés triées).
- Répertoire `Application Support/com.platform.analytics/` exclu du backup (`isExcludedFromBackup`).

## Tickets
- #1 — Package, façade, validation, queue — 2026-09-30
- #3 — acquittement par position absolue (`Peek.end`), pré-filtres PII — 2026-09-30
