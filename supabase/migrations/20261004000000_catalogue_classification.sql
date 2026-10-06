-- ============================================================
-- N'Gola Pharma — PR 1 (1/3) : catalogue de médicaments et classification réglementaire
-- SPEC 1 §5bis/§6, SPEC 2 §4.0. PRODUCTION : à exécuter à la main, après relecture, APRÈS la migration de
-- fusion 20261003100000 (la fusion refuse de tourner si une clé étrangère vers `medicaments` qu'elle ne
-- gère pas existe déjà, ce qui est le cas ici : alias_medicaments).
--
-- On ÉTEND `medicaments` (pas de nouvelle table `drug_catalog`) : l'Espace Pro et le site public continuent
-- de fonctionner. La vue `drug_catalog` (noms de la spec, lecture seule) en est la vue de compatibilité.
-- Correspondance spec -> dépôt : voir docs/specs/NOMS-FR.md.
--
-- CLASSIFICATION : ce script n'en décide AUCUNE. Toutes les lignes existantes sont `restreint = true` et non
-- validées (comportement sûr : jamais routées automatiquement). Les médicaments actuels sont le catalogue de
-- TEST : ils sont marqués `est_demo = true`. Leur `restreint` ne passe à `false` que par décision du
-- propriétaire (démo) ou validation d'un pharmacien (production), via valider_classification().
-- ============================================================
BEGIN;

-- ── 1. Colonnes du catalogue ──────────────────────────────────────────
-- `ordonnance` (existant) tient lieu de `requires_prescription` ; aucune donnée d'ordonnance n'est collectée.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = 'medicaments' AND column_name = 'est_demo') THEN
        ALTER TABLE public.medicaments
            ADD COLUMN est_demo boolean NOT NULL DEFAULT false,
            ADD COLUMN restreint boolean NOT NULL DEFAULT true,
            ADD COLUMN classification_validee_le timestamptz,
            ADD COLUMN validation_classification_id uuid,
            ADD COLUMN statut_catalogue text NOT NULL DEFAULT 'actif'
                CHECK (statut_catalogue IN ('actif', 'archive'));
        -- Une seule fois : les fiches présentes aujourd'hui sont le catalogue de test.
        UPDATE public.medicaments SET est_demo = true;
    END IF;
END $$;

-- ── 2. Validation pharmacien (SPEC 2 §4.0) ────────────────────────────
CREATE TABLE IF NOT EXISTS public.validations_classification (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    valide_par_nom  text NOT NULL CHECK (char_length(btrim(valide_par_nom)) > 0),
    numero_ordre    text NOT NULL CHECK (char_length(btrim(numero_ordre)) > 0),   -- n° d'Ordre du pharmacien validateur
    valide_le       timestamptz NOT NULL DEFAULT now(),
    portee          jsonb NOT NULL,                                               -- ids du catalogue + valeurs validées
    document_ref    text,
    enregistre_par  uuid                                                          -- admin qui a saisi la validation
);
ALTER TABLE public.validations_classification ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin lit les validations de classification" ON public.validations_classification;
DROP POLICY IF EXISTS "Admin enregistre une validation de classification" ON public.validations_classification;
CREATE POLICY "Admin lit les validations de classification" ON public.validations_classification
    FOR SELECT USING (auth_role() = 'admin');
CREATE POLICY "Admin enregistre une validation de classification" ON public.validations_classification
    FOR INSERT WITH CHECK (auth_role() = 'admin');
-- Pas de UPDATE ni de DELETE : une validation est une trace d'audit.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'medicaments_validation_classification_fkey') THEN
        ALTER TABLE public.medicaments
            ADD CONSTRAINT medicaments_validation_classification_fkey
            FOREIGN KEY (validation_classification_id) REFERENCES public.validations_classification(id);
    END IF;
END $$;

-- Toute modification des indicateurs d'une ligne remet sa validation à zéro, sauf si la même écriture
-- enregistre une nouvelle validation (cas de valider_classification).
CREATE OR REPLACE FUNCTION public.medicaments_reset_validation()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF (NEW.restreint IS DISTINCT FROM OLD.restreint OR NEW.ordonnance IS DISTINCT FROM OLD.ordonnance)
       AND NEW.classification_validee_le IS NOT DISTINCT FROM OLD.classification_validee_le THEN
        NEW.classification_validee_le := NULL;
        NEW.validation_classification_id := NULL;
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_medicaments_reset_validation ON public.medicaments;
CREATE TRIGGER trg_medicaments_reset_validation
    BEFORE UPDATE ON public.medicaments
    FOR EACH ROW EXECUTE FUNCTION public.medicaments_reset_validation();

