-- ============================================================
-- N'Gola Pharma — Inventaire du schéma `public` (LECTURE SEULE)
--
-- À exécuter dans le SQL Editor Supabase de PRODUCTION. Un seul SELECT : il ne
-- modifie rien (le seul calcul « écriture-like » est un count(*) par table, voir
-- section `info`). Il ne lit aucune donnée métier : pas de contenu de lignes, pas
-- d'emails, pas de téléphones — uniquement la structure et des comptes.
--
-- Les empreintes de fonctions ignorent espaces et commentaires `--`.
-- Résultat : une colonne `ligne`, format `type|clé|valeur`, triée. Exportez-la en CSV
-- (ou copiez la colonne) dans un fichier, puis :
--
--     node scripts/compare-schema.js prod_inventory.csv
--
-- Le script la compare à supabase/baseline/inventory.expected.txt (schéma de
-- référence = migrations de supabase/migrations/, baseline + suivantes) et
-- liste : manquant en prod / en trop en prod / différent.
-- Les objets installés par une extension (PostGIS : spatial_ref_sys, etc.) sont exclus.
-- ============================================================
WITH
tables AS (
    SELECT c.oid, c.relname, c.relkind, c.relrowsecurity, c.relforcerowsecurity, c.relacl
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'v', 'm', 'p')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')
),
lignes AS (
    -- Extensions (le comparateur ne signale que celles qui MANQUENT)
    SELECT 'extension|' || extname || '|' AS l FROM pg_extension

    UNION ALL -- Types énumérés (labels dans l'ordre)
    SELECT 'enum|' || t.typname || '|' ||
           (SELECT string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid = t.oid)
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typtype = 'e'

    UNION ALL -- Tables / vues et RLS
    SELECT 'table|' || relname || '|' ||
           CASE relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'table' WHEN 'v' THEN 'vue' ELSE 'vue matérialisée' END ||
           ' rls=' || relrowsecurity || ' force_rls=' || relforcerowsecurity
    FROM tables

    UNION ALL -- Colonnes
    SELECT 'column|' || t.relname || '.' || a.attname || '|' ||
           format_type(a.atttypid, a.atttypmod) ||
           CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END ||
           coalesce(' DEFAULT ' || regexp_replace(pg_get_expr(ad.adbin, ad.adrelid), '\s+', ' ', 'g'), '')
    FROM tables t
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped
    LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum

    UNION ALL -- Contraintes
    -- « NOT VALID » est retiré : c'est l'état de validation des lignes existantes, pas la structure
    -- (signalé à part, section `info`).
    SELECT 'constraint|' || t.relname || '.' || co.conname || '|' ||
           regexp_replace(regexp_replace(pg_get_constraintdef(co.oid), ' NOT VALID$', ''), '\s+', ' ', 'g')
    FROM tables t JOIN pg_constraint co ON co.conrelid = t.oid
    WHERE t.relkind IN ('r', 'p')

    UNION ALL -- Index
    SELECT 'index|' || tablename || '.' || indexname || '|' ||
           regexp_replace(indexdef, '\s+', ' ', 'g')
    FROM pg_indexes
    WHERE schemaname = 'public' AND tablename IN (SELECT relname FROM tables)

    UNION ALL -- Policies RLS
    SELECT 'policy|' || tablename || '.' || policyname || '|' ||
           'cmd=' || cmd || ' roles=' || array_to_string(roles, ',') ||
           ' using=' || coalesce(regexp_replace(qual, '\s+', ' ', 'g'), '-') ||
           ' with_check=' || coalesce(regexp_replace(with_check, '\s+', ' ', 'g'), '-')
    FROM pg_policies WHERE schemaname = 'public'

    UNION ALL -- Fonctions (signature + empreinte du corps, espaces normalisés)
    SELECT 'function|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|' ||
           'returns=' || pg_get_function_result(p.oid) ||
           ' lang=' || l.lanname ||
           ' security=' || CASE WHEN p.prosecdef THEN 'definer' ELSE 'invoker' END ||
           ' volatility=' || p.provolatile::text ||
           ' config=' || coalesce(array_to_string(p.proconfig, ','), '-') ||
           ' body=' || md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', ' ', 'g'))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_language l ON l.oid = p.prolang
    WHERE n.nspname = 'public'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')

    UNION ALL -- Triggers (hors triggers internes des clés étrangères)
    SELECT 'trigger|' || t.relname || '.' || tg.tgname || '|' ||
           regexp_replace(pg_get_triggerdef(tg.oid), '\s+', ' ', 'g')
    FROM tables t JOIN pg_trigger tg ON tg.tgrelid = t.oid
    WHERE NOT tg.tgisinternal

    UNION ALL -- Vues : empreinte de la définition
    SELECT 'view|' || relname || '|' || md5(regexp_replace(pg_get_viewdef(oid), '\s+', ' ', 'g'))
    FROM tables WHERE relkind IN ('v', 'm')

    UNION ALL -- Droits sur les tables pour anon / authenticated (service_role : ignoré)
    SELECT 'grant|' || t.relname || '.' || r.rolname || '|' ||
           string_agg(x.privilege_type, ',' ORDER BY x.privilege_type)
    FROM tables t
    CROSS JOIN LATERAL aclexplode(coalesce(t.relacl, acldefault('r', (SELECT relowner FROM pg_class WHERE oid = t.oid)))) x
    JOIN pg_roles r ON r.oid = x.grantee AND r.rolname IN ('anon', 'authenticated')
    -- MAINTAIN n'existe qu'à partir de PostgreSQL 17 : exclu pour que l'inventaire ne dépende
    -- pas de la version du serveur (prod, Supabase local, CI).
    WHERE x.privilege_type <> 'MAINTAIN'
    GROUP BY t.relname, r.rolname

    UNION ALL -- Informatif : contraintes dont les lignes existantes n'ont pas été validées (NOT VALID)
    SELECT 'info|not_valid.' || t.relname || '.' || co.conname || '|'
    FROM tables t JOIN pg_constraint co ON co.conrelid = t.oid
    WHERE NOT co.convalidated

    UNION ALL -- Informatif (ignoré par la comparaison) : nombre de lignes par table
    SELECT 'info|count.' || relname || '|' ||
           (xpath('/row/c/text()',
                  query_to_xml(format('SELECT count(*) AS c FROM public.%I', relname), false, true, '')))[1]::text
    FROM tables WHERE relkind IN ('r', 'p')
)
SELECT l AS ligne FROM lignes ORDER BY l COLLATE "C";
