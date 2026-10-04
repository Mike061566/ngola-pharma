-- ============================================================
-- N'Gola Pharma — Rollback de setup_consolide.sql
-- À exécuter UNIQUEMENT dans le projet Supabase où le script a été
-- collé par erreur.
--
-- ⚠️ SÉCURITÉ : ce script suppose que le schéma `public` de ce
-- projet ne contient QUE des objets créés par setup_consolide.sql
-- (aucune autre donnée/table pré-existante). Si ce projet contient
-- autre chose (une autre appli, un autre client), ne pas lancer ce
-- script tel quel — vérifier d'abord la liste des tables avec :
--
--   select tablename from pg_tables where schemaname = 'public';
--
-- ============================================================

-- ============================================================
-- ÉTAPE 1 : SUPPRIMER LES TABLES (ordre inverse des FK)
-- ============================================================
-- Les CASCADE suppriment aussi les policies RLS, index, triggers
-- et contraintes associés à chaque table automatiquement.

DROP TABLE IF EXISTS alertes_stock CASCADE;
DROP TABLE IF EXISTS recherches CASCADE;
DROP TABLE IF EXISTS profils CASCADE;
DROP TABLE IF EXISTS stocks CASCADE;
DROP TABLE IF EXISTS medicaments CASCADE;
DROP TABLE IF EXISTS pharmacies CASCADE;
DROP TABLE IF EXISTS quartiers CASCADE;

-- ============================================================
-- ÉTAPE 2 : SUPPRIMER LES VUES
-- ============================================================

DROP VIEW IF EXISTS v_meilleurs_prix CASCADE;
DROP VIEW IF EXISTS v_pharmacies CASCADE;

-- ============================================================
-- ÉTAPE 3 : SUPPRIMER LES FONCTIONS
-- ============================================================

DROP FUNCTION IF EXISTS pharmacies_proches(DOUBLE PRECISION, DOUBLE PRECISION, INTEGER);
DROP FUNCTION IF EXISTS auth_pharmacie_id();
DROP FUNCTION IF EXISTS auth_role();
DROP FUNCTION IF EXISTS sync_coordinates() CASCADE;
DROP FUNCTION IF EXISTS update_updated_at() CASCADE;

-- ============================================================
-- ÉTAPE 4 : SUPPRIMER LES TYPES ENUM
-- ============================================================
-- (uniquement possible une fois toutes les tables/colonnes qui les
-- utilisaient supprimées à l'étape 1)

DROP TYPE IF EXISTS source_donnee;
DROP TYPE IF EXISTS statut_pharmacie;

-- ============================================================
-- NOTE : extensions non supprimées
-- ============================================================
-- postgis et pg_trgm sont laissées activées volontairement : les
-- retirer nécessite des droits superuser et peut affecter d'autres
-- objets du projet si celui-ci n'est pas totalement vide. Ce n'est
-- pas gênant de les laisser actives si le projet est réutilisé.

-- ============================================================
-- ÉTAPE 5 : SUPPRIMER LE(S) COMPTE(S) DE TEST
-- ============================================================
-- Le SQL Editor ne supprime pas les comptes auth.users proprement
-- (Supabase recommande de passer par l'UI). À faire manuellement :
--   Dashboard → Authentication → Users → sélectionner le compte
--   test (ex. pcaedeninternational@gmail.com) → Delete user.
-- (La ligne `profils` correspondante est déjà partie avec le
-- DROP TABLE profils CASCADE ci-dessus, donc pas de FK bloquante.)

-- ============================================================
-- VÉRIFICATION
-- ============================================================
DO $$
DECLARE
    n_tables INTEGER;
BEGIN
    SELECT count(*) INTO n_tables
    FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename IN ('quartiers','pharmacies','medicaments','stocks','profils','recherches','alertes_stock');

    IF n_tables = 0 THEN
        RAISE NOTICE '✅ Rollback terminé : plus aucune table N''Gola Pharma dans ce projet.';
    ELSE
        RAISE WARNING '⚠️  % table(s) N''Gola Pharma encore présente(s) — vérifier manuellement', n_tables;
    END IF;
END $$;
