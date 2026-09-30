# Envoi : batching, retry, opt-out
Dernière mise à jour : 2026-09-30 (ticket #3)

## Rôle
Vide la queue vers `POST /v1/ingest/events` par batches, sans jamais perdre un événement sur une erreur
passagère ni insister contre une clé révoquée, et respecte le choix de l'utilisateur de ne pas être mesuré.

## Règles métier
- Flush déclenché par : `flushThreshold` événements en attente, `flushInterval` écoulé avec ≥ 1 événement,
  passage en arrière-plan (après `$session_end`, sous `beginBackgroundTask`), `flush()`, retour du réseau. (#3)
- Un flush envoie des batches **séquentiels** jusqu'à vider la queue : ≤ 500 événements, les plus anciens
  d'abord, corps ≤ 1 Mo (on divise le nombre d'événements par deux tant que ça dépasse). (#3)
- Réponses (C05 §2.6) : `2xx` → acquitté (`rejected` > 0 loggé en `info`) ; `429` → aucun envoi avant
  `Retry-After` (défaut 60 s), même si le réseau revient ; `401`/`403` → queue purgée, SDK désactivé
  jusqu'au prochain lancement (plus aucun `track`, session ni envoi) ; autre `4xx` (`409`, `413`, `422`,
  `426`…) → batch droppé et on passe au suivant ; `5xx`/timeout/pas de réseau → batch conservé, backoff. (#3)
- Backoff : délai dans `[d/2, d]`, `d = min(5 s × 2^échecs, 10 min)` ; remis à zéro par un `2xx` ou un
  retour du réseau. Un retry est programmé à l'échéance. (#3)
- Retry : **même corps, octet pour octet, et même `Idempotency-Key`** jusqu'au `2xx` (ou jusqu'à un 4xx). (#3)
- `optOut = true` : persisté dans `UserDefaults` (`com.platform.analytics.optOut`), queue purgée, envoi en
  cours ignoré, marqueur de session supprimé, `track`/`screen`/cycle de vie ignorés, aucun réseau.
  `false` : nouvelle session. `configure` en opt-out ne crée ni session ni `$crash`. (#3)

## Décisions
- 2026-09-30 #3 — Corps du batch figé à sa création (dont `sent_at`) : C02 §1.4 répond `409` à une
  `Idempotency-Key` réutilisée avec un corps différent, ce qui droppait le batch. Conséquence : sur un
  retry, `sent_at` date de la première tentative et la correction d'horloge du serveur décale les
  événements du délai de retry. À trancher dans le contrat.
- 2026-09-30 #3 — La clé d'idempotence n'est pas persistée : après un relancement, un batch dont le premier
  envoi a peut-être abouti repart avec une nouvelle clé (doublon possible, C05 §5).
- 2026-09-30 #3 — L'envoi tourne dans une tâche de l'actor : `handle` rend la main tout de suite et les
  `track` continuent d'être écrits pendant une requête (réentrance de l'actor).
- 2026-09-30 #3 — Plafond de 1 Mo par corps ajouté : 500 événements à 4 Ko de props dépassent la limite
  serveur (C02 §2.6) et seraient droppés en `413`.
- 2026-09-30 #3 — `Reachability` (framework Network) et `beginBackgroundTask` (UIKit) sont exigés par C05
  §2.5 alors que C05 §0.1 ne liste que Foundation, Security, SwiftUI et les notifications UIKit/AppKit.

## Points techniques
- Un `ack` porte une position absolue (`Peek.end`) : si la tête de la queue a bougé pendant l'envoi
  (plafond atteint, purge), l'acquittement ne retire pas d'autres événements que ceux envoyés.
- Toute purge incrémente une génération : un résultat d'envoi reçu après une purge est ignoré.
- `URLSession` éphémère : timeout 15 s, `waitsForConnectivity = false`, pas de réseau contraint (mode
  économie de données → erreur réseau → backoff, la queue garde tout), pas de cookie ni de cache.
- `BackgroundTask` : démarré dans le handler de notification (main thread), terminé quand le flush de
  `$session_end` rend la main ou à l'expiration système. Sans objet sur macOS.
- PII : pré-filtre par caractère (`@`, `+`, `.`, deux `:`) et lookbehind sur les regex, sinon coût
  quadratique sur les longues chaînes (4 s pour 400 événements avant correction).

## Tickets
- #3 — Transport, batching, retry, opt-out — 2026-09-30
