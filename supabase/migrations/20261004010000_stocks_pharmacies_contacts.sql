-- ============================================================
-- N'Gola Pharma — PR 1 (2/3) : stocks, publication des pharmacies, contacts de messagerie
-- SPEC 1 §1/§6, SPEC 2 §6. PRODUCTION : à exécuter à la main, après relecture, après 20261004000000.
--
-- On ÉTEND `stocks` (la contrainte UNIQUE (pharmacie_id, medicament_id) existe déjà) et `pharmacies`.
-- La vue `stock_items` (noms de la spec, lecture seule) est la vue de compatibilité de `stocks`.
-- Les colonnes existantes (en_stock, date_maj...) restent la source utilisée par l'Espace Pro et le site public :
-- un trigger garde `statut_stock` et `en_stock` cohérents dans les deux sens.
-- ============================================================
BEGIN;

-- ── 1. Pharmacies : « suspendu », publication, démo ───────────────────
-- (la nouvelle valeur n'est pas utilisée dans cette transaction : permis par PostgreSQL ≥ 12)
ALTER TYPE public.statut_pharmacie ADD VALUE IF NOT EXISTS 'suspendu';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = 'pharmacies' AND column_name = 'est_demo') THEN
        ALTER TABLE public.pharmacies
            ADD COLUMN est_demo boolean NOT NULL DEFAULT false,
            ADD COLUMN est_publiee boolean NOT NULL DEFAULT false,
            ADD COLUMN publiee_le timestamptz;
        -- Une seule fois : toutes les pharmacies présentes aujourd'hui sont des pharmacies de test.
        UPDATE public.pharmacies SET est_demo = true;
    END IF;
END $$;

-- Règle : seule une pharmacie `verifie` peut être publiée (donc éligible aux alertes). Les colonnes ajoutées sont
-- réservées à l'admin par défaut (trigger protect_pharmacies_columns) : un pharmacien ne peut pas se publier.
ALTER TABLE public.pharmacies DROP CONSTRAINT IF EXISTS pharmacies_publiee_verifiee;
ALTER TABLE public.pharmacies ADD CONSTRAINT pharmacies_publiee_verifiee
    CHECK (NOT est_publiee OR statut = 'verifie');

-- Avancement de la checklist d'onboarding : table à part (pas dans `pharmacies`, lisible par tous).
CREATE TABLE IF NOT EXISTS public.etat_onboarding_pharmacie (
    pharmacie_id  uuid PRIMARY KEY REFERENCES public.pharmacies(id) ON DELETE CASCADE,
    etat          jsonb NOT NULL DEFAULT '{}',
    mis_a_jour_le timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.etat_onboarding_pharmacie ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Pharmacien voit son onboarding" ON public.etat_onboarding_pharmacie;
DROP POLICY IF EXISTS "Admin gère l'onboarding" ON public.etat_onboarding_pharmacie;
CREATE POLICY "Pharmacien voit son onboarding" ON public.etat_onboarding_pharmacie FOR SELECT
    USING (auth_role() = 'pharmacien' AND pharmacie_id = auth_pharmacie_id());
CREATE POLICY "Admin gère l'onboarding" ON public.etat_onboarding_pharmacie FOR ALL
    USING (auth_role() = 'admin') WITH CHECK (auth_role() = 'admin');

-- ── 2. Stocks : statut détaillé et dernière confirmation ──────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = 'stocks' AND column_name = 'statut_stock') THEN
        ALTER TABLE public.stocks
            ADD COLUMN statut_stock text NOT NULL DEFAULT 'en_stock'
                CHECK (statut_stock IN ('en_stock', 'faible', 'rupture', 'archive')),
            ADD COLUMN confirme_le timestamptz NOT NULL DEFAULT now(),
            ADD COLUMN mis_a_jour_par uuid;
        UPDATE public.stocks SET statut_stock = CASE WHEN en_stock THEN 'en_stock' ELSE 'rupture' END,
                                 confirme_le = date_maj;
    END IF;
END $$;

