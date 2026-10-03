# Retours arrière

Scripts à exécuter **à la main**, jamais par la CLI (ils ne sont volontairement pas dans `supabase/migrations/`).

| Migration | Retour arrière |
|---|---|
| `20261003100000_fusion_doublons_medicaments.sql` | `20261003100000_fusion_doublons_medicaments_rollback.sql` |

## Fusion des fiches `medicaments` en double — ordre d'exécution en production

1. `supabase/diagnostics/fusion_doublons_dry_run.sql` (lecture seule) : relire le résumé et les conflits ;
   la section `COLLISION_INDEX` doit être **vide**.
2. `supabase/migrations/20261003100000_fusion_doublons_medicaments.sql` : une transaction, contrôle final,
   sauvegarde dans le schéma `sauvegarde_fusion`. Une anomalie annule tout.
3. `supabase/diagnostics/fusion_doublons_verification.sql` (lecture seule) : toutes les lignes `ok = true`.
4. En cas de problème constaté : le script de retour arrière (restaure l'état d'avant la fusion ; les
   modifications faites depuis sur les lignes de stock concernées sont perdues).
5. Une fois la fusion validée définitivement : purger la sauvegarde à la main
   (`DROP SCHEMA sauvegarde_fusion CASCADE;`). Tant qu'elle existe, la migration refuse de se relancer.

Si la CLI Supabase gère un jour l'historique de ce projet : `supabase migration repair --status applied 20261003100000`.
