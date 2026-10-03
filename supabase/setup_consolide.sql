-- ============================================================
-- N'Gola Pharma — Setup consolidé (schéma + RLS + alertes_stock)
-- Remplace : setup_complet.sql + fix_rls_recursion.sql
--            + create_alertes_stock.sql + alter_alertes_add_phone.sql
--
-- Objectif : un seul script idempotent à coller dans le SQL Editor
-- d'un projet Supabase NEUF, pour chaque nouveau client pharmacie.
-- Contrairement aux scripts d'origine, celui-ci pose des policies
-- RLS correctes sur `profils` dès le départ (fonction auth_role()
-- SECURITY DEFINER) — pas de récursion, pas de policy manquante.
--
-- Statut : vérifié par lecture/relecture du schéma d'origine du
-- dépôt Mike061566/ngola-pharma. À exécuter une fois sur un projet
-- de test et dérouler la checklist du RUNBOOK_DEPLOIEMENT_CLIENT.md
-- avant de l'utiliser sur un vrai client.
-- ============================================================

-- ============================================================
-- ÉTAPE 1 : EXTENSIONS
-- ============================================================
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================
-- ÉTAPE 2 : TABLES
-- ============================================================

-- ── Quartiers ──
CREATE TABLE IF NOT EXISTS quartiers (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nom         TEXT NOT NULL UNIQUE,
    slug        TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── Pharmacies ──
DO $$ BEGIN CREATE TYPE statut_pharmacie AS ENUM ('non_verifie', 'verifie', 'partenaire'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE source_donnee AS ENUM ('scraping', 'terrain', 'pharmacien', 'admin'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS pharmacies (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nom             TEXT NOT NULL,
    slug            TEXT NOT NULL UNIQUE,
    quartier_id     UUID NOT NULL REFERENCES quartiers(id),
    adresse         TEXT,
    coordinates     GEOGRAPHY(Point, 4326),
    latitude        DOUBLE PRECISION,
    longitude       DOUBLE PRECISION,
    telephone       TEXT,
    email           TEXT,
    site_web        TEXT,
    horaires        JSONB DEFAULT '{}',
    est_de_garde    BOOLEAN NOT NULL DEFAULT false,
    garde_jusqu_a   TIMESTAMPTZ,
    statut          statut_pharmacie NOT NULL DEFAULT 'non_verifie',
    source          source_donnee NOT NULL DEFAULT 'admin',
    logo_url        TEXT,
    note_moyenne    NUMERIC(2,1) DEFAULT 0.0 CHECK (note_moyenne >= 0 AND note_moyenne <= 5),
    nombre_avis     INTEGER DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    verified_at     TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_pharmacies_quartier ON pharmacies(quartier_id);
CREATE INDEX IF NOT EXISTS idx_pharmacies_statut ON pharmacies(statut);
CREATE INDEX IF NOT EXISTS idx_pharmacies_garde ON pharmacies(est_de_garde) WHERE est_de_garde = true;
CREATE INDEX IF NOT EXISTS idx_pharmacies_geo ON pharmacies USING GIST(coordinates);
CREATE INDEX IF NOT EXISTS idx_pharmacies_nom_trgm ON pharmacies USING GIN(nom gin_trgm_ops);

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_pharmacies_updated ON pharmacies;
CREATE TRIGGER trg_pharmacies_updated BEFORE UPDATE ON pharmacies FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE OR REPLACE FUNCTION sync_coordinates()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.latitude IS NOT NULL AND NEW.longitude IS NOT NULL THEN
        NEW.coordinates = ST_SetSRID(ST_MakePoint(NEW.longitude, NEW.latitude), 4326)::geography;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_pharmacies_geo ON pharmacies;
CREATE TRIGGER trg_pharmacies_geo BEFORE INSERT OR UPDATE OF latitude, longitude ON pharmacies FOR EACH ROW EXECUTE FUNCTION sync_coordinates();

-- ── Médicaments ──
CREATE TABLE IF NOT EXISTS medicaments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nom             TEXT NOT NULL,
    nom_commercial  TEXT,
    dci             TEXT,
    forme           TEXT,
    dosage          TEXT,
    categorie       TEXT,
    ordonnance      BOOLEAN NOT NULL DEFAULT false,
    description     TEXT,
    image_url       TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_medicaments_nom ON medicaments USING GIN(nom gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_medicaments_dci ON medicaments(dci);
CREATE INDEX IF NOT EXISTS idx_medicaments_categorie ON medicaments(categorie);

DROP TRIGGER IF EXISTS trg_medicaments_updated ON medicaments;
CREATE TRIGGER trg_medicaments_updated BEFORE UPDATE ON medicaments FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ── Stocks ──
CREATE TABLE IF NOT EXISTS stocks (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pharmacie_id    UUID NOT NULL REFERENCES pharmacies(id) ON DELETE CASCADE,
    medicament_id   UUID NOT NULL REFERENCES medicaments(id) ON DELETE CASCADE,
    prix_fcfa       INTEGER NOT NULL CHECK (prix_fcfa >= 0),
    en_stock        BOOLEAN NOT NULL DEFAULT true,
    date_maj        TIMESTAMPTZ NOT NULL DEFAULT now(),
    source          source_donnee NOT NULL DEFAULT 'admin',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(pharmacie_id, medicament_id)
);

CREATE INDEX IF NOT EXISTS idx_stocks_pharmacie ON stocks(pharmacie_id);
CREATE INDEX IF NOT EXISTS idx_stocks_medicament ON stocks(medicament_id);
CREATE INDEX IF NOT EXISTS idx_stocks_prix ON stocks(prix_fcfa);

-- ── Profils (lié à auth.users) ──
CREATE TABLE IF NOT EXISTS profils (
    id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    nom_complet     TEXT,
    telephone       TEXT,
    quartier_id     UUID REFERENCES quartiers(id),
    role            TEXT NOT NULL DEFAULT 'patient' CHECK (role IN ('patient', 'pharmacien', 'admin')),
    pharmacie_id    UUID REFERENCES pharmacies(id),
    avatar_url      TEXT,
    langue          TEXT NOT NULL DEFAULT 'fr' CHECK (langue IN ('fr', 'en')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_profils_role ON profils(role);
CREATE INDEX IF NOT EXISTS idx_profils_pharmacie ON profils(pharmacie_id);

DROP TRIGGER IF EXISTS trg_profils_updated ON profils;
CREATE TRIGGER trg_profils_updated BEFORE UPDATE ON profils FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ── Recherches (analytics) ──
CREATE TABLE IF NOT EXISTS recherches (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    terme           TEXT NOT NULL,
    user_id         UUID REFERENCES auth.users(id),
    resultats       INTEGER DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_recherches_terme ON recherches(terme);
CREATE INDEX IF NOT EXISTS idx_recherches_date ON recherches(created_at DESC);

-- ── Alertes de stock (notifications "prévenez-moi") ──
-- Colonnes téléphone/canal incluses dès la création (fusion de
-- create_alertes_stock.sql + alter_alertes_add_phone.sql d'origine).
CREATE TABLE IF NOT EXISTS alertes_stock (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_email      TEXT,
    user_phone      TEXT,
    canal           TEXT DEFAULT 'email' CHECK (canal IN ('email', 'whatsapp', 'ussd')),
    medicament_nom  TEXT NOT NULL,
    medicament_id   UUID REFERENCES medicaments(id),
    quartier_id     UUID REFERENCES quartiers(id),
    created_at      TIMESTAMPTZ DEFAULT now(),
    notified_at     TIMESTAMPTZ,
    active          BOOLEAN DEFAULT true,
    CONSTRAINT contact_required CHECK (user_email IS NOT NULL OR user_phone IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_alertes_stock_active ON alertes_stock(active, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_alertes_stock_email ON alertes_stock(user_email);
CREATE INDEX IF NOT EXISTS idx_alertes_stock_phone ON alertes_stock(user_phone);

-- ============================================================
-- ÉTAPE 3 : FONCTION ANTI-RÉCURSION POUR LES POLICIES RLS
-- ============================================================
-- SECURITY DEFINER : contourne le RLS de `profils` en interne,
-- pour que les policies d'AUTRES tables (et de `profils` elle-même)
-- puissent vérifier le rôle sans déclencher une évaluation récursive
-- de la policy SELECT de `profils`.
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

CREATE OR REPLACE FUNCTION auth_pharmacie_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT pharmacie_id FROM profils WHERE id = auth.uid();
$$;

-- ============================================================
-- ÉTAPE 4 : ROW LEVEL SECURITY — policies finales, non récursives
-- ============================================================

-- Le DROP POLICY IF EXISTS couvre les noms utilisés par les
-- anciens scripts (001_schema.sql / setup_complet.sql /
-- fix_rls_recursion.sql / create_alertes_stock.sql), pour que ce
-- script reste rejouable sans erreur sur un projet où l'un d'eux
-- aurait déjà tourné partiellement.

-- Quartiers : lecture publique
ALTER TABLE quartiers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Quartiers lisibles par tous" ON quartiers;
CREATE POLICY "Quartiers lisibles par tous" ON quartiers FOR SELECT USING (true);

-- Pharmacies : lecture publique, écriture admin/pharmacien (sa propre pharmacie)
ALTER TABLE pharmacies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Pharmacies lisibles par tous" ON pharmacies;
DROP POLICY IF EXISTS "Pharmacies modifiables par admin" ON pharmacies;
DROP POLICY IF EXISTS "Pharmacien modifie sa pharmacie" ON pharmacies;
CREATE POLICY "Pharmacies lisibles par tous" ON pharmacies FOR SELECT USING (true);
CREATE POLICY "Pharmacies modifiables par admin" ON pharmacies FOR ALL
    USING (auth_role() = 'admin');
CREATE POLICY "Pharmacien modifie sa pharmacie" ON pharmacies FOR UPDATE
    USING (auth_role() = 'pharmacien' AND id = auth_pharmacie_id());

-- Médicaments : lecture publique, écriture admin
ALTER TABLE medicaments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Médicaments lisibles par tous" ON medicaments;
DROP POLICY IF EXISTS "Médicaments modifiables par admin" ON medicaments;
CREATE POLICY "Médicaments lisibles par tous" ON medicaments FOR SELECT USING (true);
CREATE POLICY "Médicaments modifiables par admin" ON medicaments FOR ALL
    USING (auth_role() = 'admin');

-- Stocks : lecture publique, écriture admin/pharmacien (sa propre pharmacie)
ALTER TABLE stocks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Stocks lisibles par tous" ON stocks;
DROP POLICY IF EXISTS "Stocks modifiables par admin" ON stocks;
DROP POLICY IF EXISTS "Pharmacien gère ses stocks" ON stocks;
CREATE POLICY "Stocks lisibles par tous" ON stocks FOR SELECT USING (true);
CREATE POLICY "Stocks modifiables par admin" ON stocks FOR ALL
    USING (auth_role() = 'admin');
CREATE POLICY "Pharmacien gère ses stocks" ON stocks FOR ALL
    USING (auth_role() = 'pharmacien' AND pharmacie_id = auth_pharmacie_id());

-- Profils : chacun voit/modifie le sien, l'admin voit tout
ALTER TABLE profils ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Profil visible par son propriétaire" ON profils;
DROP POLICY IF EXISTS "Profil modifiable par son propriétaire" ON profils;
DROP POLICY IF EXISTS "profils_select" ON profils;
DROP POLICY IF EXISTS "profils_update" ON profils;
DROP POLICY IF EXISTS "profils_insert" ON profils;
CREATE POLICY "profils_select" ON profils FOR SELECT
    USING (id = auth.uid() OR auth_role() = 'admin');
-- Un utilisateur peut modifier son propre profil, mais ne peut changer ni son
-- `role` ni son `pharmacie_id` (seul un admin le peut). Sans la restriction sur
-- `role`, n'importe quel compte pourrait s'octroyer l'accès admin ; sans celle sur
-- `pharmacie_id`, un pharmacien pourrait se rattacher à une autre officine et
-- modifier ses stocks. Voir supabase/fix_profils_pharmacie_id.sql.
CREATE POLICY "profils_update" ON profils FOR UPDATE
    USING (id = auth.uid() OR auth_role() = 'admin')
    WITH CHECK (
        auth_role() = 'admin'
        OR (
            id = auth.uid()
            AND role = auth_role()
            AND pharmacie_id IS NOT DISTINCT FROM auth_pharmacie_id()
        )
    );
-- Auto-inscription publique : uniquement en tant que patient, sans
-- pharmacie liée. Un admin existant peut créer un profil avec
-- n'importe quel rôle (ex. depuis le SQL Editor).
CREATE POLICY "profils_insert" ON profils FOR INSERT
    WITH CHECK (
        id = auth.uid()
        AND ((role = 'patient' AND pharmacie_id IS NULL) OR auth_role() = 'admin')
    );

-- Recherches : insertion publique, lecture admin
ALTER TABLE recherches ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Tout le monde peut rechercher" ON recherches;
DROP POLICY IF EXISTS "Recherches lisibles par admin" ON recherches;
CREATE POLICY "Tout le monde peut rechercher" ON recherches FOR INSERT WITH CHECK (true);
CREATE POLICY "Recherches lisibles par admin" ON recherches FOR SELECT
    USING (auth_role() = 'admin');

-- Alertes de stock : insertion publique (anon + authentifié), lecture/modif admin uniquement
ALTER TABLE alertes_stock ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Tout le monde peut créer une alerte" ON alertes_stock;
DROP POLICY IF EXISTS "Admins voient les alertes" ON alertes_stock;
DROP POLICY IF EXISTS "Admins modifient les alertes" ON alertes_stock;
CREATE POLICY "Tout le monde peut créer une alerte" ON alertes_stock FOR INSERT
    TO anon, authenticated WITH CHECK (true);
CREATE POLICY "Admins voient les alertes" ON alertes_stock FOR SELECT
    TO authenticated USING (auth_role() = 'admin');
CREATE POLICY "Admins modifient les alertes" ON alertes_stock FOR UPDATE
    TO authenticated USING (auth_role() = 'admin');

-- ============================================================
-- ÉTAPE 5 : VUES & FONCTION DE RECHERCHE GÉOGRAPHIQUE
-- ============================================================

CREATE OR REPLACE VIEW v_pharmacies AS
SELECT p.*, q.nom AS quartier_nom, q.slug AS quartier_slug
FROM pharmacies p
JOIN quartiers q ON q.id = p.quartier_id;

CREATE OR REPLACE VIEW v_meilleurs_prix AS
SELECT DISTINCT ON (s.medicament_id)
    s.medicament_id,
    m.nom AS medicament_nom,
    m.dci,
    m.dosage,
    s.pharmacie_id,
    ph.nom AS pharmacie_nom,
    ph.quartier_id,
    q.nom AS quartier_nom,
    s.prix_fcfa,
    s.en_stock
FROM stocks s
JOIN medicaments m ON m.id = s.medicament_id
JOIN pharmacies ph ON ph.id = s.pharmacie_id
JOIN quartiers q ON q.id = ph.quartier_id
WHERE s.en_stock = true
ORDER BY s.medicament_id, s.prix_fcfa ASC;

CREATE OR REPLACE FUNCTION pharmacies_proches(
    lat DOUBLE PRECISION, lng DOUBLE PRECISION, rayon_m INTEGER DEFAULT 3000
)
RETURNS TABLE (
    id UUID, nom TEXT, adresse TEXT,
    latitude DOUBLE PRECISION, longitude DOUBLE PRECISION,
    distance_m DOUBLE PRECISION, est_de_garde BOOLEAN,
    statut statut_pharmacie, quartier_nom TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT p.id, p.nom, p.adresse, p.latitude, p.longitude,
        ST_Distance(p.coordinates, ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography) AS distance_m,
        p.est_de_garde, p.statut, q.nom AS quartier_nom
    FROM pharmacies p
    JOIN quartiers q ON q.id = p.quartier_id
    WHERE ST_DWithin(p.coordinates, ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography, rayon_m)
    ORDER BY distance_m;
$$;

-- ============================================================
-- ÉTAPE 6 : DONNÉES DE DÉMO — À SUPPRIMER/REMPLACER POUR UN VRAI CLIENT
-- ============================================================
-- Cette section reprend les données de démo de Yaoundé (7 quartiers,
-- 52 pharmacies, 20 médicaments, stocks factices) de setup_complet.sql.
-- Pour un vrai client, commenter/supprimer ce bloc et importer les
-- vraies données (voir étape 5 du RUNBOOK_DEPLOIEMENT_CLIENT.md :
-- npm run seed avec les CSV du client, ou INSERT adaptés).

-- Quartiers
INSERT INTO quartiers (nom, slug, description) VALUES
    ('Centre-Ville', 'centre-ville', 'Cœur administratif et commercial de Yaoundé'),
    ('Bastos', 'bastos', 'Quartier résidentiel et diplomatique'),
    ('Essos', 'essos', 'Quartier populaire et animé'),
    ('Mvan', 'mvan', 'Pôle universitaire et jeune'),
    ('Ngousso', 'ngousso', 'Quartier en pleine expansion'),
    ('Odza', 'odza', 'Zone aéroportuaire et périurbaine'),
    ('Nlongkak', 'nlongkak', 'Quartier central résidentiel')
ON CONFLICT (slug) DO NOTHING;

-- Médicaments (20)
INSERT INTO medicaments (nom, nom_commercial, dci, forme, dosage, categorie, ordonnance, description) VALUES
    ('Paracétamol 500mg', 'Doliprane', 'Paracétamol', 'Comprimé', '500mg', 'Antalgique', false, 'Antalgique et antipyrétique courant'),
    ('Paracétamol 1000mg', 'Efferalgan', 'Paracétamol', 'Comprimé effervescent', '1000mg', 'Antalgique', false, 'Antalgique effervescent'),
    ('Ibuprofène 400mg', 'Advil', 'Ibuprofène', 'Comprimé', '400mg', 'Anti-inflammatoire', false, 'Anti-inflammatoire non stéroïdien'),
    ('Aspirine 500mg', 'Aspro', 'Acide acétylsalicylique', 'Comprimé', '500mg', 'Antalgique', false, 'Antalgique anti-inflammatoire'),
    ('Amoxicilline 500mg', 'Clamoxyl', 'Amoxicilline', 'Gélule', '500mg', 'Antibiotique', true, 'Antibiotique bêta-lactamine'),
    ('Métronidazole 500mg', 'Flagyl', 'Métronidazole', 'Comprimé', '500mg', 'Antibiotique', true, 'Antiparasitaire et antibactérien'),
    ('Coartem', 'Coartem', 'Artemether-Lumefantrine', 'Comprimé', '20/120mg', 'Antipaludéen', true, 'Traitement du paludisme'),
    ('Quinine 500mg', 'Quinimax', 'Quinine', 'Comprimé', '500mg', 'Antipaludéen', true, 'Antipaludéen classique'),
    ('Oméprazole 20mg', 'Mopral', 'Oméprazole', 'Gélule', '20mg', 'Gastro-entérologie', false, 'Inhibiteur de la pompe à protons'),
    ('Métformine 500mg', 'Glucophage', 'Métformine', 'Comprimé', '500mg', 'Diabétologie', true, 'Antidiabétique oral'),
    ('Vitamine C 500mg', 'Vitascorbol', 'Acide ascorbique', 'Comprimé', '500mg', 'Vitamines', false, 'Complément en vitamine C'),
    ('Multivitamines', 'Supradyn', 'Multivitamines', 'Comprimé effervescent', '', 'Vitamines', false, 'Complexe multivitaminé'),
    ('Chloroquine 100mg', 'Nivaquine', 'Chloroquine', 'Comprimé', '100mg', 'Antipaludéen', true, 'Prophylaxie du paludisme'),
    ('Diclofénac 50mg', 'Voltarène', 'Diclofénac', 'Comprimé', '50mg', 'Anti-inflammatoire', false, 'AINS puissant'),
    ('Cotrimoxazole', 'Bactrim', 'Sulfaméthoxazole-Triméthoprime', 'Comprimé', '800/160mg', 'Antibiotique', true, 'Antibiotique à large spectre'),
    ('Cétirizine 10mg', 'Zyrtec', 'Cétirizine', 'Comprimé', '10mg', 'Antihistaminique', false, 'Antiallergique non sédatif'),
    ('Lopéramide 2mg', 'Imodium', 'Lopéramide', 'Gélule', '2mg', 'Gastro-entérologie', false, 'Antidiarrhéique'),
    ('Salbutamol', 'Ventoline', 'Salbutamol', 'Aérosol', '100µg/dose', 'Pneumologie', true, 'Bronchodilatateur d''urgence'),
    ('Fer + Acide folique', 'Tardyféron', 'Fer-Acide folique', 'Comprimé', '80mg+0.35mg', 'Hématologie', false, 'Traitement de l''anémie'),
    ('Ciprofloxacine 500mg', 'Ciflox', 'Ciprofloxacine', 'Comprimé', '500mg', 'Antibiotique', true, 'Fluoroquinolone à large spectre')
ON CONFLICT DO NOTHING;

-- Pharmacies de démo (extrait minimal pour tester le flux — pas les 52 de Yaoundé,
-- voir setup_complet.sql sur GitHub pour la liste complète si besoin d'un jeu plus riche)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie du Centre', 'pharmacie-du-centre', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Avenue Kennedy, Centre-Ville', 3.8667, 11.5167, '+237 222 23 45 67', 'verifie', 'admin'),
    ('Pharmacie de Bastos', 'pharmacie-de-bastos', (SELECT id FROM quartiers WHERE slug='bastos'), 'Rue Joseph Mballa Eloumden, Bastos', 3.8830, 11.5070, '+237 222 20 11 22', 'verifie', 'admin'),
    ('Pharmacie d''Essos', 'pharmacie-d-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Carrefour Essos', 3.8740, 11.5330, '+237 222 22 11 22', 'non_verifie', 'admin')
ON CONFLICT (slug) DO NOTHING;

-- Stocks de démonstration
DO $$
DECLARE
    ph_ids UUID[];
    med_ids UUID[];
    prix INTEGER[] := ARRAY[1200, 1500, 1800, 2500, 3500, 2000, 4500, 3000, 1800, 2200,
                            1100, 1600, 1900, 2300, 3200];
    i INTEGER; j INTEGER; idx INTEGER := 1;
BEGIN
    SELECT array_agg(id ORDER BY nom) INTO ph_ids FROM pharmacies LIMIT 3;
    SELECT array_agg(id ORDER BY nom) INTO med_ids FROM medicaments LIMIT 5;

    FOR i IN 1..3 LOOP
        FOR j IN 1..5 LOOP
            INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock, source)
            VALUES (ph_ids[i], med_ids[j], prix[idx], true, 'admin')
            ON CONFLICT (pharmacie_id, medicament_id) DO NOTHING;
            idx := idx + 1;
        END LOOP;
    END LOOP;
END $$;

UPDATE pharmacies SET est_de_garde = true, garde_jusqu_a = now() + interval '24 hours'
WHERE slug = 'pharmacie-du-centre';

-- ============================================================
-- VÉRIFICATION FINALE
-- ============================================================
DO $$
DECLARE
    n_quartiers INTEGER; n_pharmacies INTEGER; n_medicaments INTEGER;
    n_stocks INTEGER; n_garde INTEGER; n_profils_policies INTEGER;
BEGIN
    SELECT count(*) INTO n_quartiers FROM quartiers;
    SELECT count(*) INTO n_pharmacies FROM pharmacies;
    SELECT count(*) INTO n_medicaments FROM medicaments;
    SELECT count(*) INTO n_stocks FROM stocks;
    SELECT count(*) INTO n_garde FROM pharmacies WHERE est_de_garde = true;
    SELECT count(*) INTO n_profils_policies FROM pg_policies WHERE tablename = 'profils';

    RAISE NOTICE '✅ Setup consolidé terminé : % quartiers, % pharmacies (% de garde), % médicaments, % stocks',
        n_quartiers, n_pharmacies, n_garde, n_medicaments, n_stocks;

    IF n_profils_policies <> 3 THEN
        RAISE WARNING '⚠️  % policies trouvées sur profils (3 attendues) — vérifier avant de continuer', n_profils_policies;
    ELSE
        RAISE NOTICE '✅ profils : 3 policies RLS en place (select/update/insert), pas de récursion';
    END IF;
END $$;
