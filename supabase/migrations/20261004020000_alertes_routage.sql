-- ============================================================
-- N'Gola Pharma — PR 1 (3/3) : alertes, routage, outbox, configuration, verrou de production
-- SPEC 2 §4.0, §4.0bis, §8. PRODUCTION : à exécuter à la main, après relecture, après 20261004010000.
--
-- Noms français (voir docs/specs/NOMS-FR.md). L'ancienne table `alertes_stock` (alertes de stock du site public)
-- n'est PAS modifiée : le routage a ses propres tables (`alertes_routage`, `envois_alerte`, ...).
--
-- Accès (SPEC 2 §8) :
--   - la pharmacie ne lit JAMAIS `alertes_routage` : elle passe par `vue_alertes_pharmacie` (médicament, quartier,
--     heure, urgence, sans aucune donnée patient) ;
--   - contact patient chiffré, adresse chiffrée de l'outbox, jetons Telegram : serveur uniquement (service role) ;
--   - configuration, liste de blocage, validations : admin.
-- Aucun envoi réel n'est créé par cette migration.
-- ============================================================
BEGIN;

-- ── 1. Configuration du routage ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.config_routage (
    cle           text PRIMARY KEY,
    valeur        jsonb NOT NULL,
    mis_a_jour_par uuid,
    mis_a_jour_le timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.config_routage ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin gère la configuration du routage" ON public.config_routage;
CREATE POLICY "Admin gère la configuration du routage" ON public.config_routage FOR ALL
    USING (auth_role() = 'admin') WITH CHECK (auth_role() = 'admin');

-- Valeurs initiales (SPEC 2 §8, §4.2). Ne remplace jamais une valeur déjà modifiée par l'admin.
-- `score_poids` reprend le tableau du §4.2 ; `budget_messages_jour` n'a pas de valeur dans la spec : 50 est un
-- plafond provisoire à ajuster par l'admin.
INSERT INTO public.config_routage (cle, valeur) VALUES
    ('vague1_taille',                 '3'),
    ('vague2_taille',                 '5'),
    ('vague2_delai_min',              '10'),
    ('escalade_min',                  '30'),
    ('expiration_min',                '120'),
    ('fenetre_agregation_s',          '120'),
    ('max_envois_par_heure',          '6'),
    ('rupture_recente_jours',         '3'),
    ('facteur_delai_urgent',          '0.5'),
    ('relance_sms_apres_min',         '5'),
    ('max_contacts_telegram_par_pharmacie', '3'),
    ('budget_messages_jour',          '50'),
    ('mode_application',              '"demo"'),
    ('facteur_temps_demo',            '1'),
    ('fournisseur_telegram_reel',     'false'),
    ('score_poids', '{"stock_confirme_3j":40,"stock_confirme_7j":30,"aucun_enregistrement":15,"stock_perime":10,
                      "meme_quartier":30,"quartier_adjacent":15,"autre_quartier":5,"taux_reponse_max":20,
                      "garde_hors_horaires":10,"penalite_par_demande_au_dela_de_3":-5}')
ON CONFLICT (cle) DO NOTHING;

-- ── 2. Médicament routable (SPEC 2 §4.0 / §4.0bis) ────────────────────
-- Routable si : actif, NON restreint, et (classification validée par un pharmacien, OU mode démo + fiche de démo).
-- Une classification absente = restreint (colonne `restreint` à true par défaut) : comportement sûr.
CREATE OR REPLACE FUNCTION public.mode_application()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT COALESCE((SELECT valeur #>> '{}' FROM public.config_routage WHERE cle = 'mode_application'), 'demo') $$;

CREATE OR REPLACE FUNCTION public.medicament_routable(p_medicament_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
    SELECT COALESCE((
        SELECT m.statut_catalogue = 'actif'
           AND NOT m.restreint
           AND (m.classification_validee_le IS NOT NULL
                OR (m.est_demo AND public.mode_application() = 'demo'))
        FROM public.medicaments m WHERE m.id = p_medicament_id
    ), false)
$$;

-- Pharmacie éligible (filtres éliminatoires 1 et 2 du §4.1 qui dépendent des données d'onboarding) :
-- vérifiée, publiée, et au moins un contact avec consentement, non désabonné.
-- Les horaires, le cooldown et les stocks restent évalués par le moteur de routage (PR 3).
CREATE OR REPLACE FUNCTION public.pharmacie_eligible_routage(p_pharmacie_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
    SELECT COALESCE((SELECT p.statut = 'verifie' AND p.est_publiee FROM public.pharmacies p WHERE p.id = p_pharmacie_id), false)
       AND EXISTS (SELECT 1 FROM public.contacts_pharmacie c
                   WHERE c.pharmacie_id = p_pharmacie_id AND c.desabonne_le IS NULL)
$$;
REVOKE ALL ON FUNCTION public.mode_application(), public.medicament_routable(uuid), public.pharmacie_eligible_routage(uuid)
    FROM PUBLIC, anon;

-- ── 3. Conditions de passage en production (SPEC 2 §4.0bis) ───────────
-- (a) validation pharmacien existante  (b) plus de fiche de démo active ni de pharmacie de démo publiée
-- (c) au moins une pharmacie réelle vérifiée  (d) fournisseur Telegram réel déclaré configuré (clé de config,
-- posée par le déploiement : le secret lui-même reste en variable d'environnement).
CREATE OR REPLACE FUNCTION public.conditions_passage_production()
RETURNS TABLE (cle text, ok boolean, detail text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    n int;
BEGIN
    -- Réservé à l'admin (ou au serveur : auth.uid() nul).
    IF auth.uid() IS NOT NULL AND auth_role() <> 'admin' THEN
        RAISE EXCEPTION 'Réservé à l''administrateur' USING ERRCODE = '42501';
    END IF;

    SELECT count(*) INTO n FROM public.validations_classification;
    cle := 'validation_pharmacien'; ok := n > 0;
    detail := n || ' validation(s) enregistrée(s)'; RETURN NEXT;

    SELECT count(*) INTO n FROM public.medicaments WHERE est_demo AND statut_catalogue = 'actif';
    cle := 'catalogue_demo_retire'; ok := n = 0;
    detail := n || ' fiche(s) de démonstration encore active(s)'; RETURN NEXT;

    SELECT count(*) INTO n FROM public.pharmacies WHERE est_demo AND est_publiee;
    cle := 'pharmacies_demo_depubliees'; ok := n = 0;
    detail := n || ' pharmacie(s) de démonstration encore publiée(s)'; RETURN NEXT;

    SELECT count(*) INTO n FROM public.pharmacies WHERE NOT est_demo AND statut = 'verifie';
    cle := 'pharmacie_reelle_verifiee'; ok := n > 0;
    detail := n || ' pharmacie(s) réelle(s) vérifiée(s)'; RETURN NEXT;

    cle := 'fournisseur_telegram_reel';
    ok := COALESCE((SELECT valeur = 'true'::jsonb FROM public.config_routage WHERE config_routage.cle = 'fournisseur_telegram_reel'), false);
    detail := CASE WHEN ok THEN 'déclaré configuré' ELSE 'non configuré' END; RETURN NEXT;
END;
$$;
REVOKE ALL ON FUNCTION public.conditions_passage_production() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.conditions_passage_production() TO authenticated;

-- Verrou : la clé `mode_application` n'accepte que demo|production, et le passage à `production` est refusé
-- tant que toutes les conditions ne sont pas remplies. Vaut pour tous les rôles (admin, service role, SQL Editor).
CREATE OR REPLACE FUNCTION public.config_routage_verrou()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    manquantes text;
BEGIN
    IF NEW.cle = 'mode_application' THEN
        IF NEW.valeur NOT IN ('"demo"'::jsonb, '"production"'::jsonb) THEN
            RAISE EXCEPTION 'mode_application doit valoir "demo" ou "production"' USING ERRCODE = '22023';
        END IF;
        IF NEW.valeur = '"production"'::jsonb AND (TG_OP = 'INSERT' OR OLD.valeur IS DISTINCT FROM NEW.valeur) THEN
            SELECT string_agg(c.cle || ' (' || c.detail || ')', ', ') INTO manquantes
            FROM public.conditions_passage_production() c WHERE NOT c.ok;
            IF manquantes IS NOT NULL THEN
                RAISE EXCEPTION 'Passage en production refusé. Conditions non remplies : %', manquantes
                    USING ERRCODE = 'check_violation';
            END IF;
        END IF;
    END IF;
    NEW.mis_a_jour_le := now();
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS config_routage_verrou ON public.config_routage;
CREATE TRIGGER config_routage_verrou BEFORE INSERT OR UPDATE ON public.config_routage
    FOR EACH ROW EXECUTE FUNCTION public.config_routage_verrou();

-- Le verrou ne doit pas pouvoir être contourné en supprimant la ligne (le mode retomberait sur « demo » : sûr),
-- mais on interdit quand même la suppression de la clé.
CREATE OR REPLACE FUNCTION public.config_routage_interdit_suppression_mode()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.cle = 'mode_application' THEN
        RAISE EXCEPTION 'La clé mode_application ne peut pas être supprimée' USING ERRCODE = 'check_violation';
    END IF;
    RETURN OLD;
END;
$$;
DROP TRIGGER IF EXISTS config_routage_pas_de_suppression ON public.config_routage;
CREATE TRIGGER config_routage_pas_de_suppression BEFORE DELETE ON public.config_routage
    FOR EACH ROW EXECUTE FUNCTION public.config_routage_interdit_suppression_mode();

-- ── 4. Alertes de routage ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.alertes_routage (
    id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    id_public                 text NOT NULL UNIQUE,                 -- affiché au patient
    medicament_id             uuid REFERENCES public.medicaments(id),
    requete_brute             text,                                 -- si non reconnu (jamais envoyé aux pharmacies)
    quartier_id               uuid NOT NULL REFERENCES public.quartiers(id),
    lat                       numeric(9,6),
    lng                       numeric(9,6),
    urgence                   text NOT NULL DEFAULT 'normal' CHECK (urgence IN ('normal', 'urgent')),
    statut                    text NOT NULL DEFAULT 'new'
        CHECK (statut IN ('new', 'needs_review', 'routing', 'answered', 'escalated', 'fulfilled', 'expired', 'cancelled')),
    canal_patient             text CHECK (canal_patient IN ('telegram', 'sms', 'none')),
    contact_patient_chiffre   bytea,                                -- chiffré ; serveur uniquement
    empreinte_patient         text NOT NULL,                        -- anti-abus / limitation de débit
    consentement_le           timestamptz,
    vague                     int NOT NULL DEFAULT 0,
    premiere_reponse_positive_le timestamptz,
    cree_le                   timestamptz NOT NULL DEFAULT now(),
    expire_le                 timestamptz NOT NULL,
    CONSTRAINT alertes_routage_medicament_ou_requete CHECK (medicament_id IS NOT NULL OR requete_brute IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_alertes_routage_statut ON public.alertes_routage (statut, expire_le);
CREATE INDEX IF NOT EXISTS idx_alertes_routage_empreinte ON public.alertes_routage (empreinte_patient, cree_le);
ALTER TABLE public.alertes_routage ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin lit les alertes de routage" ON public.alertes_routage;
CREATE POLICY "Admin lit les alertes de routage" ON public.alertes_routage FOR SELECT USING (auth_role() = 'admin');

-- ── 5. Envois, réponses ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.envois_alerte (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    alerte_id      uuid NOT NULL REFERENCES public.alertes_routage(id) ON DELETE CASCADE,
    pharmacie_id   uuid NOT NULL REFERENCES public.pharmacies(id),
    vague          int NOT NULL,
    score          numeric(5,2) NOT NULL,
    detail_score   jsonb NOT NULL,                                  -- pourquoi cette pharmacie (audit, réservé admin)
    code_reponse   text NOT NULL UNIQUE,                            -- code court du lien /r/<code> (secret)
    statut         text NOT NULL DEFAULT 'sent' CHECK (statut IN ('sent', 'responded', 'expired', 'cancelled')),
    envoye_le      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (alerte_id, pharmacie_id)
);
CREATE INDEX IF NOT EXISTS idx_envois_alerte_pharmacie ON public.envois_alerte (pharmacie_id, envoye_le DESC);

CREATE TABLE IF NOT EXISTS public.reponses_alerte (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    envoi_id      uuid NOT NULL UNIQUE REFERENCES public.envois_alerte(id) ON DELETE CASCADE,
    reponse       text NOT NULL CHECK (reponse IN ('available', 'unavailable')),
    prix_fcfa     integer CHECK (prix_fcfa > 0),
    canal         text NOT NULL CHECK (canal IN ('telegram', 'link', 'dashboard', 'admin')),
    repondu_le    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT reponses_alerte_prix_si_disponible CHECK (reponse = 'available' OR prix_fcfa IS NULL)
);

ALTER TABLE public.envois_alerte ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reponses_alerte ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin lit les envois" ON public.envois_alerte;
DROP POLICY IF EXISTS "Pharmacie voit ses envois" ON public.envois_alerte;
DROP POLICY IF EXISTS "Admin lit les réponses" ON public.reponses_alerte;
DROP POLICY IF EXISTS "Pharmacie voit ses réponses" ON public.reponses_alerte;
CREATE POLICY "Admin lit les envois" ON public.envois_alerte FOR SELECT USING (auth_role() = 'admin');
CREATE POLICY "Pharmacie voit ses envois" ON public.envois_alerte FOR SELECT
    USING (auth_role() = 'pharmacien' AND pharmacie_id = auth_pharmacie_id());
CREATE POLICY "Admin lit les réponses" ON public.reponses_alerte FOR SELECT USING (auth_role() = 'admin');
CREATE POLICY "Pharmacie voit ses réponses" ON public.reponses_alerte FOR SELECT
    USING (auth_role() = 'pharmacien' AND EXISTS (
        SELECT 1 FROM public.envois_alerte e WHERE e.id = envoi_id AND e.pharmacie_id = auth_pharmacie_id()));

-- ── 6. Outbox de notifications ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.notifications_outbox (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cle_idempotence   text NOT NULL UNIQUE,
    type_destinataire text NOT NULL CHECK (type_destinataire IN ('pharmacy', 'patient', 'admin')),
    destinataire_ref  uuid,
    canal             text NOT NULL CHECK (canal IN ('telegram', 'sms', 'email')),
    modele            text NOT NULL,
    adresse_chiffree  bytea NOT NULL,                               -- serveur uniquement
    variables         jsonb NOT NULL DEFAULT '{}',
    statut            text NOT NULL DEFAULT 'queued'
        CHECK (statut IN ('queued', 'sent', 'delivered', 'read', 'failed', 'cancelled', 'suppressed_demo')),
    id_message_fournisseur text,
    id_discussion_fournisseur text,                                 -- pour editMessageText (Telegram)
    tentatives        int NOT NULL DEFAULT 0,
    prochaine_tentative_le timestamptz NOT NULL DEFAULT now(),
    derniere_erreur   text,
    cout_estime       numeric(8,4),
    cree_le           timestamptz NOT NULL DEFAULT now(),
    mis_a_jour_le     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_notifications_outbox_file ON public.notifications_outbox (statut, prochaine_tentative_le);
ALTER TABLE public.notifications_outbox ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin lit l'outbox" ON public.notifications_outbox;
CREATE POLICY "Admin lit l'outbox" ON public.notifications_outbox FOR SELECT USING (auth_role() = 'admin');

-- ── 7. Jetons Telegram, liste de blocage ──────────────────────────────
CREATE TABLE IF NOT EXISTS public.jetons_telegram (
    jeton_hash  text PRIMARY KEY,                                   -- jamais le jeton en clair
    objet       text NOT NULL CHECK (objet IN ('pharmacy_contact', 'patient_alert')),
    ref_id      uuid NOT NULL,                                      -- contacts_pharmacie.id ou alertes_routage.id
    expire_le   timestamptz NOT NULL,
    utilise_le  timestamptz
);
ALTER TABLE public.jetons_telegram ENABLE ROW LEVEL SECURITY;      -- aucune politique : service role uniquement

CREATE TABLE IF NOT EXISTS public.patients_bloques (
    empreinte_patient text PRIMARY KEY,
    motif             text,
    cree_le           timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.patients_bloques ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin gère la liste de blocage" ON public.patients_bloques;
CREATE POLICY "Admin gère la liste de blocage" ON public.patients_bloques FOR ALL
    USING (auth_role() = 'admin') WITH CHECK (auth_role() = 'admin');

-- ── 8. Droits : écritures serveur uniquement, colonnes sensibles masquées ──
-- Les rôles du navigateur (anon, authenticated) n'écrivent jamais dans ces tables (service role / Edge Functions).
-- Les colonnes secrètes ou internes sont retirées du SELECT : même un admin connecté depuis le navigateur ne lit
-- ni le contact patient chiffré, ni les adresses de l'outbox, ni les codes de réponse.
REVOKE ALL ON public.alertes_routage, public.envois_alerte, public.reponses_alerte,
              public.notifications_outbox, public.jetons_telegram FROM PUBLIC, anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.config_routage, public.patients_bloques FROM PUBLIC, anon;
REVOKE ALL ON public.config_routage, public.patients_bloques FROM anon;

GRANT SELECT (id, id_public, medicament_id, requete_brute, quartier_id, lat, lng, urgence, statut, canal_patient,
              empreinte_patient, consentement_le, vague, premiere_reponse_positive_le, cree_le, expire_le)
    ON public.alertes_routage TO authenticated;
GRANT SELECT (id, alerte_id, pharmacie_id, vague, statut, envoye_le)
    ON public.envois_alerte TO authenticated;
GRANT SELECT ON public.reponses_alerte TO authenticated;
GRANT SELECT (id, cle_idempotence, type_destinataire, destinataire_ref, canal, modele, variables, statut,
              tentatives, prochaine_tentative_le, derniere_erreur, cout_estime, cree_le, mis_a_jour_le)
    ON public.notifications_outbox TO authenticated;
-- `score`, `detail_score` (autres candidats, motifs d'exclusion) et `code_reponse` (secret du lien /r/<code>) ne sont
-- lisibles par aucun rôle du navigateur : l'admin les consulte via l'API serveur (PR 3).

-- ── 9. Vue anonymisée pour la pharmacie (SPEC 2 §8 « pharmacy_alert_view ») ──
-- Vue exécutée avec les droits de son propriétaire (elle lit `alertes_routage`, interdite à la pharmacie) :
-- le filtre sur auth_pharmacie_id() est la seule porte d'accès. Aucune colonne patient : ni contact, ni
-- empreinte, ni GPS, ni requête brute.
CREATE OR REPLACE VIEW public.vue_alertes_pharmacie AS
SELECT e.id AS envoi_id,
       e.statut AS statut_envoi,
       e.envoye_le,
       a.urgence,
       a.expire_le,
       q.nom AS quartier,
       m.nom AS medicament_nom,
       m.dosage AS medicament_dosage,
       m.forme AS medicament_forme,
       m.ordonnance AS sur_ordonnance
FROM public.envois_alerte e
JOIN public.alertes_routage a ON a.id = e.alerte_id
JOIN public.quartiers q ON q.id = a.quartier_id
JOIN public.medicaments m ON m.id = a.medicament_id
WHERE auth_role() = 'pharmacien' AND e.pharmacie_id = auth_pharmacie_id();
REVOKE ALL ON public.vue_alertes_pharmacie FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.vue_alertes_pharmacie TO authenticated;

COMMIT;
