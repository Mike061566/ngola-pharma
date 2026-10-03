# Scripts historiques (ne plus utiliser pour un nouveau déploiement)

`001_schema.sql` est le schéma d'origine. Il contient la récursion RLS sur `profils` et les
policies d'escalade de rôle corrigées plus tard : **ne pas l'appliquer**. Le schéma de référence
est `supabase/setup_consolide.sql` (correctifs inclus) ; la chaîne de migrations versionnées
dans `supabase/migrations/` le remplacera (PR 0a, étape baseline).

## Autres scripts de ce dossier

`setup_consolide.sql`, `setup_complet.sql`, `fix_rls_recursion.sql`, `fix_role_escalation.sql`,
`create_alertes_stock.sql`, `alter_alertes_add_phone.sql`, `set_verified_pharmacies.sql`,
`rollback_setup_consolide.sql` : historique du modèle « 1 client = 1 projet Supabase », abandonné au profit
d'une plateforme unique (un seul projet). Ils ne sont plus maintenus : ne pas les appliquer. Voir
`supabase/migrations/` (baseline) et `supabase/applied/` (correctifs déjà appliqués en production).
