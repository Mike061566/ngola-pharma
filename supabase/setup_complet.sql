-- ============================================================
-- N'Gola Pharma — Setup complet pour Supabase SQL Editor
-- Exécuter ce script EN UNE SEULE FOIS dans :
-- https://supabase.com/dashboard → SQL Editor → New Query
-- ============================================================

-- ============================================================
-- ÉTAPE 1 : SCHÉMA (tables, index, vues, fonctions)
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ── QUARTIERS ──
CREATE TABLE IF NOT EXISTS quartiers (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nom         TEXT NOT NULL UNIQUE,
    slug        TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── PHARMACIES ──
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

-- ── MÉDICAMENTS ──
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

-- ── STOCKS ──
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

-- ── PROFILS ──
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

DROP TRIGGER IF EXISTS trg_profils_updated ON profils;
CREATE TRIGGER trg_profils_updated BEFORE UPDATE ON profils FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ── RECHERCHES ──
CREATE TABLE IF NOT EXISTS recherches (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    terme           TEXT NOT NULL,
    user_id         UUID REFERENCES auth.users(id),
    resultats       INTEGER DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_recherches_terme ON recherches(terme);
CREATE INDEX IF NOT EXISTS idx_recherches_date ON recherches(created_at DESC);

-- ============================================================
-- ÉTAPE 2 : ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE quartiers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Quartiers lisibles par tous" ON quartiers;
CREATE POLICY "Quartiers lisibles par tous" ON quartiers FOR SELECT USING (true);

ALTER TABLE pharmacies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Pharmacies lisibles par tous" ON pharmacies;
CREATE POLICY "Pharmacies lisibles par tous" ON pharmacies FOR SELECT USING (true);

ALTER TABLE medicaments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Médicaments lisibles par tous" ON medicaments;
CREATE POLICY "Médicaments lisibles par tous" ON medicaments FOR SELECT USING (true);

ALTER TABLE stocks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Stocks lisibles par tous" ON stocks;
CREATE POLICY "Stocks lisibles par tous" ON stocks FOR SELECT USING (true);

ALTER TABLE profils ENABLE ROW LEVEL SECURITY;

ALTER TABLE recherches ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Tout le monde peut rechercher" ON recherches;
CREATE POLICY "Tout le monde peut rechercher" ON recherches FOR INSERT WITH CHECK (true);

-- ============================================================
-- ÉTAPE 3 : VUES
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
-- ÉTAPE 4 : DONNÉES DE SEED
-- ============================================================

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

-- Pharmacies Centre-Ville (12)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie du Centre', 'pharmacie-du-centre', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Avenue Kennedy, Centre-Ville', 3.8667, 11.5167, '+237 222 23 45 67', 'non_verifie', 'admin'),
    ('Pharmacie de la Poste Centrale', 'pharmacie-de-la-poste-centrale', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Rue de la Poste, Centre-Ville', 3.8670, 11.5185, '+237 222 23 12 34', 'non_verifie', 'admin'),
    ('Pharmacie du Marché Central', 'pharmacie-du-marche-central', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Boulevard du 20 Mai, Centre-Ville', 3.8685, 11.5170, '+237 222 23 56 78', 'non_verifie', 'admin'),
    ('Pharmacie de l''Hôtel de Ville', 'pharmacie-de-l-hotel-de-ville', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Place de l''Hôtel de Ville', 3.8660, 11.5195, '+237 222 23 89 01', 'non_verifie', 'admin'),
    ('Pharmacie Biyem-Assi', 'pharmacie-biyem-assi', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Carrefour Biyem-Assi', 3.8540, 11.4985, '+237 222 23 22 33', 'non_verifie', 'admin'),
    ('Pharmacie Kennedy', 'pharmacie-kennedy', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Avenue Kennedy', 3.8672, 11.5150, '+237 222 23 44 55', 'non_verifie', 'admin'),
    ('Pharmacie du Plateau', 'pharmacie-du-plateau', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Quartier du Plateau', 3.8700, 11.5180, '+237 222 23 66 77', 'non_verifie', 'admin'),
    ('Pharmacie Mvog-Ada', 'pharmacie-mvog-ada', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Carrefour Mvog-Ada', 3.8595, 11.5135, '+237 222 23 88 99', 'non_verifie', 'admin'),
    ('Pharmacie de la Cathédrale', 'pharmacie-de-la-cathedrale', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Rue de la Cathédrale', 3.8678, 11.5200, '+237 222 23 11 22', 'non_verifie', 'admin'),
    ('Pharmacie Warda', 'pharmacie-warda', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Avenue Monseigneur Vogt', 3.8655, 11.5175, '+237 222 23 33 44', 'non_verifie', 'admin'),
    ('Pharmacie Elig-Essono', 'pharmacie-elig-essono', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Carrefour Elig-Essono', 3.8690, 11.5210, '+237 222 23 55 66', 'non_verifie', 'admin'),
    ('Pharmacie du 20 Mai', 'pharmacie-du-20-mai', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Boulevard du 20 Mai', 3.8695, 11.5165, '+237 222 23 77 88', 'non_verifie', 'admin')
ON CONFLICT (slug) DO NOTHING;

-- Pharmacies Bastos (8)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie de Bastos', 'pharmacie-de-bastos', (SELECT id FROM quartiers WHERE slug='bastos'), 'Rue Joseph Mballa Eloumden, Bastos', 3.8830, 11.5070, '+237 222 20 11 22', 'non_verifie', 'admin'),
    ('Pharmacie du Lac', 'pharmacie-du-lac', (SELECT id FROM quartiers WHERE slug='bastos'), 'Quartier du Lac, Bastos', 3.8850, 11.5100, '+237 222 20 33 44', 'non_verifie', 'admin'),
    ('Pharmacie les Ambassades', 'pharmacie-les-ambassades', (SELECT id FROM quartiers WHERE slug='bastos'), 'Avenue Charles de Gaulle, Bastos', 3.8815, 11.5055, '+237 222 20 55 66', 'non_verifie', 'admin'),
    ('Pharmacie Santa Lucia', 'pharmacie-santa-lucia', (SELECT id FROM quartiers WHERE slug='bastos'), 'Rue 1.828, Bastos', 3.8840, 11.5085, '+237 222 20 77 88', 'non_verifie', 'admin'),
    ('Pharmacie Golf', 'pharmacie-golf', (SELECT id FROM quartiers WHERE slug='bastos'), 'Près du Golf Club, Bastos', 3.8870, 11.5110, '+237 222 20 99 00', 'non_verifie', 'admin'),
    ('Pharmacie Nouvelle Bastos', 'pharmacie-nouvelle-bastos', (SELECT id FROM quartiers WHERE slug='bastos'), 'Carrefour Bastos', 3.8820, 11.5065, '+237 222 20 22 33', 'non_verifie', 'admin'),
    ('Pharmacie Résidence', 'pharmacie-residence', (SELECT id FROM quartiers WHERE slug='bastos'), 'Avenue des Palmiers, Bastos', 3.8860, 11.5095, '+237 222 20 44 55', 'non_verifie', 'admin'),
    ('Pharmacie Tropicale', 'pharmacie-tropicale', (SELECT id FROM quartiers WHERE slug='bastos'), 'Rue 1.845, Bastos', 3.8845, 11.5080, '+237 222 20 66 77', 'non_verifie', 'admin')
ON CONFLICT (slug) DO NOTHING;

-- Pharmacies Essos (15)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie d''Essos', 'pharmacie-d-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Carrefour Essos', 3.8740, 11.5330, '+237 222 22 11 22', 'non_verifie', 'admin'),
    ('Pharmacie de la Paix', 'pharmacie-de-la-paix', (SELECT id FROM quartiers WHERE slug='essos'), 'Rue d''Essos', 3.8755, 11.5345, '+237 222 22 33 44', 'non_verifie', 'admin'),
    ('Pharmacie Populaire d''Essos', 'pharmacie-populaire-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Marché d''Essos', 3.8735, 11.5320, '+237 222 22 55 66', 'non_verifie', 'admin'),
    ('Pharmacie Fraternité', 'pharmacie-fraternite', (SELECT id FROM quartiers WHERE slug='essos'), 'Avenue d''Essos', 3.8760, 11.5355, '+237 222 22 77 88', 'non_verifie', 'admin'),
    ('Pharmacie Carrefour Essos', 'pharmacie-carrefour-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Grand Carrefour Essos', 3.8745, 11.5335, '+237 222 22 99 00', 'non_verifie', 'admin'),
    ('Pharmacie du Bonheur', 'pharmacie-du-bonheur', (SELECT id FROM quartiers WHERE slug='essos'), 'Rue du Bonheur, Essos', 3.8770, 11.5360, '+237 222 22 22 33', 'non_verifie', 'admin'),
    ('Pharmacie la Providence Essos', 'pharmacie-la-providence-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Quartier Essos Nord', 3.8780, 11.5340, '+237 222 22 44 55', 'non_verifie', 'admin'),
    ('Pharmacie Espoir', 'pharmacie-espoir', (SELECT id FROM quartiers WHERE slug='essos'), 'Essos Sud', 3.8725, 11.5315, '+237 222 22 66 77', 'non_verifie', 'admin'),
    ('Pharmacie Centrale Essos', 'pharmacie-centrale-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Centre Essos', 3.8750, 11.5350, '+237 222 22 88 99', 'non_verifie', 'admin'),
    ('Pharmacie les Palmiers Essos', 'pharmacie-les-palmiers-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Avenue des Palmiers, Essos', 3.8765, 11.5325, '+237 222 22 11 33', 'non_verifie', 'admin'),
    ('Pharmacie Lumière', 'pharmacie-lumiere', (SELECT id FROM quartiers WHERE slug='essos'), 'Essos Plateau', 3.8738, 11.5355, '+237 222 22 44 66', 'non_verifie', 'admin'),
    ('Pharmacie Santé Plus Essos', 'pharmacie-sante-plus-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Carrefour Essos Est', 3.8775, 11.5370, '+237 222 22 55 77', 'non_verifie', 'admin'),
    ('Pharmacie Solidarité Essos', 'pharmacie-solidarite-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Essos Ouest', 3.8730, 11.5310, '+237 222 22 66 88', 'non_verifie', 'admin'),
    ('Pharmacie Merveilleuse Essos', 'pharmacie-merveilleuse-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Rue Merveilleuse, Essos', 3.8742, 11.5365, '+237 222 22 77 99', 'non_verifie', 'admin'),
    ('Pharmacie Bonne Santé Essos', 'pharmacie-bonne-sante-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Essos Centre-Sud', 3.8758, 11.5328, '+237 222 22 88 11', 'non_verifie', 'admin')
ON CONFLICT (slug) DO NOTHING;

-- Pharmacies Mvan (10)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie du Campus', 'pharmacie-du-campus', (SELECT id FROM quartiers WHERE slug='mvan'), 'Entrée Université Yaoundé I, Mvan', 3.8560, 11.4960, '+237 222 21 11 22', 'non_verifie', 'admin'),
    ('Pharmacie Étudiante', 'pharmacie-etudiante', (SELECT id FROM quartiers WHERE slug='mvan'), 'Rue des Étudiants, Mvan', 3.8575, 11.4975, '+237 222 21 33 44', 'non_verifie', 'admin'),
    ('Pharmacie du Savoir', 'pharmacie-du-savoir', (SELECT id FROM quartiers WHERE slug='mvan'), 'Boulevard Universitaire, Mvan', 3.8550, 11.4950, '+237 222 21 55 66', 'non_verifie', 'admin'),
    ('Pharmacie la Référence Mvan', 'pharmacie-la-reference-mvan', (SELECT id FROM quartiers WHERE slug='mvan'), 'Carrefour Mvan', 3.8580, 11.4980, '+237 222 21 77 88', 'non_verifie', 'admin'),
    ('Pharmacie Mvan Centre', 'pharmacie-mvan-centre', (SELECT id FROM quartiers WHERE slug='mvan'), 'Centre Mvan', 3.8565, 11.4965, '+237 222 21 99 00', 'non_verifie', 'admin'),
    ('Pharmacie de l''Espérance Mvan', 'pharmacie-de-l-esperance-mvan', (SELECT id FROM quartiers WHERE slug='mvan'), 'Avenue de l''Espérance, Mvan', 3.8545, 11.4955, '+237 222 21 22 33', 'non_verifie', 'admin'),
    ('Pharmacie Jeunesse', 'pharmacie-jeunesse', (SELECT id FROM quartiers WHERE slug='mvan'), 'Quartier Jeunesse, Mvan', 3.8590, 11.4990, '+237 222 21 44 55', 'non_verifie', 'admin'),
    ('Pharmacie le Progrès Mvan', 'pharmacie-le-progres-mvan', (SELECT id FROM quartiers WHERE slug='mvan'), 'Rue du Progrès, Mvan', 3.8555, 11.4970, '+237 222 21 66 77', 'non_verifie', 'admin'),
    ('Pharmacie Bien-Être Mvan', 'pharmacie-bien-etre-mvan', (SELECT id FROM quartiers WHERE slug='mvan'), 'Mvan Nord', 3.8585, 11.4985, '+237 222 21 88 99', 'non_verifie', 'admin'),
    ('Pharmacie Soleil Mvan', 'pharmacie-soleil-mvan', (SELECT id FROM quartiers WHERE slug='mvan'), 'Mvan Est', 3.8570, 11.4995, '+237 222 21 11 33', 'non_verifie', 'admin')
ON CONFLICT (slug) DO NOTHING;

-- Pharmacies Ngousso (5)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie de Ngousso', 'pharmacie-de-ngousso', (SELECT id FROM quartiers WHERE slug='ngousso'), 'Carrefour Ngousso', 3.8900, 11.5250, '+237 222 25 11 22', 'non_verifie', 'admin'),
    ('Pharmacie Nouvelle Ngousso', 'pharmacie-nouvelle-ngousso', (SELECT id FROM quartiers WHERE slug='ngousso'), 'Avenue Ngousso', 3.8915, 11.5265, '+237 222 25 33 44', 'non_verifie', 'admin'),
    ('Pharmacie la Grâce Ngousso', 'pharmacie-la-grace-ngousso', (SELECT id FROM quartiers WHERE slug='ngousso'), 'Ngousso Centre', 3.8905, 11.5255, '+237 222 25 55 66', 'non_verifie', 'admin'),
    ('Pharmacie Avenir Ngousso', 'pharmacie-avenir-ngousso', (SELECT id FROM quartiers WHERE slug='ngousso'), 'Ngousso Sud', 3.8890, 11.5240, '+237 222 25 77 88', 'non_verifie', 'admin'),
    ('Pharmacie Développement Ngousso', 'pharmacie-developpement-ngousso', (SELECT id FROM quartiers WHERE slug='ngousso'), 'Ngousso Nord', 3.8920, 11.5270, '+237 222 25 99 00', 'non_verifie', 'admin')
ON CONFLICT (slug) DO NOTHING;

-- Pharmacie Odza (1)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie de l''Aéroport', 'pharmacie-de-l-aeroport', (SELECT id FROM quartiers WHERE slug='odza'), 'Route de l''Aéroport, Odza', 3.8380, 11.5520, '+237 222 24 11 22', 'non_verifie', 'admin')
ON CONFLICT (slug) DO NOTHING;

-- Pharmacie Nlongkak (1)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie la Moderne Nlongkak', 'pharmacie-la-moderne-nlongkak', (SELECT id FROM quartiers WHERE slug='nlongkak'), 'Carrefour Nlongkak', 3.8780, 11.5120, '+237 222 26 11 22', 'non_verifie', 'admin')
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

-- Stocks de démonstration (6 pharmacies × 5 médicaments)
DO $$
DECLARE
    ph_ids UUID[];
    med_ids UUID[];
    prix INTEGER[] := ARRAY[1200, 1500, 1800, 2500, 3500, 2000, 4500, 3000, 1800, 2200,
                            1100, 1600, 1900, 2300, 3200, 2100, 4200, 2800, 1700, 2400,
                            1300, 1450, 1750, 2600, 3600, 1950, 4800, 3100, 1850, 2150];
    i INTEGER;
    j INTEGER;
    idx INTEGER := 1;
BEGIN
    SELECT array_agg(id ORDER BY nom) INTO ph_ids FROM pharmacies LIMIT 6;
    SELECT array_agg(id ORDER BY nom) INTO med_ids FROM medicaments LIMIT 5;

    FOR i IN 1..6 LOOP
        FOR j IN 1..5 LOOP
            INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock, source)
            VALUES (ph_ids[i], med_ids[j], prix[idx], true, 'admin')
            ON CONFLICT (pharmacie_id, medicament_id) DO NOTHING;
            idx := idx + 1;
        END LOOP;
    END LOOP;
END $$;

-- ============================================================
-- ÉTAPE 5 : PHARMACIES DE GARDE (pour tester la fonctionnalité)
-- ============================================================
UPDATE pharmacies SET est_de_garde = true, garde_jusqu_a = now() + interval '24 hours'
WHERE slug IN (
    'pharmacie-du-centre',
    'pharmacie-de-bastos',
    'pharmacie-d-essos',
    'pharmacie-du-campus',
    'pharmacie-de-ngousso'
);

-- ============================================================
-- VÉRIFICATION FINALE
-- ============================================================
DO $$
DECLARE
    n_quartiers INTEGER;
    n_pharmacies INTEGER;
    n_medicaments INTEGER;
    n_stocks INTEGER;
    n_garde INTEGER;
BEGIN
    SELECT count(*) INTO n_quartiers FROM quartiers;
    SELECT count(*) INTO n_pharmacies FROM pharmacies;
    SELECT count(*) INTO n_medicaments FROM medicaments;
    SELECT count(*) INTO n_stocks FROM stocks;
    SELECT count(*) INTO n_garde FROM pharmacies WHERE est_de_garde = true;
    RAISE NOTICE '✅ Setup terminé : % quartiers, % pharmacies (% de garde), % médicaments, % stocks',
        n_quartiers, n_pharmacies, n_garde, n_medicaments, n_stocks;
END $$;
