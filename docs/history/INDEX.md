# Historique du projet

Une fiche par bloc fonctionnel. Lire la fiche d'un bloc avant de le modifier ; la mettre à jour dans le même ticket.

| Fiche | Rôle | Dernière mise à jour |
|---|---|---|
| [events.md](events.md) | Façade `Analytics`, validation locale (règles serveur + PII), queue disque, table PII de référence | 2026-09-30 (#5) |
| [sessions.md](sessions.md) | `device_id` Keychain, sessions `$session_*`, marqueur `session.active` → `$crash`, cycle de vie | 2026-09-30 (#5) |
| [transport.md](transport.md) | Flush, batches ≤ 500 / 1 Mo, table des réponses, backoff, idempotence, opt-out | 2026-09-30 (#5) |
| [swiftui.md](swiftui.md) | `.analyticsScreen` et son dédoublonnage 1 s, README, CHANGELOG, CI, release | 2026-09-30 (#5) |
