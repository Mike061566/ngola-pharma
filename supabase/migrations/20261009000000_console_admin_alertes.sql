-- ============================================================
-- N'Gola Pharma — PR 6 : console admin des alertes (supervision, actions manuelles, réglages, indicateurs)
-- SPEC 2 §4.0 (revue needs_review), §4.5 (actions admin), §6.2 (budget), §10 (console, indicateurs), §11 (audit).
-- PRODUCTION : à exécuter à la main, après relecture, après 20261008000000. Cette migration n'envoie rien.
--
-- Toutes les fonctions « admin_* » sont réservées au rôle admin (vérifié dans la fonction), journalisées dans
-- `journal_admin_alertes`, et ne contiennent AUCUNE donnée personnelle de patient dans le journal. Les actions qui
-- doivent écrire à quelqu'un (transmission manuelle, refus) déposent un ORDRE exécuté par le planificateur (qui seul
-- détient la clé de chiffrement) : le navigateur ne manipule jamais de contact chiffré.
-- ============================================================
BEGIN;

-- ── 1. Journal d'audit et ordres ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.journal_admin_alertes (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_id  uuid,
    action    text NOT NULL,
    alerte_id uuid REFERENCES public.alertes_routage(id) ON DELETE SET NULL,
    details   jsonb NOT NULL DEFAULT '{}',        -- identifiants et compteurs seulement, jamais de contact ni de texte libre
    cree_le   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_journal_admin_alertes ON public.journal_admin_alertes (alerte_id, cree_le);
ALTER TABLE public.journal_admin_alertes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin lit le journal des alertes" ON public.journal_admin_alertes;
CREATE POLICY "Admin lit le journal des alertes" ON public.journal_admin_alertes FOR SELECT USING (auth_role() = 'admin');
REVOKE ALL ON public.journal_admin_alertes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.journal_admin_alertes TO authenticated;      -- lecture seule ; écriture par les fonctions ci-dessous

CREATE TABLE IF NOT EXISTS public.ordres_admin_alertes (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    alerte_id  uuid NOT NULL REFERENCES public.alertes_routage(id) ON DELETE CASCADE,
    type       text NOT NULL CHECK (type IN ('transmettre', 'refuser')),
    params     jsonb NOT NULL DEFAULT '{}',
    cree_par   uuid,
    cree_le    timestamptz NOT NULL DEFAULT now(),
    traite_le  timestamptz,
    erreur     text
);
CREATE INDEX IF NOT EXISTS idx_ordres_admin_en_attente ON public.ordres_admin_alertes (cree_le) WHERE traite_le IS NULL;
ALTER TABLE public.ordres_admin_alertes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin lit les ordres" ON public.ordres_admin_alertes;
CREATE POLICY "Admin lit les ordres" ON public.ordres_admin_alertes FOR SELECT USING (auth_role() = 'admin');
REVOKE ALL ON public.ordres_admin_alertes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.ordres_admin_alertes TO authenticated;

-- Routage manuel : l'alerte a été transmise par l'admin ; le moteur n'envoie plus de vague automatique (jamais pour
-- un médicament restreint, même si le statut devient `routing`). L'escalade et l'expiration restent automatiques.
ALTER TABLE public.alertes_routage ADD COLUMN IF NOT EXISTS routage_manuel boolean NOT NULL DEFAULT false;
GRANT SELECT (routage_manuel) ON public.alertes_routage TO authenticated;

CREATE OR REPLACE FUNCTION public.exiger_admin() RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$ BEGIN IF auth_role() <> 'admin' THEN RAISE EXCEPTION 'Réservé à l''administrateur' USING ERRCODE = '42501'; END IF; END $$;

