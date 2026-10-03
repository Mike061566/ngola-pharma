-- ============================================================
-- N'Gola Pharma — Correctif : alertes_stock (validation, anti-spam, alertes « héritées »)
--
-- Contexte : le site public insère directement dans `alertes_stock` avec la clé anon
-- (policy `WITH CHECK (true)`) : aucun contrôle de format, aucune limite, n'importe qui
-- peut remplir la table. L'Edge Function de la PR 4 (captcha Turnstile) remplacera cette
-- insertion ; à ce moment-là l'insertion anonyme sera RETIRÉE. D'ici là, ce correctif :
--
--   1. Alertes « héritées » : nouvelle colonne `heritee`. Les alertes canal whatsapp / ussd
--      (existantes ET celles que l'ancien formulaire enverrait encore), ainsi que les lignes
--      existantes non conformes aux nouvelles règles, sont marquées héritées, jamais converties en sms, et ne doivent JAMAIS être contactées par le
--      nouveau système de routage (SPEC 2 : Telegram / SMS / email).
--   2. Validation : format email / téléphone E.164, longueur du nom de médicament,
--      cohérence canal <-> contact. Contraintes NOT VALID : elles s'appliquent aux nouvelles
--      lignes sans faire échouer les lignes existantes ; les lignes héritées en sont exemptées.
--   3. Anti-spam par contact (email ou téléphone) : même contact + même médicament sous
--      30 min = fusionné (ignoré sans erreur) ; au-delà de 5 alertes / 24 h = refusé.
--      La limite par IP et le captcha viendront avec l'Edge Function (PR 4).
--   4. Policy d'insertion : `notified_at` doit être nul à la création.
--
-- Idempotent. Seule écriture de données : l'UPDATE qui marque `heritee` (canal whatsapp/ussd).
-- Test : supabase/tests/database/alertes_stock.test.sql (pgTAP).
-- ============================================================
BEGIN;

ALTER TABLE alertes_stock ADD COLUMN IF NOT EXISTS heritee BOOLEAN NOT NULL DEFAULT false;

-- Héritées : canal whatsapp / ussd, ainsi que toute ligne existante qui ne respecte pas les
-- nouvelles règles (sinon un simple UPDATE admin de `notified_at` serait refusé par les
-- contraintes ci-dessous). Les lignes conformes en email restent actives.
UPDATE alertes_stock SET heritee = true
WHERE heritee = false
  AND (canal IN ('whatsapp', 'ussd')
       OR (user_email IS NOT NULL AND NOT (char_length(user_email) <= 254
              AND user_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'))
       OR (user_phone IS NOT NULL AND user_phone !~ '^\+[1-9][0-9]{7,14}$')
       OR NOT (char_length(btrim(medicament_nom)) BETWEEN 1 AND 120)
       OR NOT (canal IS NULL
               OR (canal = 'email' AND user_email IS NOT NULL)
               OR (canal <> 'email' AND user_phone IS NOT NULL)));

-- ── Contraintes ───────────────────────────────────────────────────────
-- canal : whatsapp / ussd restent autorisés (alertes héritées) ; sms est ajouté.
ALTER TABLE alertes_stock DROP CONSTRAINT IF EXISTS alertes_stock_canal_check;
ALTER TABLE alertes_stock ADD CONSTRAINT alertes_stock_canal_check
    CHECK (canal IN ('email', 'sms', 'whatsapp', 'ussd'));

ALTER TABLE alertes_stock DROP CONSTRAINT IF EXISTS alertes_stock_email_format;
ALTER TABLE alertes_stock ADD CONSTRAINT alertes_stock_email_format
    CHECK (heritee OR user_email IS NULL
           OR (char_length(user_email) <= 254 AND user_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'))
    NOT VALID;

ALTER TABLE alertes_stock DROP CONSTRAINT IF EXISTS alertes_stock_phone_format;
ALTER TABLE alertes_stock ADD CONSTRAINT alertes_stock_phone_format
    CHECK (heritee OR user_phone IS NULL OR user_phone ~ '^\+[1-9][0-9]{7,14}$')
    NOT VALID;

ALTER TABLE alertes_stock DROP CONSTRAINT IF EXISTS alertes_stock_medicament_nom_len;
ALTER TABLE alertes_stock ADD CONSTRAINT alertes_stock_medicament_nom_len
    CHECK (heritee OR char_length(btrim(medicament_nom)) BETWEEN 1 AND 120)
    NOT VALID;

ALTER TABLE alertes_stock DROP CONSTRAINT IF EXISTS alertes_stock_canal_contact;
ALTER TABLE alertes_stock ADD CONSTRAINT alertes_stock_canal_contact
    CHECK (heritee OR canal IS NULL
           OR (canal = 'email' AND user_email IS NOT NULL)
           OR (canal <> 'email' AND user_phone IS NOT NULL))
    NOT VALID;

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
    -- Champs décidés par le serveur, jamais par le client.
    NEW.created_at  := now();
    NEW.notified_at := NULL;
    NEW.heritee     := NEW.canal IN ('whatsapp', 'ussd');

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

-- ── Policy d'insertion publique (à retirer en PR 4) ───────────────────
DROP POLICY IF EXISTS "Tout le monde peut créer une alerte" ON alertes_stock;
CREATE POLICY "Tout le monde peut créer une alerte" ON alertes_stock FOR INSERT
    TO anon, authenticated
    WITH CHECK (notified_at IS NULL AND active IS NOT FALSE);

COMMIT;
