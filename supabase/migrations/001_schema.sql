-- ============================================================
-- N'Gola Pharma — Schéma Supabase
-- Migration 001 : tables fondamentales
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================
-- 1. QUARTIERS
-- ============================================================
CREATE TABLE quartiers (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nom         TEXT NOT NULL UNIQUE,
    slug        TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE quartiers IS 'Les 7 quartiers de Yaoundé couverts par N''Gola Pharma';

-- ============================================================
-- 2. PHARMACIES
-- ============================================================
CREATE TYPE statut_pharmacie AS ENUM ('non_verifie', 'verifie', 'partenaire');
CREATE TYPE source_donnee    AS ENUM ('scraping', 'terrain', 'pharmacien', 'admin');

CREATE TABLE pharmacies (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nom             TEXT NOT NULL,
    slug            TEXT NOT NULL UNIQUE,
    quartier_id     UUID NOT NULL REFERENCES quartiers(id),

    -- Adresse & géolocalisation
    adresse         TEXT,
    coordinates     GEOGRAPHY(Point, 4326),  -- longitude, latitude (WGS84)
    latitude        DOUBLE PRECISION,
    longitude       DOUBLE PRECISION,

    -- Contact
    telephone       TEXT,
    email           TEXT,
    site_web        TEXT,

    -- Horaires (JSONB pour flexibilité)
    -- Format: {"lun": {"ouv": "08:00", "fer": "20:00"}, "sam": {"ouv": "08:00", "fer": "14:00"}, ...}
    horaires        JSONB DEFAULT '{}',
    est_de_garde    BOOLEAN NOT NULL DEFAULT false,
    garde_jusqu_a   TIMESTAMPTZ,

    -- Métadonnées
    statut          statut_pharmacie NOT NULL DEFAULT 'non_verifie',
    source          source_donnee NOT NULL DEFAULT 'admin',
    logo_url        TEXT,
    note_moyenne    NUMERIC(2,1) DEFAULT 0.0 CHECK (note_moyenne >= 0 AND note_moyenne <= 5),
    nombre_avis     INTEGER DEFAULT 0,

    -- Timestamps
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    verified_at     TIMESTAMPTZ
);

-- Index pour les recherches fréquentes
CREATE INDEX idx_pharmacies_quartier    ON pharmacies(quartier_id);
CREATE INDEX idx_pharmacies_statut      ON pharmacies(statut);
CREATE INDEX idx_pharmacies_garde       ON pharmacies(est_de_garde) WHERE est_de_garde = true;
CREATE INDEX idx_pharmacies_geo         ON pharmacies USING GIST(coordinates);
CREATE INDEX idx_pharmacies_nom_trgm    ON pharmacies USING GIN(nom gin_trgm_ops);

-- Trigger updated_at
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_pharmacies_updated
    BEFORE UPDATE ON pharmacies
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- Sync latitude/longitude → coordinates
CREATE OR REPLACE FUNCTION sync_coordinates()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.latitude IS NOT NULL AND NEW.longitude IS NOT NULL THEN
        NEW.coordinates = ST_SetSRID(ST_MakePoint(NEW.longitude, NEW.latitude), 4326)::geography;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_pharmacies_geo
    BEFORE INSERT OR UPDATE OF latitude, longitude ON pharmacies
    FOR EACH ROW EXECUTE FUNCTION sync_coordinates();

COMMENT ON TABLE pharmacies IS 'Pharmacies enregistrées — statut non_verifie/verifie/partenaire';

-- ============================================================
-- 3. MÉDICAMENTS
-- ============================================================
CREATE TABLE medicaments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nom             TEXT NOT NULL,
    nom_commercial  TEXT,
    dci             TEXT,              -- Dénomination Commune Internationale
    forme           TEXT,              -- comprimé, sirop, injectable…
    dosage          TEXT,              -- ex: "500mg", "200mg/5ml"
    categorie       TEXT,              -- antalgique, antibiotique, anti-inflammatoire…
    ordonnance      BOOLEAN NOT NULL DEFAULT false,
    description     TEXT,
    image_url       TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_medicaments_nom       ON medicaments USING GIN(nom gin_trgm_ops);
CREATE INDEX idx_medicaments_dci       ON medicaments(dci);
CREATE INDEX idx_medicaments_categorie ON medicaments(categorie);

CREATE TRIGGER trg_medicaments_updated
    BEFORE UPDATE ON medicaments
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

COMMENT ON TABLE medicaments IS 'Catalogue de médicaments avec DCI, forme et dosage';

-- ============================================================
-- 4. STOCKS (prix par pharmacie)
-- ============================================================
CREATE TABLE stocks (
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

CREATE INDEX idx_stocks_pharmacie  ON stocks(pharmacie_id);
CREATE INDEX idx_stocks_medicament ON stocks(medicament_id);
CREATE INDEX idx_stocks_prix       ON stocks(prix_fcfa);

COMMENT ON TABLE stocks IS 'Prix et disponibilité d''un médicament dans une pharmacie';

-- ============================================================
-- 5. UTILISATEURS (profil étendu, auth gérée par Supabase Auth)
-- ============================================================
CREATE TABLE profils (
    id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    nom_complet     TEXT,
    telephone       TEXT,
    quartier_id     UUID REFERENCES quartiers(id),
    role            TEXT NOT NULL DEFAULT 'patient' CHECK (role IN ('patient', 'pharmacien', 'admin')),
    pharmacie_id    UUID REFERENCES pharmacies(id),  -- si role = pharmacien
    avatar_url      TEXT,
    langue          TEXT NOT NULL DEFAULT 'fr' CHECK (langue IN ('fr', 'en')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_profils_role       ON profils(role);
CREATE INDEX idx_profils_pharmacie  ON profils(pharmacie_id);

CREATE TRIGGER trg_profils_updated
    BEFORE UPDATE ON profils
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

COMMENT ON TABLE profils IS 'Profil utilisateur étendu — lié à auth.users de Supabase';

-- ============================================================
-- 6. RECHERCHES (analytics)
-- ============================================================
CREATE TABLE recherches (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    terme           TEXT NOT NULL,
    user_id         UUID REFERENCES auth.users(id),
    resultats       INTEGER DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_recherches_terme ON recherches(terme);
CREATE INDEX idx_recherches_date  ON recherches(created_at DESC);

COMMENT ON TABLE recherches IS 'Historique des recherches — analytics produit';

-- ============================================================
-- 7. ROW LEVEL SECURITY (RLS)
-- ============================================================

-- Quartiers : lecture publique
ALTER TABLE quartiers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Quartiers lisibles par tous"
    ON quartiers FOR SELECT USING (true);

-- Pharmacies : lecture publique, écriture admin/pharmacien
ALTER TABLE pharmacies ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Pharmacies lisibles par tous"
    ON pharmacies FOR SELECT USING (true);
CREATE POLICY "Pharmacies modifiables par admin"
    ON pharmacies FOR ALL
    USING (
        EXISTS (SELECT 1 FROM profils WHERE id = auth.uid() AND role = 'admin')
    );
CREATE POLICY "Pharmacien modifie sa pharmacie"
    ON pharmacies FOR UPDATE
    USING (
        EXISTS (SELECT 1 FROM profils WHERE id = auth.uid() AND role = 'pharmacien' AND pharmacie_id = pharmacies.id)
    );

-- Médicaments : lecture publique
ALTER TABLE medicaments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Médicaments lisibles par tous"
    ON medicaments FOR SELECT USING (true);
CREATE POLICY "Médicaments modifiables par admin"
    ON medicaments FOR ALL
    USING (
        EXISTS (SELECT 1 FROM profils WHERE id = auth.uid() AND role = 'admin')
    );

-- Stocks : lecture publique, écriture pharmacien/admin
ALTER TABLE stocks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Stocks lisibles par tous"
    ON stocks FOR SELECT USING (true);
CREATE POLICY "Stocks modifiables par admin"
    ON stocks FOR ALL
    USING (
        EXISTS (SELECT 1 FROM profils WHERE id = auth.uid() AND role = 'admin')
    );
CREATE POLICY "Pharmacien gère ses stocks"
    ON stocks FOR ALL
    USING (
        EXISTS (SELECT 1 FROM profils WHERE id = auth.uid() AND role = 'pharmacien' AND pharmacie_id = stocks.pharmacie_id)
    );

-- Profils : l'utilisateur voit/modifie le sien, admin voit tout
ALTER TABLE profils ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Profil visible par son propriétaire"
    ON profils FOR SELECT
    USING (id = auth.uid() OR EXISTS (SELECT 1 FROM profils p WHERE p.id = auth.uid() AND p.role = 'admin'));
CREATE POLICY "Profil modifiable par son propriétaire"
    ON profils FOR UPDATE
    USING (id = auth.uid());

-- Recherches : insertion par tous, lecture admin
ALTER TABLE recherches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Tout le monde peut rechercher"
    ON recherches FOR INSERT WITH CHECK (true);
CREATE POLICY "Recherches lisibles par admin"
    ON recherches FOR SELECT
    USING (
        EXISTS (SELECT 1 FROM profils WHERE id = auth.uid() AND role = 'admin')
    );

-- ============================================================
-- 8. VUES UTILITAIRES
-- ============================================================

-- Vue : pharmacies avec nom du quartier
CREATE OR REPLACE VIEW v_pharmacies AS
SELECT
    p.*,
    q.nom AS quartier_nom,
    q.slug AS quartier_slug
FROM pharmacies p
JOIN quartiers q ON q.id = p.quartier_id;

-- Vue : prix le plus bas par médicament
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

-- Fonction : pharmacies à proximité (rayon en mètres)
CREATE OR REPLACE FUNCTION pharmacies_proches(
    lat DOUBLE PRECISION,
    lng DOUBLE PRECISION,
    rayon_m INTEGER DEFAULT 3000
)
RETURNS TABLE (
    id UUID,
    nom TEXT,
    adresse TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    distance_m DOUBLE PRECISION,
    est_de_garde BOOLEAN,
    statut statut_pharmacie,
    quartier_nom TEXT
)
LANGUAGE sql STABLE
AS $$
    SELECT
        p.id, p.nom, p.adresse, p.latitude, p.longitude,
        ST_Distance(p.coordinates, ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography) AS distance_m,
        p.est_de_garde, p.statut,
        q.nom AS quartier_nom
    FROM pharmacies p
    JOIN quartiers q ON q.id = p.quartier_id
    WHERE ST_DWithin(
        p.coordinates,
        ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography,
        rayon_m
    )
    ORDER BY distance_m;
$$;
