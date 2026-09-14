-- ============================================================
-- N'Gola Pharma — Fix RLS infinite recursion on profils
-- Exécuter dans Supabase SQL Editor
-- ============================================================

-- ─── ÉTAPE 1 : Fonction SECURITY DEFINER pour vérifier le rôle ───
-- Cette fonction contourne le RLS de profils pour éviter la récursion
CREATE OR REPLACE FUNCTION auth_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT role FROM profils WHERE id = auth.uid()),
    'anonymous'
  );
$$;

-- ─── ÉTAPE 2 : Supprimer TOUTES les anciennes politiques ───

-- Profils
DROP POLICY IF EXISTS "Profil visible par son propriétaire" ON profils;
DROP POLICY IF EXISTS "Profil modifiable par son propriétaire" ON profils;
DROP POLICY IF EXISTS "profils_select" ON profils;
DROP POLICY IF EXISTS "profils_update" ON profils;
DROP POLICY IF EXISTS "profils_insert" ON profils;

-- Pharmacies
DROP POLICY IF EXISTS "Pharmacies lisibles par tous" ON pharmacies;
DROP POLICY IF EXISTS "Pharmacies modifiables par admin" ON pharmacies;
DROP POLICY IF EXISTS "Pharmacien modifie sa pharmacie" ON pharmacies;

-- Médicaments
DROP POLICY IF EXISTS "Médicaments lisibles par tous" ON medicaments;
DROP POLICY IF EXISTS "Médicaments modifiables par admin" ON medicaments;

-- Stocks
DROP POLICY IF EXISTS "Stocks lisibles par tous" ON stocks;
DROP POLICY IF EXISTS "Stocks modifiables par admin" ON stocks;
DROP POLICY IF EXISTS "Pharmacien gère ses stocks" ON stocks;

-- Recherches
DROP POLICY IF EXISTS "Tout le monde peut rechercher" ON recherches;
DROP POLICY IF EXISTS "Recherches lisibles par admin" ON recherches;

-- Quartiers
DROP POLICY IF EXISTS "Quartiers lisibles par tous" ON quartiers;

-- ─── ÉTAPE 3 : Recréer les politiques SANS récursion ───

-- Quartiers : lecture publique
CREATE POLICY "Quartiers lisibles par tous"
  ON quartiers FOR SELECT USING (true);

-- Pharmacies : lecture publique, écriture admin/pharmacien
CREATE POLICY "Pharmacies lisibles par tous"
  ON pharmacies FOR SELECT USING (true);

CREATE POLICY "Pharmacies modifiables par admin"
  ON pharmacies FOR ALL
  USING (auth_role() = 'admin');

CREATE POLICY "Pharmacien modifie sa pharmacie"
  ON pharmacies FOR UPDATE
  USING (auth_role() = 'pharmacien' AND id IN (
    SELECT pharmacie_id FROM profils WHERE id = auth.uid()
  ));

-- Médicaments : lecture publique, écriture admin
CREATE POLICY "Médicaments lisibles par tous"
  ON medicaments FOR SELECT USING (true);

CREATE POLICY "Médicaments modifiables par admin"
  ON medicaments FOR ALL
  USING (auth_role() = 'admin');

-- Stocks : lecture publique, écriture admin/pharmacien
CREATE POLICY "Stocks lisibles par tous"
  ON stocks FOR SELECT USING (true);

CREATE POLICY "Stocks modifiables par admin"
  ON stocks FOR ALL
  USING (auth_role() = 'admin');

CREATE POLICY "Pharmacien gère ses stocks"
  ON stocks FOR ALL
  USING (auth_role() = 'pharmacien' AND pharmacie_id IN (
    SELECT pharmacie_id FROM profils WHERE id = auth.uid()
  ));

-- Profils : l'utilisateur voit/modifie le sien, admin voit tout
CREATE POLICY "profils_select"
  ON profils FOR SELECT
  USING (id = auth.uid() OR auth_role() = 'admin');

CREATE POLICY "profils_update"
  ON profils FOR UPDATE
  USING (id = auth.uid());

CREATE POLICY "profils_insert"
  ON profils FOR INSERT
  WITH CHECK (id = auth.uid());

-- Recherches : insertion publique, lecture admin
CREATE POLICY "Tout le monde peut rechercher"
  ON recherches FOR INSERT WITH CHECK (true);

CREATE POLICY "Recherches lisibles par admin"
  ON recherches FOR SELECT
  USING (auth_role() = 'admin');

-- ─── ÉTAPE 4 : Vérification ───
DO $$
BEGIN
  RAISE NOTICE '✅ Fix RLS appliqué avec succès !';
  RAISE NOTICE '   → Fonction auth_role() créée (SECURITY DEFINER)';
  RAISE NOTICE '   → Anciennes politiques récursives supprimées';
  RAISE NOTICE '   → Nouvelles politiques sans récursion créées';
END $$;
