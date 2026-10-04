-- ============================================================
-- N'Gola Pharma — PR 5 : réponses des pharmacies, activation Telegram, réglage des canaux
-- SPEC 2 §5 (réponses idempotentes, effets sur le stock), §6.1 (activation par jeton, /stop), §10.
-- PRODUCTION : à exécuter à la main, après relecture, après 20261007000000. Cette migration n'envoie rien.
--
-- Une réponse (Telegram, lien /r/<code>, Espace Pro) passe TOUJOURS par enregistrer_reponse_alerte : une seule réponse
-- comptée par envoi, mise à jour du stock dans la même transaction. Les fonctions « serveur » sont réservées au service
-- role ; les trois fonctions « pharmacie » vérifient le rôle et la pharmacie de l'appelant.
-- ============================================================
BEGIN;

ALTER TABLE public.alertes_routage ADD COLUMN IF NOT EXISTS empreinte_telegram text;     -- HMAC du chat_id (opt-out /stop du patient)
CREATE INDEX IF NOT EXISTS idx_alertes_routage_tg ON public.alertes_routage (empreinte_telegram) WHERE empreinte_telegram IS NOT NULL;
GRANT SELECT (empreinte_telegram) ON public.alertes_routage TO authenticated;

INSERT INTO public.config_routage (cle, valeur) VALUES
    ('prix_max_fcfa',          '10000000'),   -- garde-fou de saisie d'un prix
    ('max_contacts_sms_par_pharmacie', '3'),
    ('jeton_telegram_pharmacie_h', '72')      -- §6.1 : jeton à usage unique, valable 72 h
ON CONFLICT (cle) DO NOTHING;

-- ── 1. Enregistrement d'une réponse (atomique, idempotent) ────────────
-- resultat : enregistree | deja_traitee | expiree | introuvable | prix_invalide
-- `deja_traitee` renvoie la réponse déjà comptée (rejouer une réponse ne duplique rien ; un collègue arrivé trop tard
-- sait qui a répondu et quand).
CREATE OR REPLACE FUNCTION public.enregistrer_reponse_alerte(
    p_envoi_id uuid, p_reponse text, p_prix integer, p_canal text, p_utilisateur uuid DEFAULT NULL)
