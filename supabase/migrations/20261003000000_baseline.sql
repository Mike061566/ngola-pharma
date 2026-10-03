-- ============================================================
-- N'Gola Pharma — Baseline du schéma (migration 20261003000000)
--
-- État de référence de la base AU 2026-10-03 : tables, fonctions, triggers, RLS, vues.
-- Issu de supabase/legacy/setup_consolide.sql, avec les correctifs déjà appliqués en production
-- intégrés (supabase/applied/ : profils.pharmacie_id, colonnes protégées de pharmacies,
-- validation et alertes héritées de alertes_stock).
--
--   * Environnement NEUF ou de développement (Supabase local, CI) : appliquée automatiquement.
--   * PRODUCTION : déjà en place — NE PAS rejouer. Comparer d'abord avec
--     supabase/diagnostics/schema_inventory.sql + scripts/compare-schema.js, voir
--     supabase/baseline/README.md.
--
-- Aucune donnée : les données de démonstration sont dans supabase/seed/demo_setup.sql.
-- Les évolutions suivantes sont de nouvelles migrations (ne jamais modifier celle-ci).
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
    canal           TEXT DEFAULT 'email',
    medicament_nom  TEXT NOT NULL,
    medicament_id   UUID REFERENCES medicaments(id),
    quartier_id     UUID REFERENCES quartiers(id),
    created_at      TIMESTAMPTZ DEFAULT now(),
    notified_at     TIMESTAMPTZ,
    active          BOOLEAN DEFAULT true,
    -- Alerte « héritée » (canal whatsapp / ussd de l'ancien formulaire) : jamais contactée
    -- par le système de routage. Posée par le trigger d'insertion. Voir
    -- supabase/fix_alertes_stock_validation.sql.
    heritee         BOOLEAN NOT NULL DEFAULT false,
    CONSTRAINT contact_required CHECK (user_email IS NOT NULL OR user_phone IS NOT NULL),
    CONSTRAINT alertes_stock_canal_check CHECK (canal IN ('email', 'sms', 'whatsapp', 'ussd')),
    CONSTRAINT alertes_stock_email_format CHECK (heritee OR user_email IS NULL
        OR (char_length(user_email) <= 254 AND user_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
    CONSTRAINT alertes_stock_phone_format CHECK (heritee OR user_phone IS NULL OR user_phone ~ '^\+[1-9][0-9]{7,14}$'),
    CONSTRAINT alertes_stock_medicament_nom_len CHECK (heritee OR char_length(btrim(medicament_nom)) BETWEEN 1 AND 120),
    CONSTRAINT alertes_stock_canal_contact CHECK (heritee OR canal IS NULL
        OR (canal = 'email' AND user_email IS NOT NULL)
        OR (canal <> 'email' AND user_phone IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_alertes_stock_active ON alertes_stock(active, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_alertes_stock_email ON alertes_stock(user_email);
CREATE INDEX IF NOT EXISTS idx_alertes_stock_phone ON alertes_stock(user_phone);

-- ── Index pour les contrôles anti-spam ────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_alertes_stock_email_recent ON alertes_stock (lower(user_email), created_at DESC);
CREATE INDEX IF NOT EXISTS idx_alertes_stock_phone_recent ON alertes_stock (user_phone, created_at DESC);

-- ── Trigger : normalisation, marquage « héritée », fusion et limite ───
-- SECURITY DEFINER : le rôle anon n'a pas le droit de lire la table (RLS), le trigger doit
-- pouvoir compter les alertes déjà reçues pour ce contact.
CREATE OR REPLACE FUNCTION alertes_stock_avant_insertion()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    deja_recu INTEGER;
BEGIN
    -- Champs décidés par le serveur, jamais par le client. (canal NULL => pas héritée : COALESCE.)
    NEW.created_at  := now();
    NEW.notified_at := NULL;
    NEW.heritee     := COALESCE(NEW.canal IN ('whatsapp', 'ussd'), false);

    -- Normalisation : le formulaire envoie déjà +237XXXXXXXXX ; on tolère espaces et tirets.
    NEW.user_email := NULLIF(lower(btrim(NEW.user_email)), '');
    NEW.user_phone := NULLIF(regexp_replace(btrim(NEW.user_phone), '[\s.\-]', '', 'g'), '');

    -- Même contact + même médicament sous 30 min : fusionné (aucune erreur côté client).
    IF EXISTS (
        SELECT 1 FROM alertes_stock a
        WHERE a.created_at > now() - interval '30 minutes'
          AND ((NEW.user_email IS NOT NULL AND lower(a.user_email) = NEW.user_email)
            OR (NEW.user_phone IS NOT NULL AND a.user_phone = NEW.user_phone))
          AND (a.medicament_id IS NOT DISTINCT FROM NEW.medicament_id)
          AND lower(btrim(a.medicament_nom)) = lower(btrim(NEW.medicament_nom))
    ) THEN
        RETURN NULL;
    END IF;

    -- Limite : 5 alertes / 24 h par contact (email ou téléphone).
    SELECT count(*) INTO deja_recu
    FROM alertes_stock a
    WHERE a.created_at > now() - interval '24 hours'
      AND ((NEW.user_email IS NOT NULL AND lower(a.user_email) = NEW.user_email)
        OR (NEW.user_phone IS NOT NULL AND a.user_phone = NEW.user_phone));
    IF deja_recu >= 5 THEN
        RAISE EXCEPTION 'Trop d''alertes pour ce contact aujourd''hui. Réessayez demain.'
            USING ERRCODE = '54000';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_alertes_stock_avant_insertion ON alertes_stock;
CREATE TRIGGER trg_alertes_stock_avant_insertion
    BEFORE INSERT ON alertes_stock
    FOR EACH ROW EXECUTE FUNCTION alertes_stock_avant_insertion();

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
    USING (auth_role() = 'pharmacien' AND id = auth_pharmacie_id())
    WITH CHECK (auth_role() = 'pharmacien' AND id = auth_pharmacie_id());

-- Un pharmacien ne peut modifier que telephone, email, site_web, logo_url et horaires :
-- statut, nom, adresse, GPS, garde... restent à l'admin (trigger ci-dessous).
-- Voir supabase/fix_pharmacies_colonnes_protegees.sql.
CREATE OR REPLACE FUNCTION protect_pharmacies_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
    editable CONSTANT text[] := ARRAY['telephone', 'email', 'site_web', 'logo_url', 'horaires', 'updated_at'];
BEGIN
    -- Rôles serveur (postgres, service_role) et admin applicatif : aucune restriction.
    IF current_user NOT IN ('anon', 'authenticated') OR auth_role() = 'admin' THEN
        RETURN NEW;
    END IF;

    IF (to_jsonb(NEW) - editable) IS DISTINCT FROM (to_jsonb(OLD) - editable) THEN
        RAISE EXCEPTION 'Seuls telephone, email, site_web, logo_url et horaires sont modifiables par la pharmacie'
            USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pharmacies_protect ON pharmacies;
CREATE TRIGGER trg_pharmacies_protect BEFORE UPDATE ON pharmacies
    FOR EACH ROW EXECUTE FUNCTION protect_pharmacies_columns();

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
-- (policy d'insertion publique à retirer quand l'Edge Function de création d'alerte existera)
CREATE POLICY "Tout le monde peut créer une alerte" ON alertes_stock FOR INSERT
    TO anon, authenticated WITH CHECK (notified_at IS NULL AND active IS NOT FALSE);
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