CREATE OR REPLACE FUNCTION public.journaliser_admin(p_action text, p_alerte uuid, p_details jsonb DEFAULT '{}')
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$ INSERT INTO public.journal_admin_alertes (admin_id, action, alerte_id, details) VALUES (auth.uid(), p_action, p_alerte, COALESCE(p_details, '{}')) $$;
REVOKE ALL ON FUNCTION public.exiger_admin(), public.journaliser_admin(text, uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- ── 2. Validation des réglages (aucune valeur absurde n'entre dans config_routage) ──
CREATE OR REPLACE FUNCTION public.erreur_valeur_config(p_cle text, p_val jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    spec record;
    n numeric;
    k text;
BEGIN
    -- (clé, type, min, max) : int = entier, num = nombre
    SELECT * INTO spec FROM (VALUES
        ('vague1_taille', 'int', 1, 20), ('vague2_taille', 'int', 1, 50), ('vague2_delai_min', 'num', 0, 1440),
        ('escalade_min', 'num', 0, 1440), ('expiration_min', 'num', 1, 10080), ('fenetre_agregation_s', 'num', 0, 3600),
        ('max_envois_par_heure', 'int', 1, 100), ('rupture_recente_jours', 'num', 0, 365), ('facteur_delai_urgent', 'num', 0.05, 1),
        ('relance_sms_apres_min', 'num', 0, 1440), ('max_contacts_telegram_par_pharmacie', 'int', 1, 10),
        ('budget_messages_jour', 'int', 0, 100000), ('facteur_temps_demo', 'num', 1, 1000), ('worker_lot_taille', 'int', 1, 200),
        ('worker_bail_s', 'int', 10, 3600), ('debit_global_par_s', 'int', 1, 30), ('debit_par_discussion_ms', 'int', 0, 60000),
        ('stock_frais_jours', 'num', 0, 365), ('stock_tolere_jours', 'num', 0, 365), ('rayon_adjacent_km', 'num', 0, 50),
        ('equite_seuil_par_heure', 'int', 0, 100), ('taux_reponse_defaut', 'num', 0, 1), ('decalage_horaire_min', 'int', -720, 840),
        ('alertes_max_par_jour', 'int', 1, 1000), ('fusion_alertes_min', 'num', 0, 1440), ('jeton_telegram_patient_h', 'int', 1, 720),
        ('jeton_telegram_pharmacie_h', 'int', 1, 720), ('prix_max_fcfa', 'int', 1, 1000000000), ('max_contacts_sms_par_pharmacie', 'int', 1, 10)
    ) AS t(cle, type, mini, maxi) WHERE t.cle = p_cle;
    IF FOUND THEN
        IF jsonb_typeof(p_val) <> 'number' THEN RETURN p_cle || ' : un nombre est attendu'; END IF;
        n := (p_val #>> '{}')::numeric;
        IF spec.type = 'int' AND n <> trunc(n) THEN RETURN p_cle || ' : un entier est attendu'; END IF;
        IF n < spec.mini OR n > spec.maxi THEN RETURN p_cle || ' : doit être compris entre ' || spec.mini || ' et ' || spec.maxi; END IF;
        RETURN NULL;
    END IF;
    IF p_cle IN ('mode_application') THEN RETURN NULL;                        -- contrôlé par le verrou de production
    ELSIF p_cle = 'fournisseur_telegram_reel' THEN
        IF jsonb_typeof(p_val) <> 'boolean' THEN RETURN p_cle || ' : true ou false attendu'; END IF; RETURN NULL;
    ELSIF p_cle = 'retry_delais_s' THEN
        IF jsonb_typeof(p_val) <> 'array' OR jsonb_array_length(p_val) NOT BETWEEN 1 AND 10 THEN RETURN p_cle || ' : liste de 1 à 10 délais en secondes'; END IF;
        FOR n IN SELECT (e #>> '{}')::numeric FROM jsonb_array_elements(p_val) e WHERE jsonb_typeof(e) = 'number' LOOP
            IF n < 0 OR n > 86400 THEN RETURN p_cle || ' : chaque délai doit être entre 0 et 86400 s'; END IF;
        END LOOP;
        IF (SELECT count(*) FROM jsonb_array_elements(p_val) e WHERE jsonb_typeof(e) <> 'number') > 0 THEN RETURN p_cle || ' : nombres uniquement'; END IF;
        RETURN NULL;
    ELSIF p_cle = 'score_poids' THEN
        IF jsonb_typeof(p_val) <> 'object' THEN RETURN p_cle || ' : objet attendu'; END IF;
        FOR k IN SELECT jsonb_object_keys(p_val) LOOP
            IF k NOT IN ('stock_confirme_3j','stock_confirme_7j','aucun_enregistrement','stock_perime','meme_quartier','quartier_adjacent',
                         'autre_quartier','taux_reponse_max','garde_hors_horaires','penalite_par_demande_au_dela_de_3') THEN
                RETURN p_cle || ' : critère inconnu « ' || k || ' »'; END IF;
            IF jsonb_typeof(p_val -> k) <> 'number' OR (p_val ->> k)::numeric NOT BETWEEN -100 AND 100 THEN
                RETURN p_cle || ' : « ' || k || ' » doit être un nombre entre -100 et 100'; END IF;
        END LOOP;
        RETURN NULL;
    END IF;
    RETURN 'Clé de configuration inconnue : ' || p_cle;
END;
$$;

CREATE OR REPLACE FUNCTION public.config_routage_valider() RETURNS trigger
LANGUAGE plpgsql SET search_path = public
AS $$
DECLARE v_err text;
BEGIN
    v_err := public.erreur_valeur_config(NEW.cle, NEW.valeur);
    IF v_err IS NOT NULL THEN RAISE EXCEPTION '%', v_err USING ERRCODE = '22023'; END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS config_routage_valider ON public.config_routage;
CREATE TRIGGER config_routage_valider BEFORE INSERT OR UPDATE ON public.config_routage
    FOR EACH ROW EXECUTE FUNCTION public.config_routage_valider();

-- Journal des changements de réglage (qui, quelle clé, avant / après).
CREATE OR REPLACE FUNCTION public.config_routage_journal() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    IF OLD.valeur IS DISTINCT FROM NEW.valeur THEN
        INSERT INTO public.journal_admin_alertes (admin_id, action, details)
        VALUES (auth.uid(), 'config', jsonb_build_object('cle', NEW.cle, 'avant', OLD.valeur, 'apres', NEW.valeur));
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS config_routage_journal ON public.config_routage;
CREATE TRIGGER config_routage_journal AFTER UPDATE ON public.config_routage
    FOR EACH ROW EXECUTE FUNCTION public.config_routage_journal();

-- ── 3. Supervision : file en temps réel, chronologie, indicateurs, budget ──
CREATE OR REPLACE FUNCTION public.file_alertes_admin(p_statuts text[] DEFAULT NULL, p_limite int DEFAULT 100)
RETURNS TABLE (id uuid, id_public text, statut text, raison_revue text, urgence text, medicament text, quartier text,
               cree_le timestamptz, expire_le timestamptz, vague int, routage_manuel boolean, nb_envois int, nb_reponses int,
               nb_positives int, premiere_reponse_positive_le timestamptz, canal_patient text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    PERFORM public.exiger_admin();
    RETURN QUERY
    SELECT a.id, a.id_public, a.statut, a.raison_revue, a.urgence,
           COALESCE(m.nom || COALESCE(' ' || m.dosage, ''), '(non reconnu)'), q.nom, a.cree_le, a.expire_le, a.vague, a.routage_manuel,
           (SELECT count(*)::int FROM public.envois_alerte e WHERE e.alerte_id = a.id),
           (SELECT count(*)::int FROM public.reponses_alerte r JOIN public.envois_alerte e ON e.id = r.envoi_id WHERE e.alerte_id = a.id),
           (SELECT count(*)::int FROM public.reponses_alerte r JOIN public.envois_alerte e ON e.id = r.envoi_id WHERE e.alerte_id = a.id AND r.reponse = 'available'),
           a.premiere_reponse_positive_le, a.canal_patient
    FROM public.alertes_routage a
    JOIN public.quartiers q ON q.id = a.quartier_id
    LEFT JOIN public.medicaments m ON m.id = a.medicament_id
    WHERE p_statuts IS NULL OR a.statut = ANY (p_statuts)
    ORDER BY (a.statut = 'needs_review') DESC, a.cree_le DESC
    LIMIT LEAST(GREATEST(p_limite, 1), 500);
END;
$$;

-- Chronologie d'une alerte : vagues, destinataires, scores, réponses, messages (statut, coût), actions admin.
-- La consultation est JOURNALISÉE (accès admin aux données d'une demande de patient, §11). Aucun contact n'est renvoyé.
CREATE OR REPLACE FUNCTION public.chronologie_alerte(p_alerte_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    a public.alertes_routage%ROWTYPE;
    v_evts jsonb;
    v_cout numeric;
BEGIN
    PERFORM public.exiger_admin();
    SELECT * INTO a FROM public.alertes_routage WHERE id = p_alerte_id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    PERFORM public.journaliser_admin('consultation', a.id, '{}');

    -- À instant égal : création, envois, relances, messages, réponses, puis les repères dérivés, enfin les actions admin.
    SELECT COALESCE(jsonb_agg(ev ORDER BY (ev ->> 't'),
        array_position(ARRAY['creation','envoi','relance_sms','message','reponse','premiere_reponse_positive','escalade','patient_notifie','second_message','action_admin'], ev ->> 'type')),
        '[]'::jsonb) INTO v_evts FROM (
        SELECT jsonb_build_object('t', a.cree_le, 'type', 'creation', 'urgence', a.urgence, 'canal_patient', a.canal_patient) AS ev
        UNION ALL SELECT jsonb_build_object('t', e.envoye_le, 'type', 'envoi', 'envoi_id', e.id, 'pharmacie', p.nom, 'vague', e.vague,
                    'score', e.score, 'detail_score', e.detail_score, 'statut', e.statut)
                  FROM public.envois_alerte e JOIN public.pharmacies p ON p.id = e.pharmacie_id WHERE e.alerte_id = a.id
        UNION ALL SELECT jsonb_build_object('t', e.relance_sms_le, 'type', 'relance_sms', 'pharmacie', p.nom)
                  FROM public.envois_alerte e JOIN public.pharmacies p ON p.id = e.pharmacie_id WHERE e.alerte_id = a.id AND e.relance_sms_le IS NOT NULL
        UNION ALL SELECT jsonb_build_object('t', r.repondu_le, 'type', 'reponse', 'pharmacie', p.nom, 'reponse', r.reponse, 'prix_fcfa', r.prix_fcfa, 'canal', r.canal)
                  FROM public.reponses_alerte r JOIN public.envois_alerte e ON e.id = r.envoi_id JOIN public.pharmacies p ON p.id = e.pharmacie_id WHERE e.alerte_id = a.id
        UNION ALL SELECT jsonb_build_object('t', o.cree_le, 'type', 'message', 'canal', o.canal, 'modele', o.modele, 'statut', o.statut,
                    'destinataire', o.type_destinataire, 'erreur', o.derniere_erreur, 'cout', o.cout_estime)
                  FROM public.notifications_outbox o
                  WHERE o.cle_base LIKE 'alerte:' || a.id::text || ':%' OR o.cle_base IN (SELECT e.id::text FROM public.envois_alerte e WHERE e.alerte_id = a.id)
        UNION ALL SELECT jsonb_build_object('t', a.escalade_le, 'type', 'escalade') WHERE a.escalade_le IS NOT NULL
        UNION ALL SELECT jsonb_build_object('t', a.premiere_reponse_positive_le, 'type', 'premiere_reponse_positive') WHERE a.premiere_reponse_positive_le IS NOT NULL
        UNION ALL SELECT jsonb_build_object('t', a.patient_notifie_le, 'type', 'patient_notifie') WHERE a.patient_notifie_le IS NOT NULL
        UNION ALL SELECT jsonb_build_object('t', a.second_message_le, 'type', 'second_message') WHERE a.second_message_le IS NOT NULL
        UNION ALL SELECT jsonb_build_object('t', j.cree_le, 'type', 'action_admin', 'action', j.action, 'details', j.details)
                  FROM public.journal_admin_alertes j WHERE j.alerte_id = a.id AND j.action <> 'consultation'
    ) x WHERE (ev ->> 't') IS NOT NULL;

    SELECT COALESCE(sum(o.cout_estime), 0) INTO v_cout FROM public.notifications_outbox o
        WHERE o.cle_base LIKE 'alerte:' || a.id::text || ':%' OR o.cle_base IN (SELECT e.id::text FROM public.envois_alerte e WHERE e.alerte_id = a.id);
    RETURN jsonb_build_object(
        'alerte', jsonb_build_object('id', a.id, 'id_public', a.id_public, 'statut', a.statut, 'raison_revue', a.raison_revue, 'urgence', a.urgence,
            'vague', a.vague, 'routage_manuel', a.routage_manuel, 'cree_le', a.cree_le, 'expire_le', a.expire_le, 'canal_patient', a.canal_patient,
            'requete_brute', a.requete_brute,
            'medicament', (SELECT jsonb_build_object('id', m.id, 'nom', m.nom, 'dosage', m.dosage, 'forme', m.forme, 'restreint', m.restreint, 'ordonnance', m.ordonnance)
                           FROM public.medicaments m WHERE m.id = a.medicament_id),
            'quartier', (SELECT q.nom FROM public.quartiers q WHERE q.id = a.quartier_id)),
        'cout_estime_total', v_cout, 'evenements', v_evts);
END;
$$;

CREATE OR REPLACE FUNCTION public.etat_budget_messages()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_plafond int; v_util int;
BEGIN
    PERFORM public.exiger_admin();
    SELECT COALESCE((SELECT (valeur #>> '{}')::int FROM public.config_routage WHERE cle = 'budget_messages_jour'), 50) INTO v_plafond;
    v_util := public.compter_messages_payants_du_jour();
    RETURN jsonb_build_object('utilises', v_util, 'plafond', v_plafond,
        'pourcentage', CASE WHEN v_plafond > 0 THEN round(100.0 * v_util / v_plafond) ELSE NULL END,
        'alerte_80', v_plafond > 0 AND v_util >= 0.8 * v_plafond, 'depasse', v_util >= v_plafond);
END;
$$;

-- Indicateurs de §10 sur les `p_jours` derniers jours.
CREATE OR REPLACE FUNCTION public.indicateurs_alertes(p_jours int DEFAULT 30)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_debut timestamptz := now() - make_interval(days => LEAST(GREATEST(p_jours, 1), 365));
    v_nb int; v_routees int; v_rapides int; v_mediane numeric; v_statuts jsonb; v_pharma jsonb; v_msgs jsonb;
    v_pub int; v_tg int; v_tg_liste jsonb; v_cout numeric; v_payants int; v_sms_repli int; v_tg_total int; v_reponses jsonb;
BEGIN
    PERFORM public.exiger_admin();
    SELECT count(*) INTO v_nb FROM public.alertes_routage WHERE cree_le >= v_debut;
    SELECT COALESCE(jsonb_object_agg(statut, n), '{}') INTO v_statuts FROM (SELECT statut, count(*) AS n FROM public.alertes_routage WHERE cree_le >= v_debut GROUP BY statut) s;

    -- Délai médian jusqu'à la première réponse positive ; part d'alertes routées avec réponse positive sous 15 min
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM (premiere_reponse_positive_le - cree_le)))
        INTO v_mediane FROM public.alertes_routage WHERE cree_le >= v_debut AND premiere_reponse_positive_le IS NOT NULL;
    SELECT count(*), count(*) FILTER (WHERE a.premiere_reponse_positive_le IS NOT NULL AND a.premiere_reponse_positive_le <= a.cree_le + interval '15 minutes')
        INTO v_routees, v_rapides FROM public.alertes_routage a
        WHERE a.cree_le >= v_debut AND EXISTS (SELECT 1 FROM public.envois_alerte e WHERE e.alerte_id = a.id);

    -- Taux de réponse par pharmacie (envois non annulés)
    SELECT COALESCE(jsonb_agg(x ORDER BY (x ->> 'envois')::int DESC), '[]') INTO v_pharma FROM (
        SELECT jsonb_build_object('pharmacie_id', p.id, 'nom', p.nom, 'envois', count(e.id), 'reponses', count(r.id),
                                  'taux', CASE WHEN count(e.id) > 0 THEN round(count(r.id)::numeric / count(e.id), 3) END) AS x
        FROM public.pharmacies p JOIN public.envois_alerte e ON e.pharmacie_id = p.id AND e.envoye_le >= v_debut AND e.statut <> 'cancelled'
        LEFT JOIN public.reponses_alerte r ON r.envoi_id = e.id
        GROUP BY p.id, p.nom ORDER BY count(e.id) DESC LIMIT 50) t;

    -- Activation Telegram : pharmacies publiées avec au moins un compte vérifié, actif
    SELECT count(*) INTO v_pub FROM public.pharmacies WHERE est_publiee;
    SELECT count(*) INTO v_tg FROM public.pharmacies p WHERE p.est_publiee AND EXISTS (
        SELECT 1 FROM public.contacts_pharmacie c WHERE c.pharmacie_id = p.id AND c.canal = 'telegram' AND c.verifie_le IS NOT NULL AND c.desabonne_le IS NULL AND c.bloque_le IS NULL);
    SELECT COALESCE(jsonb_agg(x ORDER BY (x ->> 'comptes_telegram')::int ASC, x ->> 'nom'), '[]') INTO v_tg_liste FROM (
        SELECT jsonb_build_object('pharmacie_id', p.id, 'nom', p.nom, 'comptes_telegram',
            (SELECT count(*) FROM public.contacts_pharmacie c WHERE c.pharmacie_id = p.id AND c.canal = 'telegram' AND c.verifie_le IS NOT NULL AND c.desabonne_le IS NULL AND c.bloque_le IS NULL)) AS x
        FROM public.pharmacies p WHERE p.est_publiee LIMIT 200) t;

    -- Messages : échecs et repli SMS, coût
    SELECT COALESCE(jsonb_object_agg(canal, jsonb_build_object('total', total, 'envoyes', envoyes, 'echecs', echecs,
              'taux_echec', CASE WHEN envoyes + echecs > 0 THEN round(echecs::numeric / (envoyes + echecs), 3) END)), '{}') INTO v_msgs FROM (
        SELECT canal, count(*) FILTER (WHERE statut NOT IN ('cancelled', 'suppressed_demo')) AS total,
               count(*) FILTER (WHERE statut IN ('sent', 'delivered', 'read')) AS envoyes, count(*) FILTER (WHERE statut = 'failed') AS echecs
        FROM public.notifications_outbox WHERE cree_le >= v_debut GROUP BY canal) c;
    SELECT count(*) INTO v_sms_repli FROM public.notifications_outbox WHERE cree_le >= v_debut AND canal = 'sms' AND 'telegram' = ANY (canaux_tentes);
    SELECT count(*) INTO v_tg_total FROM public.notifications_outbox WHERE cree_le >= v_debut AND canal = 'telegram' AND statut NOT IN ('cancelled', 'suppressed_demo');
    SELECT COALESCE(sum(cout_estime), 0), count(*) FILTER (WHERE canal IN ('sms', 'email') AND statut IN ('sent', 'delivered', 'read'))
        INTO v_cout, v_payants FROM public.notifications_outbox WHERE cree_le >= v_debut;

    -- Mises à jour de stock issues des alertes = réponses enregistrées sur un médicament reconnu
    SELECT jsonb_build_object('total', count(*), 'disponible', count(*) FILTER (WHERE r.reponse = 'available'), 'indisponible', count(*) FILTER (WHERE r.reponse = 'unavailable'))
        INTO v_reponses FROM public.reponses_alerte r JOIN public.envois_alerte e ON e.id = r.envoi_id JOIN public.alertes_routage a ON a.id = e.alerte_id
        WHERE r.repondu_le >= v_debut AND a.medicament_id IS NOT NULL;

    RETURN jsonb_build_object(
        'jours', LEAST(GREATEST(p_jours, 1), 365), 'nb_alertes', v_nb, 'par_statut', v_statuts,
        'needs_review_en_attente', (SELECT count(*) FROM public.alertes_routage WHERE statut = 'needs_review'),
        'delai_median_premiere_reponse_s', CASE WHEN v_mediane IS NULL THEN NULL ELSE round(v_mediane) END,
        'alertes_routees', v_routees, 'part_reponse_positive_15min', CASE WHEN v_routees > 0 THEN round(v_rapides::numeric / v_routees, 3) END,
        'taux_reponse_pharmacies', v_pharma,
        'activation_telegram', jsonb_build_object('pharmacies_publiees', v_pub, 'avec_telegram', v_tg,
            'taux', CASE WHEN v_pub > 0 THEN round(v_tg::numeric / v_pub, 3) END, 'par_pharmacie', v_tg_liste),
        'messages', v_msgs,
        'repli_sms', jsonb_build_object('sms_de_repli', v_sms_repli, 'messages_telegram', v_tg_total,
            'taux', CASE WHEN v_tg_total > 0 THEN round(v_sms_repli::numeric / v_tg_total, 3) END),
        'cout', jsonb_build_object('total_estime', v_cout, 'messages_payants', v_payants,
            'moyen_par_alerte', CASE WHEN v_nb > 0 THEN round(v_cout / v_nb, 4) END,
            'messages_payants_par_alerte', CASE WHEN v_nb > 0 THEN round(v_payants::numeric / v_nb, 3) END),
        'mises_a_jour_stock', v_reponses);
END;
$$;

-- ── 4. Actions manuelles (§4.0, §4.5) ────────────────────────────────
-- Rattacher une alerte en revue à un médicament du catalogue. Routable -> l'alerte repart en routage automatique (`new`).
-- Restreint ou non classé -> elle reste en revue (seule la transmission manuelle reste possible).
CREATE OR REPLACE FUNCTION public.admin_rattacher_medicament(p_alerte_id uuid, p_medicament_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    a public.alertes_routage%ROWTYPE; m public.medicaments%ROWTYPE; v_statut text; v_raison text;
BEGIN
    PERFORM public.exiger_admin();
    SELECT * INTO a FROM public.alertes_routage WHERE id = p_alerte_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Alerte introuvable' USING ERRCODE = 'P0002'; END IF;
    IF a.statut <> 'needs_review' THEN RAISE EXCEPTION 'Seule une alerte en revue peut être rattachée' USING ERRCODE = '55000'; END IF;
    SELECT * INTO m FROM public.medicaments WHERE id = p_medicament_id AND statut_catalogue = 'actif';
    IF NOT FOUND THEN RAISE EXCEPTION 'Médicament introuvable ou archivé' USING ERRCODE = 'P0002'; END IF;
    IF public.medicament_routable(m.id) THEN v_statut := 'new'; v_raison := NULL;
    ELSE v_statut := 'needs_review'; v_raison := CASE WHEN m.restreint THEN 'restreint' ELSE 'classification_non_validee' END; END IF;
    UPDATE public.alertes_routage SET medicament_id = m.id, statut = v_statut, raison_revue = v_raison, routage_manuel = false WHERE id = a.id;
    PERFORM public.journaliser_admin('rattacher', a.id, jsonb_build_object('medicament_id', m.id, 'statut', v_statut));
    RETURN v_statut;
END;
$$;

-- Transmettre (ou ajouter) manuellement des pharmacies choisies. Le message part via le planificateur (≤ 1 min) avec le rappel
-- d'ordonnance si besoin. L'alerte passe en `routing` en mode manuel : plus de vague automatique, même pour un médicament restreint.
-- Seules les pharmacies vérifiées, avec un contact actif (et, en production, non « démo ») sont acceptées.
CREATE OR REPLACE FUNCTION public.admin_transmettre(p_alerte_id uuid, p_pharmacie_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    a public.alertes_routage%ROWTYPE; v_ok uuid[] := '{}'; v_refus jsonb := '[]'; pid uuid; p public.pharmacies%ROWTYPE; v_raison text;
BEGIN
    PERFORM public.exiger_admin();
    SELECT * INTO a FROM public.alertes_routage WHERE id = p_alerte_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Alerte introuvable' USING ERRCODE = 'P0002'; END IF;
    IF a.statut IN ('fulfilled', 'expired', 'cancelled') THEN RAISE EXCEPTION 'Alerte terminée' USING ERRCODE = '55000'; END IF;
    IF a.medicament_id IS NULL THEN RAISE EXCEPTION 'Rattachez d''abord l''alerte à un médicament du catalogue' USING ERRCODE = '55000'; END IF;
    IF p_pharmacie_ids IS NULL OR array_length(p_pharmacie_ids, 1) IS NULL OR array_length(p_pharmacie_ids, 1) > 20 THEN
        RAISE EXCEPTION 'Choisissez de 1 à 20 pharmacies' USING ERRCODE = '22023'; END IF;
    FOREACH pid IN ARRAY p_pharmacie_ids LOOP
        v_raison := NULL;
        SELECT * INTO p FROM public.pharmacies WHERE id = pid;
        IF NOT FOUND THEN v_raison := 'introuvable';
        ELSIF p.statut <> 'verifie' THEN v_raison := 'non_verifiee';
        ELSIF public.mode_application() = 'production' AND p.est_demo THEN v_raison := 'demo_en_production';
        ELSIF NOT EXISTS (SELECT 1 FROM public.contacts_pharmacie c WHERE c.pharmacie_id = pid AND c.desabonne_le IS NULL AND c.bloque_le IS NULL
                          AND (c.canal <> 'telegram' OR c.verifie_le IS NOT NULL)) THEN v_raison := 'aucun_contact_actif';
        ELSIF EXISTS (SELECT 1 FROM public.envois_alerte e WHERE e.alerte_id = a.id AND e.pharmacie_id = pid AND e.statut <> 'cancelled') THEN v_raison := 'deja_sollicitee';
        END IF;
        IF v_raison IS NULL THEN v_ok := v_ok || pid; ELSE v_refus := v_refus || jsonb_build_object('pharmacie_id', pid, 'raison', v_raison); END IF;
    END LOOP;
    IF array_length(v_ok, 1) IS NOT NULL THEN
        -- Une pharmacie précédemment retirée (envoi annulé) peut être re-sollicitée : on lève l'annulation côté ordre (le planificateur recrée l'envoi).
        DELETE FROM public.envois_alerte e WHERE e.alerte_id = a.id AND e.pharmacie_id = ANY (v_ok) AND e.statut = 'cancelled';
        INSERT INTO public.ordres_admin_alertes (alerte_id, type, params, cree_par) VALUES (a.id, 'transmettre', jsonb_build_object('pharmacie_ids', to_jsonb(v_ok)), auth.uid());
        UPDATE public.alertes_routage SET routage_manuel = true, vague = GREATEST(vague, 1), debut_routage_le = COALESCE(debut_routage_le, now()),
               statut = CASE WHEN statut IN ('new', 'needs_review') THEN 'routing' ELSE statut END, raison_revue = NULL WHERE id = a.id;
        PERFORM public.journaliser_admin('transmettre', a.id, jsonb_build_object('pharmacies', to_jsonb(v_ok), 'refusees', v_refus));
    END IF;
    RETURN jsonb_build_object('acceptees', COALESCE(array_length(v_ok, 1), 0), 'refusees', v_refus);
END;
$$;

-- Refuser une demande en revue : annulée, le patient reçoit `restricted_refus` (envoyé par le planificateur).
CREATE OR REPLACE FUNCTION public.admin_refuser_alerte(p_alerte_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE a public.alertes_routage%ROWTYPE;
BEGIN
    PERFORM public.exiger_admin();
    SELECT * INTO a FROM public.alertes_routage WHERE id = p_alerte_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Alerte introuvable' USING ERRCODE = 'P0002'; END IF;
    IF a.statut <> 'needs_review' THEN RAISE EXCEPTION 'Seule une alerte en revue peut être refusée' USING ERRCODE = '55000'; END IF;
    UPDATE public.alertes_routage SET statut = 'cancelled' WHERE id = a.id;
    INSERT INTO public.ordres_admin_alertes (alerte_id, type, cree_par) VALUES (a.id, 'refuser', auth.uid());
    PERFORM public.journaliser_admin('refuser', a.id, '{}');
END;
$$;

-- Relancer une vague : on recule d'un cran ; le planificateur renvoie la vague à des pharmacies pas encore sollicitées.
CREATE OR REPLACE FUNCTION public.admin_relancer_vague(p_alerte_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE a public.alertes_routage%ROWTYPE; v_vague int;
BEGIN
    PERFORM public.exiger_admin();
    SELECT * INTO a FROM public.alertes_routage WHERE id = p_alerte_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Alerte introuvable' USING ERRCODE = 'P0002'; END IF;
    IF a.statut NOT IN ('routing', 'escalated') OR a.premiere_reponse_positive_le IS NOT NULL THEN
        RAISE EXCEPTION 'Relance possible uniquement pour une alerte en recherche, sans réponse positive' USING ERRCODE = '55000'; END IF;
    IF a.routage_manuel THEN RAISE EXCEPTION 'Alerte en routage manuel : utilisez « Ajouter une pharmacie »' USING ERRCODE = '55000'; END IF;
    v_vague := GREATEST(a.vague - 1, 0);
    UPDATE public.alertes_routage SET vague = v_vague, debut_routage_le = now() WHERE id = a.id;
    PERFORM public.journaliser_admin('relancer_vague', a.id, jsonb_build_object('vague', v_vague));
    RETURN v_vague;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_cloturer_alerte(p_alerte_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE a public.alertes_routage%ROWTYPE;
BEGIN
    PERFORM public.exiger_admin();
    SELECT * INTO a FROM public.alertes_routage WHERE id = p_alerte_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Alerte introuvable' USING ERRCODE = 'P0002'; END IF;
    IF a.statut NOT IN ('routing', 'escalated', 'answered') THEN RAISE EXCEPTION 'Alerte non clôturable dans cet état' USING ERRCODE = '55000'; END IF;
    UPDATE public.alertes_routage SET statut = 'fulfilled' WHERE id = a.id;
    UPDATE public.envois_alerte SET statut = 'expired' WHERE alerte_id = a.id AND statut = 'sent';
    PERFORM public.journaliser_admin('cloturer', a.id, '{}');
END;
$$;

-- Annuler : l'alerte et ses envois sont annulés, les messages encore en file ne partiront pas.
CREATE OR REPLACE FUNCTION public.annuler_alerte_interne(p_alerte_id uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
    UPDATE public.alertes_routage SET statut = 'cancelled' WHERE id = p_alerte_id;
    UPDATE public.envois_alerte SET statut = 'cancelled' WHERE alerte_id = p_alerte_id AND statut = 'sent';
    UPDATE public.notifications_outbox SET statut = 'cancelled', derniere_erreur = 'alerte_annulee'
        WHERE statut = 'queued' AND (cle_base IN (SELECT e.id::text FROM public.envois_alerte e WHERE e.alerte_id = p_alerte_id)
                                     OR cle_base LIKE 'alerte:' || p_alerte_id::text || ':%')
          AND modele NOT IN ('restricted_refus');
$$;
REVOKE ALL ON FUNCTION public.annuler_alerte_interne(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_annuler_alerte(p_alerte_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE a public.alertes_routage%ROWTYPE;
BEGIN
    PERFORM public.exiger_admin();
    SELECT * INTO a FROM public.alertes_routage WHERE id = p_alerte_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Alerte introuvable' USING ERRCODE = 'P0002'; END IF;
    IF a.statut IN ('fulfilled', 'expired', 'cancelled') THEN RAISE EXCEPTION 'Alerte déjà terminée' USING ERRCODE = '55000'; END IF;
    PERFORM public.annuler_alerte_interne(a.id);
    PERFORM public.journaliser_admin('annuler', a.id, '{}');
END;
$$;

-- Retirer un destinataire : l'envoi est annulé, son message encore en file ne partira pas.
CREATE OR REPLACE FUNCTION public.admin_retirer_destinataire(p_envoi_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE e public.envois_alerte%ROWTYPE;
BEGIN
    PERFORM public.exiger_admin();
    SELECT * INTO e FROM public.envois_alerte WHERE id = p_envoi_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Envoi introuvable' USING ERRCODE = 'P0002'; END IF;
    IF e.statut <> 'sent' THEN RAISE EXCEPTION 'Destinataire déjà répondu, expiré ou retiré' USING ERRCODE = '55000'; END IF;
    UPDATE public.envois_alerte SET statut = 'cancelled' WHERE id = e.id;
    UPDATE public.notifications_outbox SET statut = 'cancelled', derniere_erreur = 'destinataire_retire' WHERE statut = 'queued' AND cle_base = e.id::text;
    PERFORM public.journaliser_admin('retirer_destinataire', e.alerte_id, jsonb_build_object('pharmacie_id', e.pharmacie_id));
END;
$$;

-- Bloquer un patient (empreintes, jamais le numéro) : l'alerte est annulée, les prochaines créations du même numéro / de la même IP refusées.
CREATE OR REPLACE FUNCTION public.admin_bloquer_patient(p_alerte_id uuid, p_motif text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE a public.alertes_routage%ROWTYPE;
BEGIN
    PERFORM public.exiger_admin();
    SELECT * INTO a FROM public.alertes_routage WHERE id = p_alerte_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Alerte introuvable' USING ERRCODE = 'P0002'; END IF;
    INSERT INTO public.patients_bloques (empreinte_patient, motif) VALUES (a.empreinte_patient, left(COALESCE(p_motif, 'abus'), 120)) ON CONFLICT DO NOTHING;
    IF a.empreinte_ip IS NOT NULL AND a.empreinte_ip <> a.empreinte_patient THEN
        INSERT INTO public.patients_bloques (empreinte_patient, motif) VALUES (a.empreinte_ip, left(COALESCE(p_motif, 'abus'), 120)) ON CONFLICT DO NOTHING;
    END IF;
    IF a.statut NOT IN ('fulfilled', 'expired', 'cancelled') THEN PERFORM public.annuler_alerte_interne(a.id); END IF;
    PERFORM public.journaliser_admin('bloquer_patient', a.id, '{}');
END;
$$;

REVOKE ALL ON FUNCTION public.file_alertes_admin(text[], int), public.chronologie_alerte(uuid), public.etat_budget_messages(),
    public.indicateurs_alertes(int), public.admin_rattacher_medicament(uuid, uuid), public.admin_transmettre(uuid, uuid[]),
    public.admin_refuser_alerte(uuid), public.admin_relancer_vague(uuid), public.admin_cloturer_alerte(uuid),
    public.admin_annuler_alerte(uuid), public.admin_retirer_destinataire(uuid), public.admin_bloquer_patient(uuid, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.file_alertes_admin(text[], int), public.chronologie_alerte(uuid), public.etat_budget_messages(),
    public.indicateurs_alertes(int), public.admin_rattacher_medicament(uuid, uuid), public.admin_transmettre(uuid, uuid[]),
    public.admin_refuser_alerte(uuid), public.admin_relancer_vague(uuid), public.admin_cloturer_alerte(uuid),
    public.admin_annuler_alerte(uuid), public.admin_retirer_destinataire(uuid), public.admin_bloquer_patient(uuid, text) TO authenticated;
-- Les fonctions vérifient le rôle admin elles-mêmes (42501 sinon).

COMMIT;