CREATE OR REPLACE FUNCTION public.stocks_sync_statut()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.statut_stock <> 'en_stock' THEN
            NEW.en_stock := (NEW.statut_stock = 'faible');       -- rupture et archive : indisponible
        ELSIF NOT NEW.en_stock THEN
            NEW.statut_stock := 'rupture';                         -- l'ancien champ en_stock commande
        END IF;
    ELSE
        IF NEW.statut_stock IS DISTINCT FROM OLD.statut_stock THEN
            NEW.en_stock := NEW.statut_stock IN ('en_stock', 'faible');
        ELSIF NEW.en_stock IS DISTINCT FROM OLD.en_stock THEN
            NEW.statut_stock := CASE WHEN NEW.en_stock THEN 'en_stock' ELSE 'rupture' END;
        END IF;
        IF NEW.date_maj IS DISTINCT FROM OLD.date_maj THEN
            NEW.confirme_le := NEW.date_maj;                       -- une mise à jour vaut confirmation
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_stocks_sync_statut ON public.stocks;
CREATE TRIGGER trg_stocks_sync_statut
    BEFORE INSERT OR UPDATE ON public.stocks
    FOR EACH ROW EXECUTE FUNCTION public.stocks_sync_statut();

CREATE INDEX IF NOT EXISTS idx_stocks_confirme_le ON public.stocks (confirme_le);

-- Vue de compatibilité (noms de la spec, lecture seule)
CREATE OR REPLACE VIEW public.stock_items WITH (security_invoker = true) AS
SELECT s.id,
       s.pharmacie_id AS pharmacy_id,
       s.medicament_id AS catalog_id,
       s.prix_fcfa AS price_fcfa,
       CASE s.statut_stock WHEN 'en_stock' THEN 'in_stock' WHEN 'faible' THEN 'low'
                           WHEN 'rupture' THEN 'out' ELSE 'archived' END AS status,
       s.confirme_le AS last_confirmed_at,
       s.mis_a_jour_par AS updated_by
FROM public.stocks s;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.stock_items FROM PUBLIC, anon, authenticated;

-- ── 3. Contacts de messagerie des pharmacies (SPEC 1 §6, SPEC 2 §6) ───
CREATE TABLE IF NOT EXISTS public.contacts_pharmacie (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    pharmacie_id     uuid NOT NULL REFERENCES public.pharmacies(id) ON DELETE CASCADE,
    canal            text NOT NULL CHECK (canal IN ('telegram', 'sms', 'email')),
    adresse          text NOT NULL CHECK (char_length(btrim(adresse)) > 0),   -- chat_id Telegram, numéro E.164 ou email
    est_principal    boolean NOT NULL DEFAULT false,
    consentement_le  timestamptz NOT NULL,                                    -- opt-in horodaté
    verifie_le       timestamptz,
    desabonne_le     timestamptz,
    est_contact_demo boolean NOT NULL DEFAULT false,                          -- liste blanche des envois réels en mode démo
    UNIQUE (pharmacie_id, canal, adresse),
    CONSTRAINT contacts_pharmacie_adresse_sms CHECK (canal <> 'sms' OR adresse ~ '^\+[1-9][0-9]{7,14}$'),
    CONSTRAINT contacts_pharmacie_adresse_email CHECK (canal <> 'email' OR adresse ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);
CREATE INDEX IF NOT EXISTS idx_contacts_pharmacie_pharmacie ON public.contacts_pharmacie (pharmacie_id);
ALTER TABLE public.contacts_pharmacie ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Pharmacien voit ses contacts" ON public.contacts_pharmacie;
DROP POLICY IF EXISTS "Admin gère les contacts" ON public.contacts_pharmacie;
-- Lecture seule pour la pharmacie : les contacts sont créés et vérifiés côté serveur (activation Telegram par
-- jeton, Edge Function), jamais par une écriture directe depuis le navigateur.
CREATE POLICY "Pharmacien voit ses contacts" ON public.contacts_pharmacie FOR SELECT
    USING (auth_role() = 'pharmacien' AND pharmacie_id = auth_pharmacie_id());
CREATE POLICY "Admin gère les contacts" ON public.contacts_pharmacie FOR ALL
    USING (auth_role() = 'admin') WITH CHECK (auth_role() = 'admin');

COMMIT;
