-- ============================================================
-- N'Gola Pharma — Correctif : colonnes de `pharmacies` protégées vis-à-vis du pharmacien
--
-- Faille : la policy « Pharmacien modifie sa pharmacie » (FOR UPDATE, sans WITH CHECK
-- ni limite de colonnes) laissait un pharmacien modifier TOUTES les colonnes de sa
-- pharmacie, dont `statut` (se passer `verifie` / `partenaire`), `nom`, `adresse`,
-- le GPS et `est_de_garde`. SPEC 1 §6 : ces champs relèvent de l'admin.
--
-- Colonnes modifiables par un pharmacien (sa propre pharmacie uniquement) :
--     telephone, email, site_web, logo_url, horaires
-- Toutes les autres colonnes — y compris celles ajoutées plus tard — sont protégées
-- par défaut : nom, slug, quartier_id, adresse, latitude, longitude, coordinates,
-- est_de_garde, garde_jusqu_a, statut, source, note_moyenne, nombre_avis, verified_at,
-- id, created_at. (updated_at est géré par trigger.)
--
-- Mécanisme : trigger BEFORE UPDATE (et non GRANT par colonne : l'admin utilise le même
-- rôle `authenticated`). Sont exemptés : l'admin applicatif (profils.role = 'admin') et
-- les rôles serveur (postgres / service_role : SQL Editor, Edge Functions).
--
-- Idempotent. Aucune donnée n'est lue ni modifiée.
-- Test : supabase/tests/pharmacies_colonnes_protegees.test.sql (pgTAP).
-- ============================================================
BEGIN;

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
CREATE TRIGGER trg_pharmacies_protect
    BEFORE UPDATE ON pharmacies
    FOR EACH ROW EXECUTE FUNCTION protect_pharmacies_columns();

-- Policy : le pharmacien ne met à jour que SA pharmacie, avant comme après modification.
DROP POLICY IF EXISTS "Pharmacien modifie sa pharmacie" ON pharmacies;
CREATE POLICY "Pharmacien modifie sa pharmacie" ON pharmacies FOR UPDATE
    USING (auth_role() = 'pharmacien' AND id = auth_pharmacie_id())
    WITH CHECK (auth_role() = 'pharmacien' AND id = auth_pharmacie_id());

COMMIT;
