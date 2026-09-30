# Événements : façade, validation, queue
Dernière mise à jour : 2026-09-30 (ticket #5)

## Rôle
Point d'entrée du SDK pour l'app hôte (`Analytics.configure/track/screen/flush`) : chaque appel est
validé selon les règles du serveur puis écrit dans une queue disque, sans jamais bloquer ni crasher l'app.

## Règles métier
- Nom d'événement : `^[a-z0-9_]{1,64}$`. Les noms `$…` sont réservés au SDK ; seul `$crash` est accepté
  depuis le code applicatif (relais MetricKit). Nom invalide → événement droppé, log `warning`. (#1)
- Props : clé `^[a-z0-9_]{1,32}$` sinon droppée ; `double` non fini (NaN, ±∞) droppé ; chaîne tronquée à
  256 caractères ; au-delà de 20 props, on garde les 20 premières clés **par ordre alphabétique** ; props
  sérialisées > 4 096 octets → toutes droppées, événement conservé. (#1)
- PII : une chaîne qui **contient** un email, un numéro E.164, une IPv4 ou une IPv6 selon les règles
  exactes de C02 §3.1 (v1.7) est droppée, avec un log `warning` qui ne cite que la clé (`possible PII:
  prop '<clé>' dropped`). Test sur la valeur complète, avant troncature. Cas de référence ci-dessous. (#1, #5)
  - IPv6 : c'est la **suite maximale** de `[0-9A-Fa-f:.]` (≥ 2 « : ») qui doit être valide pour
    `inet_pton`, telle quelle : un « . » final l'invalide, et `::` est une IPv6. (#5, remplace le
    nettoyage des « . » et l'exigence d'un chiffre hexa de #1)
  - IPv4 : un octet s'écrit sans zéro non significatif (`0`–`255`, pas `01` ni `001`) : lecture de
    « octets décimaux 0-255 » de C02 §3.1, alignée sur `inet_pton` et `netip.ParseAddr`. (#5)
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
  `logLevel: .warning` sans nommer le type. Ratifié par C05 v1.2 (#5), qui le déclare `Sendable`
  seulement : les conformances `Int`/`Comparable`/`CaseIterable` et `Equatable` sur `Options` ont été
  retirées avant la 1.0 (en ajouter plus tard ne casse rien, en retirer si). (#5)
- 2026-09-30 #1 — Recherche PII « contient » plutôt que « correspond exactement » : plus protecteur, au prix
  de faux positifs (ex. une chaîne contenant « 1.2.3.4 »). Règles fixées par C02 §3.1 v1.7 (#5) ; le
  backend doit donner le même résultat sur la table de référence.
- 2026-09-30 #1 — Endpoint par défaut compilé `https://api.baptcave.example/v1` : le domaine est encore un
  placeholder (PLAN §0). C05 v1.2 §6 : pas de publication tant que c'est le cas (#5).
- 2026-09-30 #5 — Sur macOS, sans bundle id (outil en ligne de commande, `swift test`), le nom du process
  remplace le bundle id dans le chemin de la queue.

## Points techniques
- `EventQueue` n'est pas thread-safe : elle n'est touchée que depuis l'actor `AnalyticsCore`.
- Au chargement, une dernière ligne sans `\n` (écriture interrompue) est retirée ; une ligne illisible est
  sautée par `peek` mais comptée dans `lineCount`, pour être acquittée avec le batch.
- `fsync` (`FileHandle.synchronize`) toutes les 10 lignes et à chaque `flush`.
- Compaction non atomique entre `queue.jsonl` et `queue.head` (deux écritures `.atomic` successives) : un
  crash dans cette fenêtre peut perdre ou renvoyer quelques événements, acceptable (C05 §5).
- Les dates sont sérialisées en RFC 3339 UTC avec millisecondes (troncature, pas arrondi) ; la ligne de
  queue a exactement la forme d'un élément `events[]` de C02 §3.1 (clés triées).
- Répertoire `Application Support/com.platform.analytics/` (macOS : `Application Support/<bundle id>/
  com.platform.analytics/`, C05 v1.2 §2.5) exclu du backup (`isExcludedFromBackup`) ; le marqueur
  `session.active` y vit aussi. (#5)
- PII en NSRegularExpression : les bornes « non précédé de » du contrat sont des lookbehind ; « non suivi
  de » des lookahead. En RE2 (Go), sans lookaround, il faut les écrire à la main (`(?:^|[^…])` autour du
  motif) : le résultat booléen est le même. Pour l'email, la borne ne change pas le résultat.

## Table de référence PII (C02 §3.1)
Même table dans `Tests/PlatformAnalyticsTests/PIIReferenceTests.swift` (exécutée par `swift test`). Le backend
doit donner le même résultat sur chaque ligne.

| Règle | Entrée | PII | Pourquoi |
|---|---|---|---|
| email | `jane@example.com` | oui |  |
| email | `contact: JANE.DOE+tag@sub.example.co.uk merci` | oui | contenu dans une phrase |
| email | `a@b.co` | oui | TLD de 2 lettres |
| email | `prénom.nom@exemple.fr` | oui | la partie locale commence après « é » |
| email | `user_1@mail-server.io` | oui |  |
| email | `a@b.c` | non | TLD d'une lettre |
| email | `a@b` | non | pas de TLD |
| email | `jane@example` | non | pas de point dans le domaine |
| email | `@example.com` | non | partie locale vide |
| email | `jane@@example.com` | non | double @ |
| email | `version 1.2@3.4` | non | TLD numérique |
| e164 | `+33612345678` | oui |  |
| e164 | `+33 6 12 34 56 78` | oui | espaces |
| e164 | `+1-415-555-2671` | oui | tirets |
| e164 | `+1.415.555.2671` | oui | points |
| e164 | `tel:+33612345678;ext` | oui | contenu |
| e164 | `+1234567` | oui | minimum : 1 + 6 chiffres |
| e164 | `+123456789012345` | oui | maximum : 15 chiffres |
| e164 | `+1234567a` | oui | suivi d'une lettre |
| e164 | `+123456` | non | 6 chiffres seulement |
| e164 | `+1234567890123456` | non | 16 chiffres : suivi d'un chiffre |
| e164 | `+0612345678` | non | premier chiffre 0 |
| e164 | `0612345678` | non | pas de + |
| e164 | `+33  612345678` | non | deux séparateurs de suite |
| e164 | `+33 (0)6 12 34 56 78` | non | parenthèses |
| ipv4 | `192.168.1.10` | oui |  |
| ipv4 | `from 8.8.8.8 today` | oui | contenu |
| ipv4 | `0.0.0.0` | oui |  |
| ipv4 | `255.255.255.255` | oui |  |
| ipv4 | `10.0.0.1:8080` | oui | suivi de « : » |
| ipv4 | `1.2.3.4.` | oui | suivi d'un point sans chiffre |
| ipv4 | `v1.2.3.4` | oui | précédé d'une lettre |
| ipv4 | `1.2.3.4a` | oui | suivi d'une lettre |
| ipv4 | `256.1.1.1` | non | octet > 255 |
| ipv4 | `1.2.3` | non | trois octets |
| ipv4 | `2.1.0` | non | numéro de version |
| ipv4 | `1.2.3.4.5` | non | suivi de « .chiffre » |
| ipv4 | `01.2.3.4` | non | zéro non significatif |
| ipv4 | `192.168.01.1` | non | zéro non significatif |
| ipv4 | `1.2.3.04` | non | zéro non significatif |
| ipv6 | `2001:0db8:85a3:0000:0000:8a2e:0370:7334` | oui | forme complète |
| ipv6 | `2001:db8::1` | oui | forme compressée |
| ipv6 | `::1` | oui |  |
| ipv6 | `::` | oui | adresse non spécifiée, valide |
| ipv6 | `addr fe80::1%en0` | oui | la suite s'arrête au % |
| ipv6 | `[2001:db8::1]:443` | oui | la suite s'arrête au ] |
| ipv6 | `12:34:56:78:9a:bc:de:f0` | oui | 8 groupes : IPv6 valide (même si c'est une MAC) |
| ipv6 | `::ffff:10.0.0.1` | oui | IPv4 mappée (aussi détectée comme IPv4) |
| ipv6 | `2001:db8::1.` | non | la suite maximale inclut le « . » final : invalide |
| ipv6 | `12:30:45` | non | heure |
| ipv6 | `a:b` | non | un seul « : » |
| ipv6 | `2001:db8:::1` | non | « ::: » invalide |
| ipv6 | `1:2:3:4:5:6:7:8:9` | non | 9 groupes |
| ipv6 | `12345::1` | non | groupe de 5 chiffres hexa |
| ipv6 | `ab:cd:ef:01:23:45` | non | 6 groupes sans « :: » (MAC 48 bits) |
| aucune | `pro_yearly` | non |  |
| aucune | `Onboarding/Step2` | non |  |
| aucune | `iPhone16,1` | non |  |
| aucune | `2026-09-30T14:03:00Z` | non | horodatage |
| aucune | `v2.1.0 (214)` | non |  |
| aucune | `Écran d'accueil` | non |  |

## Tickets
- #1 — Package, façade, validation, queue — 2026-09-30
- #3 — acquittement par position absolue (`Peek.end`), pré-filtres PII — 2026-09-30
- #5 — mise en conformité C02 v1.7 / C05 v1.2 : règles PII exactes, chemin macOS, `LogLevel` — 2026-09-30
