# Baseline du schéma

- `../migrations/20261003000000_baseline.sql` : état de référence de la base au 2026-10-03
  (structure uniquement, aucune donnée). Les évolutions sont de **nouvelles migrations** ; on ne
  modifie jamais une migration déjà publiée.
- `inventory.expected.txt` : inventaire attendu du schéma `public`, généré par
  `scripts/build-baseline-inventory.sh` sur une base jetable. La CI vérifie qu'il correspond aux
  migrations (job « Base de données »).

## Production

La production contient déjà la baseline (elle est issue de `setup_consolide.sql` + les correctifs de
`supabase/applied/`). **Ne jamais exécuter la baseline en production.** Pour vérifier l'écart :

1. Exécuter `supabase/diagnostics/schema_inventory.sql` dans le SQL Editor de la prod (lecture seule),
   exporter la colonne `ligne` en CSV.
2. `node scripts/compare-schema.js prod_inventory.csv` : liste manquant / différent / en trop.
   Les contraintes `NOT VALID` (lignes existantes non validées, ex. `alertes_stock`) ne sont pas un écart :
   elles sont signalées à part, section « Informations ».
   L'empreinte des fonctions ignore espaces et commentaires `--`.

`inventory.expected.txt` décrit le schéma APRÈS toutes les migrations du dépôt. Tant que les migrations de la PR 1
(`20261004…`) ne sont pas appliquées en prod, comparer plutôt à l'inventaire de la baseline seule :
`git show <commit-avant-PR1>:supabase/baseline/inventory.expected.txt > /tmp/attendu.txt` puis
`node scripts/compare-schema.js prod_inventory.csv /tmp/attendu.txt`. Après les migrations de la PR 1, utiliser le fichier courant.

Les migrations suivantes (`2026…_*.sql`) sont à exécuter en prod **à la main, après relecture**, dans
l'ordre. La fusion des fiches `medicaments` en double (`20261003100000`) a sa procédure et son retour arrière
dans `supabase/rollback/README.md`.

### Suivi de version (facultatif)

Si vous utilisez un jour `supabase db push` contre la prod, déclarez d'abord la baseline comme déjà
appliquée, sinon la CLI tentera de la rejouer :

```sql
-- À n'exécuter que si la CLI Supabase doit gérer l'historique des migrations de ce projet.
insert into supabase_migrations.schema_migrations (version, name)
values ('20261003000000', 'baseline')
on conflict do nothing;
```

(ou `supabase migration repair --status applied 20261003000000`). Tant que vous exécutez les migrations
à la main dans le SQL Editor, cette étape est inutile.
