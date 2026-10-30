# Retours arrière

Scripts à exécuter **à la main**, jamais par la CLI (ils ne sont volontairement pas dans `supabase/migrations/`).

| Migration | Retour arrière |
|---|---|
| `20261003100000_fusion_doublons_medicaments.sql` | `20261003100000_fusion_doublons_medicaments_rollback.sql` |

## Fusion des fiches `medicaments` en double — ordre d'exécution en production

**La fusion (et son retour arrière) s'exécute AVANT les migrations de la PR 1** (`20261004000000` et suivantes).
La migration refuse de démarrer si une clé étrangère vers `medicaments` qu'elle ne gère pas existe déjà
(`alias_medicaments`, `alertes_routage`...). Le retour arrière restaure l'état d'avant la PR 1 : il ne connaît pas
les colonnes ajoutées ensuite (`est_demo`, `restreint`, `statut_stock`...), donc **ne pas l'utiliser une fois les
migrations de la PR 1 appliquées**.

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

## Ce que couvre (et ne couvre pas) l'index `uq_medicaments_nom_dosage`

- **Couvre** : deux fiches de même nom (minuscules, espaces autour ignorés) et de même dosage (espaces ignorés, vide = NULL)
  sont refusées. C'est le cas des 20 paires de la production et de tout rechargement futur d'un seed.
- **Ne couvre pas** : les variantes de nom (accents, espaces ou ponctuation à l'intérieur du nom, abréviations, marque contre
  DCI). Ces doublons-là ne sont détectés que par la clé produit (DCI + marque + dosage + forme) du diagnostic, de la fusion
  et du formulaire de l'Espace Pro.
- **Effet de bord** : l'index ignore la forme et la marque ; deux produits de même nom et même dosage mais de forme différente
  ne peuvent pas coexister.