RETURNS TABLE (resultat text, alerte_id uuid, pharmacie_id uuid, medicament_id uuid, reponse text,
               prix_fcfa integer, repondu_le timestamptz, stock_mis_a_jour boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    e public.envois_alerte%ROWTYPE;
    a public.alertes_routage%ROWTYPE;
    r public.reponses_alerte%ROWTYPE;
    v_prix_max int;
    v_prix int := p_prix;
    v_maj boolean := false;
    v_source public.source_donnee;
BEGIN
    IF p_reponse NOT IN ('available', 'unavailable') THEN RAISE EXCEPTION 'reponse invalide' USING ERRCODE = '22023'; END IF;
    IF p_canal NOT IN ('telegram', 'link', 'dashboard', 'admin') THEN RAISE EXCEPTION 'canal invalide' USING ERRCODE = '22023'; END IF;

    SELECT * INTO e FROM public.envois_alerte WHERE id = p_envoi_id FOR UPDATE;
    IF NOT FOUND THEN RETURN QUERY SELECT 'introuvable'::text, NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::int, NULL::timestamptz, false; RETURN; END IF;
    SELECT * INTO a FROM public.alertes_routage WHERE id = e.alerte_id;

    -- Déjà répondu : on renvoie la réponse comptée, sans rien modifier.
    SELECT * INTO r FROM public.reponses_alerte WHERE envoi_id = p_envoi_id;
    IF FOUND THEN
        RETURN QUERY SELECT 'deja_traitee'::text, a.id, e.pharmacie_id, a.medicament_id, r.reponse, r.prix_fcfa, r.repondu_le, false; RETURN;
    END IF;
    IF e.statut <> 'sent' OR a.statut IN ('expired', 'cancelled', 'fulfilled') OR now() >= a.expire_le THEN
        RETURN QUERY SELECT 'expiree'::text, a.id, e.pharmacie_id, a.medicament_id, NULL::text, NULL::int, NULL::timestamptz, false; RETURN;
    END IF;

    SELECT COALESCE((SELECT (valeur #>> '{}')::int FROM public.config_routage WHERE cle = 'prix_max_fcfa'), 10000000) INTO v_prix_max;
    IF p_reponse = 'unavailable' THEN v_prix := NULL; END IF;
    IF v_prix IS NOT NULL AND (v_prix <= 0 OR v_prix > v_prix_max) THEN
        RETURN QUERY SELECT 'prix_invalide'::text, a.id, e.pharmacie_id, a.medicament_id, NULL::text, NULL::int, NULL::timestamptz, false; RETURN;
    END IF;

    INSERT INTO public.reponses_alerte AS rr (envoi_id, reponse, prix_fcfa, canal) VALUES (p_envoi_id, p_reponse, v_prix, p_canal)
        RETURNING rr.* INTO r;
    UPDATE public.envois_alerte SET statut = 'responded' WHERE id = p_envoi_id;

    -- Effets sur le stock (§5) : Disponible -> en_stock (+ prix si saisi), Indisponible -> rupture ; date de confirmation = maintenant.
    IF a.medicament_id IS NOT NULL THEN
        v_source := CASE WHEN p_canal = 'admin' THEN 'admin' ELSE 'pharmacien' END;
        IF p_reponse = 'available' THEN
            UPDATE public.stocks s SET statut_stock = 'en_stock', prix_fcfa = COALESCE(v_prix, s.prix_fcfa), date_maj = now(),
                   confirme_le = now(), source = v_source, mis_a_jour_par = p_utilisateur
            WHERE s.pharmacie_id = e.pharmacie_id AND s.medicament_id = a.medicament_id;
            v_maj := FOUND;
            IF NOT v_maj AND v_prix IS NOT NULL THEN   -- ligne créée seulement si le prix est connu (prix_fcfa est obligatoire)
                INSERT INTO public.stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock, statut_stock, date_maj, confirme_le, source, mis_a_jour_par)
                VALUES (e.pharmacie_id, a.medicament_id, v_prix, true, 'en_stock', now(), now(), v_source, p_utilisateur);
                v_maj := true;
            END IF;
        ELSE
            UPDATE public.stocks s SET statut_stock = 'rupture', date_maj = now(), confirme_le = now(), source = v_source, mis_a_jour_par = p_utilisateur
            WHERE s.pharmacie_id = e.pharmacie_id AND s.medicament_id = a.medicament_id;
            v_maj := FOUND;
            IF NOT v_maj THEN                          -- rupture confirmée : exclut la pharmacie des prochaines alertes (§4.1) ; prix 0 = inconnu
                INSERT INTO public.stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock, statut_stock, date_maj, confirme_le, source, mis_a_jour_par)
                VALUES (e.pharmacie_id, a.medicament_id, 0, false, 'rupture', now(), now(), v_source, p_utilisateur);
                v_maj := true;
            END IF;
        END IF;
    END IF;

    -- Première réponse positive : l'alerte passe en `answered` (ouvre la fenêtre d'agrégation du planificateur).
    IF p_reponse = 'available' AND a.premiere_reponse_positive_le IS NULL THEN
        UPDATE public.alertes_routage SET premiere_reponse_positive_le = r.repondu_le,
               statut = CASE WHEN statut IN ('new', 'routing', 'escalated') THEN 'answered' ELSE statut END
        WHERE id = a.id;
    END IF;
    RETURN QUERY SELECT 'enregistree'::text, a.id, e.pharmacie_id, a.medicament_id, r.reponse, r.prix_fcfa, r.repondu_le, v_maj;
END;
$$;
REVOKE ALL ON FUNCTION public.enregistrer_reponse_alerte(uuid, text, integer, text, uuid) FROM PUBLIC, anon, authenticated;

-- ── 2. Réponse depuis l'Espace Pro (pharmacien connecté, sa pharmacie seulement) ──
CREATE OR REPLACE FUNCTION public.repondre_alerte(p_envoi_id uuid, p_reponse text, p_prix integer DEFAULT NULL)
RETURNS TABLE (resultat text, reponse text, prix_fcfa integer, repondu_le timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_pharmacie uuid;
    r record;
BEGIN
    IF auth_role() <> 'pharmacien' OR auth_pharmacie_id() IS NULL THEN RAISE EXCEPTION 'Réservé aux pharmaciens' USING ERRCODE = '42501'; END IF;
    SELECT e.pharmacie_id INTO v_pharmacie FROM public.envois_alerte e WHERE e.id = p_envoi_id;
    IF v_pharmacie IS DISTINCT FROM auth_pharmacie_id() THEN RAISE EXCEPTION 'Demande introuvable' USING ERRCODE = '42501'; END IF;
    SELECT * INTO r FROM public.enregistrer_reponse_alerte(p_envoi_id, p_reponse, p_prix, 'dashboard', auth.uid());
    RETURN QUERY SELECT r.resultat, r.reponse, r.prix_fcfa, r.repondu_le;
END;
$$;
REVOKE ALL ON FUNCTION public.repondre_alerte(uuid, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.repondre_alerte(uuid, text, integer) TO authenticated;

-- ── 3. Vue anonymisée de la pharmacie : ajout du prix du stock, de la réponse et de l'heure (colonnes en fin de vue) ──
CREATE OR REPLACE VIEW public.vue_alertes_pharmacie AS
SELECT e.id AS envoi_id, e.statut AS statut_envoi, e.envoye_le, a.urgence, a.expire_le, q.nom AS quartier,
       m.nom AS medicament_nom, m.dosage AS medicament_dosage, m.forme AS medicament_forme, m.ordonnance AS sur_ordonnance,
       s.prix_fcfa AS prix_stock, r.reponse AS reponse, r.prix_fcfa AS prix_repondu, r.repondu_le AS repondu_le
FROM public.envois_alerte e
JOIN public.alertes_routage a ON a.id = e.alerte_id
JOIN public.quartiers q ON q.id = a.quartier_id
JOIN public.medicaments m ON m.id = a.medicament_id
LEFT JOIN public.stocks s ON s.pharmacie_id = e.pharmacie_id AND s.medicament_id = a.medicament_id AND s.statut_stock <> 'rupture' AND s.prix_fcfa > 0
LEFT JOIN public.reponses_alerte r ON r.envoi_id = e.id
WHERE auth_role() = 'pharmacien' AND e.pharmacie_id = auth_pharmacie_id();
REVOKE ALL ON public.vue_alertes_pharmacie FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.vue_alertes_pharmacie TO authenticated;

-- ── 4. Webhook Telegram : résolution du bouton, jeton à usage unique, liaison du contact ──
-- `callback_data` = r:<8 premiers caractères de l'id d'envoi>:a|u ; recherche limitée à la pharmacie de l'expéditeur.
CREATE OR REPLACE FUNCTION public.trouver_envoi_court(p_pharmacie_id uuid, p_court text)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
    SELECT CASE WHEN count(*) = 1 THEN (array_agg(e.id))[1] END
    FROM public.envois_alerte e
    WHERE e.pharmacie_id = p_pharmacie_id AND p_court ~ '^[0-9a-f]{8}$' AND e.id::text LIKE p_court || '-%'
$$;

-- Consomme un jeton : usage unique, non expiré. Atomique (deux /start simultanés : un seul gagne).
CREATE OR REPLACE FUNCTION public.consommer_jeton_telegram(p_hash text)
RETURNS TABLE (objet text, ref_id uuid)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
    UPDATE public.jetons_telegram j SET utilise_le = now()
    WHERE j.jeton_hash = p_hash AND j.utilise_le IS NULL AND j.expire_le > now()
    RETURNING j.objet, j.ref_id
$$;

-- Lie un chat Telegram à un contact de pharmacie créé par activer_telegram_pharmacie (le contact devient « vérifié »).
-- resultat : active | limite_contacts | introuvable
CREATE OR REPLACE FUNCTION public.lier_contact_telegram(p_contact_id uuid, p_chat_id text)
RETURNS TABLE (resultat text, pharmacie_id uuid, pharmacie_nom text, contact_id uuid, est_contact_demo boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    c public.contacts_pharmacie%ROWTYPE;
    v_max int;
    v_existant public.contacts_pharmacie%ROWTYPE;
BEGIN
    SELECT x.* INTO c FROM public.contacts_pharmacie x WHERE x.id = p_contact_id AND x.canal = 'telegram' FOR UPDATE;
    IF NOT FOUND OR p_chat_id !~ '^-?[0-9]{1,20}$' THEN RETURN QUERY SELECT 'introuvable'::text, NULL::uuid, NULL::text, NULL::uuid, false; RETURN; END IF;
    SELECT COALESCE((SELECT (valeur #>> '{}')::int FROM public.config_routage WHERE cle = 'max_contacts_telegram_par_pharmacie'), 3) INTO v_max;

    -- Le même compte est déjà lié à cette pharmacie : on le réactive et on supprime le contact en attente.
    SELECT x.* INTO v_existant FROM public.contacts_pharmacie x
        WHERE x.pharmacie_id = c.pharmacie_id AND x.canal = 'telegram' AND x.adresse = p_chat_id AND x.id <> c.id;
    IF FOUND THEN
        UPDATE public.contacts_pharmacie x SET verifie_le = COALESCE(x.verifie_le, now()), desabonne_le = NULL, bloque_le = NULL WHERE x.id = v_existant.id;
        DELETE FROM public.contacts_pharmacie x WHERE x.id = c.id;
        RETURN QUERY SELECT 'active'::text, v_existant.pharmacie_id, (SELECT p.nom FROM public.pharmacies p WHERE p.id = v_existant.pharmacie_id), v_existant.id, v_existant.est_contact_demo;
        RETURN;
    END IF;
    IF (SELECT count(*) FROM public.contacts_pharmacie x WHERE x.pharmacie_id = c.pharmacie_id AND x.canal = 'telegram'
          AND x.verifie_le IS NOT NULL AND x.desabonne_le IS NULL AND x.bloque_le IS NULL AND x.id <> c.id) >= v_max THEN
        RETURN QUERY SELECT 'limite_contacts'::text, c.pharmacie_id, NULL::text, c.id, false; RETURN;
    END IF;
    UPDATE public.contacts_pharmacie x SET adresse = p_chat_id, verifie_le = now(), desabonne_le = NULL, bloque_le = NULL WHERE x.id = c.id;
    RETURN QUERY SELECT 'active'::text, c.pharmacie_id, (SELECT p.nom FROM public.pharmacies p WHERE p.id = c.pharmacie_id), c.id, c.est_contact_demo;
END;
$$;

-- /stop d'un compte Telegram : tous ses contacts de pharmacie sont désabonnés (les alertes restent visibles dans l'Espace Pro).
CREATE OR REPLACE FUNCTION public.desabonner_telegram(p_chat_id text)
RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
    WITH m AS (UPDATE public.contacts_pharmacie SET desabonne_le = now()
               WHERE canal = 'telegram' AND adresse = p_chat_id AND desabonne_le IS NULL RETURNING 1)
    SELECT count(*)::int FROM m
$$;

REVOKE ALL ON FUNCTION public.trouver_envoi_court(uuid, text), public.consommer_jeton_telegram(text),
    public.lier_contact_telegram(uuid, text), public.desabonner_telegram(text) FROM PUBLIC, anon, authenticated;

-- ── 5. Réglage des canaux depuis l'Espace Pro (pharmacien connecté, sa pharmacie seulement) ──
-- Les contacts sont en lecture seule côté navigateur (PR 1) : ces fonctions sont la seule porte d'écriture.
CREATE OR REPLACE FUNCTION public.activer_telegram_pharmacie(p_consentement boolean)
RETURNS TABLE (contact_id uuid, jeton text, expire_le timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_ph uuid := auth_pharmacie_id();
    v_max int; v_h int; v_jeton text; v_id uuid; v_exp timestamptz;
BEGIN
    IF auth_role() <> 'pharmacien' OR v_ph IS NULL THEN RAISE EXCEPTION 'Réservé aux pharmaciens' USING ERRCODE = '42501'; END IF;
    IF p_consentement IS NOT TRUE THEN RAISE EXCEPTION 'Consentement requis' USING ERRCODE = '22023'; END IF;
    SELECT COALESCE((SELECT (valeur #>> '{}')::int FROM public.config_routage WHERE cle = 'max_contacts_telegram_par_pharmacie'), 3) INTO v_max;
    SELECT COALESCE((SELECT (valeur #>> '{}')::int FROM public.config_routage WHERE cle = 'jeton_telegram_pharmacie_h'), 72) INTO v_h;
    -- Les activations en attente expirées sont purgées ; le plafond compte comptes vérifiés + activations en cours.
    DELETE FROM public.contacts_pharmacie c WHERE c.pharmacie_id = v_ph AND c.canal = 'telegram' AND c.verifie_le IS NULL
        AND NOT EXISTS (SELECT 1 FROM public.jetons_telegram j WHERE j.ref_id = c.id AND j.utilise_le IS NULL AND j.expire_le > now());
    IF (SELECT count(*) FROM public.contacts_pharmacie c WHERE c.pharmacie_id = v_ph AND c.canal = 'telegram' AND c.desabonne_le IS NULL AND c.bloque_le IS NULL) >= v_max THEN
        RAISE EXCEPTION 'Nombre maximal de contacts Telegram atteint' USING ERRCODE = '23514';
    END IF;
    v_jeton := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');       -- 244 bits aléatoires
    v_exp := now() + make_interval(hours => v_h);
    INSERT INTO public.contacts_pharmacie (pharmacie_id, canal, adresse, consentement_le)
        VALUES (v_ph, 'telegram', 'en_attente:' || gen_random_uuid()::text, now()) RETURNING id INTO v_id;
    INSERT INTO public.jetons_telegram (jeton_hash, objet, ref_id, expire_le)
        VALUES (encode(sha256(convert_to(v_jeton, 'UTF8')), 'hex'), 'pharmacy_contact', v_id, v_exp);
    RETURN QUERY SELECT v_id, v_jeton, v_exp;     -- le jeton en clair n'est renvoyé qu'ici ; seule son empreinte est stockée
END;
$$;

CREATE OR REPLACE FUNCTION public.ajouter_contact_sms(p_numero text, p_consentement boolean)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_ph uuid := auth_pharmacie_id(); v_max int; v_id uuid;
BEGIN
    IF auth_role() <> 'pharmacien' OR v_ph IS NULL THEN RAISE EXCEPTION 'Réservé aux pharmaciens' USING ERRCODE = '42501'; END IF;
    IF p_consentement IS NOT TRUE THEN RAISE EXCEPTION 'Consentement requis' USING ERRCODE = '22023'; END IF;
    IF p_numero !~ '^\+[1-9][0-9]{7,14}$' THEN RAISE EXCEPTION 'Numéro invalide (format international, ex. +237600000000)' USING ERRCODE = '22023'; END IF;
    SELECT COALESCE((SELECT (valeur #>> '{}')::int FROM public.config_routage WHERE cle = 'max_contacts_sms_par_pharmacie'), 3) INTO v_max;
    IF (SELECT count(*) FROM public.contacts_pharmacie c WHERE c.pharmacie_id = v_ph AND c.canal = 'sms' AND c.desabonne_le IS NULL) >= v_max THEN
        RAISE EXCEPTION 'Nombre maximal de numéros SMS atteint' USING ERRCODE = '23514';
    END IF;
    INSERT INTO public.contacts_pharmacie (pharmacie_id, canal, adresse, consentement_le) VALUES (v_ph, 'sms', p_numero, now())
        ON CONFLICT (pharmacie_id, canal, adresse) DO UPDATE SET desabonne_le = NULL, consentement_le = now()
        RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;

-- Désabonnement / réabonnement d'un contact de SA pharmacie (réabonnement = nouveau consentement explicite).
CREATE OR REPLACE FUNCTION public.changer_abonnement_contact(p_contact_id uuid, p_abonne boolean)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    IF auth_role() <> 'pharmacien' OR auth_pharmacie_id() IS NULL THEN RAISE EXCEPTION 'Réservé aux pharmaciens' USING ERRCODE = '42501'; END IF;
    UPDATE public.contacts_pharmacie SET desabonne_le = CASE WHEN p_abonne THEN NULL ELSE now() END,
           consentement_le = CASE WHEN p_abonne THEN now() ELSE consentement_le END
    WHERE id = p_contact_id AND pharmacie_id = auth_pharmacie_id();
    IF NOT FOUND THEN RAISE EXCEPTION 'Contact introuvable' USING ERRCODE = '42501'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.activer_telegram_pharmacie(boolean), public.ajouter_contact_sms(text, boolean),
    public.changer_abonnement_contact(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.activer_telegram_pharmacie(boolean), public.ajouter_contact_sms(text, boolean),
    public.changer_abonnement_contact(uuid, boolean) TO authenticated;

COMMIT;
