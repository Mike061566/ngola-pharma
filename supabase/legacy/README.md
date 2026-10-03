# Scripts historiques (ne plus utiliser pour un nouveau déploiement)

`001_schema.sql` est le schéma d'origine. Il contient la récursion RLS sur `profils` et les
policies d'escalade de rôle corrigées plus tard : **ne pas l'appliquer**. Le schéma de référence
est `supabase/setup_consolide.sql` (correctifs inclus) ; la chaîne de migrations versionnées
dans `supabase/migrations/` le remplacera (PR 0a, étape baseline).