-- Enregistre la validation d'un pharmacien pour une liste de médicaments.
--   p_elements : [{"medicament_id": "<uuid>", "restreint": true|false, "ordonnance": true|false}, ...]
-- Fonction exécutée avec les droits de l'appelant : seul un admin (RLS) peut l'utiliser.
CREATE OR REPLACE FUNCTION public.valider_classification(
    p_nom text, p_numero_ordre text, p_elements jsonb, p_document_ref text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
    v_id uuid;
    el jsonb;
BEGIN
    IF p_elements IS NULL OR jsonb_typeof(p_elements) <> 'array' OR jsonb_array_length(p_elements) = 0 THEN
        RAISE EXCEPTION 'Liste de médicaments à valider vide ou invalide';
    END IF;
    FOR el IN SELECT * FROM jsonb_array_elements(p_elements) LOOP
        IF NOT (el ? 'medicament_id' AND el ? 'restreint' AND el ? 'ordonnance')
           OR jsonb_typeof(el->'restreint') <> 'boolean' OR jsonb_typeof(el->'ordonnance') <> 'boolean' THEN
            RAISE EXCEPTION 'Chaque élément doit contenir medicament_id, restreint (booléen) et ordonnance (booléen) : %', el;
        END IF;
    END LOOP;

    INSERT INTO public.validations_classification (valide_par_nom, numero_ordre, portee, document_ref, enregistre_par)
    VALUES (p_nom, p_numero_ordre, p_elements, p_document_ref, auth.uid())
    RETURNING id INTO v_id;

    FOR el IN SELECT * FROM jsonb_array_elements(p_elements) LOOP
        UPDATE public.medicaments
        SET restreint = (el->>'restreint')::boolean,
            ordonnance = (el->>'ordonnance')::boolean,
            classification_validee_le = now(),
            validation_classification_id = v_id
        WHERE id = (el->>'medicament_id')::uuid;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Médicament introuvable (ou non modifiable par cet utilisateur) : %', el->>'medicament_id';
        END IF;
    END LOOP;
    RETURN v_id;
END;
$$;

-- ── 3. Alias de noms et demandes d'ajout au catalogue (SPEC 1 §5.1) ───
CREATE TABLE IF NOT EXISTS public.alias_medicaments (
    alias_normalise text NOT NULL,
    medicament_id   uuid NOT NULL REFERENCES public.medicaments(id) ON DELETE CASCADE,
    PRIMARY KEY (alias_normalise, medicament_id)
);
CREATE INDEX IF NOT EXISTS idx_alias_medicaments_trgm ON public.alias_medicaments USING gin (alias_normalise gin_trgm_ops);
ALTER TABLE public.alias_medicaments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Alias lisibles par tous" ON public.alias_medicaments;
DROP POLICY IF EXISTS "Alias modifiables par admin" ON public.alias_medicaments;
CREATE POLICY "Alias lisibles par tous" ON public.alias_medicaments FOR SELECT USING (true);
CREATE POLICY "Alias modifiables par admin" ON public.alias_medicaments FOR ALL
    USING (auth_role() = 'admin') WITH CHECK (auth_role() = 'admin');

CREATE TABLE IF NOT EXISTS public.demandes_catalogue (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    pharmacie_id   uuid NOT NULL REFERENCES public.pharmacies(id) ON DELETE CASCADE,
    nom_brut       text NOT NULL CHECK (char_length(btrim(nom_brut)) BETWEEN 1 AND 200),
    dosage_brut    text CHECK (dosage_brut IS NULL OR char_length(dosage_brut) <= 100),
    statut         text NOT NULL DEFAULT 'ouverte' CHECK (statut IN ('ouverte', 'traitee', 'refusee')),
    created_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.demandes_catalogue ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Pharmacien voit ses demandes d'ajout" ON public.demandes_catalogue;
DROP POLICY IF EXISTS "Pharmacien crée une demande d'ajout" ON public.demandes_catalogue;
DROP POLICY IF EXISTS "Admin gère les demandes d'ajout" ON public.demandes_catalogue;
CREATE POLICY "Pharmacien voit ses demandes d'ajout" ON public.demandes_catalogue FOR SELECT
    USING (auth_role() = 'pharmacien' AND pharmacie_id = auth_pharmacie_id());
CREATE POLICY "Pharmacien crée une demande d'ajout" ON public.demandes_catalogue FOR INSERT
    WITH CHECK (auth_role() = 'pharmacien' AND pharmacie_id = auth_pharmacie_id() AND statut = 'ouverte');
CREATE POLICY "Admin gère les demandes d'ajout" ON public.demandes_catalogue FOR ALL
    USING (auth_role() = 'admin') WITH CHECK (auth_role() = 'admin');

-- ── 4. Vue de compatibilité (noms de la spec, lecture seule) ──────────
CREATE OR REPLACE VIEW public.drug_catalog WITH (security_invoker = true) AS
SELECT m.id,
       m.dci,
       m.nom_commercial AS brand_name,
       m.dosage AS strength,
       m.forme AS form,
       NULL::text AS pack_size,
       m.ordonnance AS requires_prescription,
       m.restreint AS restricted,
       m.classification_validee_le AS classification_validated_at,
       m.est_demo AS is_demo,
       m.validation_classification_id AS classification_validation_id,
       m.statut_catalogue AS status
FROM public.medicaments m;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.drug_catalog FROM PUBLIC, anon, authenticated;

COMMIT;
