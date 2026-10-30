-- ============================================================
-- N'Gola Pharma — onboarding, étape 2 : checklist de l'Espace Pro, « Je confirme mes stocks », règle de publication (SPEC 1 §1, §5, §5.2).
-- PRODUCTION : à exécuter à la main, après relecture, après 20261011000000. Rétro-compatible : aucune colonne existante modifiée.
-- La publication (est_publiee) reste une colonne protégée : seule la fonction ci-dessous (SECURITY DEFINER) la positionne, jamais le navigateur.
-- Règle (§1) : publiée si statut = 'verifie' ET les 5 premières tâches faites ET au moins `publication_min_items_frais` stocks
-- confirmés depuis moins de `publication_fraicheur_jours` jours. Pas de dépublication automatique dans cette étape (voir README).
-- ============================================================
BEGIN;

-- Les deux nouveaux réglages sont modifiables (et validés) depuis la console admin.
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
        ('jeton_telegram_pharmacie_h', 'int', 1, 720), ('prix_max_fcfa', 'int', 1, 1000000000), ('max_contacts_sms_par_pharmacie', 'int', 1, 10),
        ('publication_min_items_frais', 'int', 1, 1000), ('publication_fraicheur_jours', 'num', 1, 90)
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

INSERT INTO public.config_routage (cle, valeur) VALUES
    ('publication_min_items_frais', '10'),
    ('publication_fraicheur_jours', '7')
ON CONFLICT (cle) DO NOTHING;

-- ── Calcul de l'état d'onboarding d'une pharmacie (interne : jamais exposé tel quel) ──
CREATE OR REPLACE FUNCTION public.calculer_onboarding(p_pharmacie uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $f$
DECLARE
    ph public.pharmacies%ROWTYPE;
    e jsonb;
    v_min int := COALESCE((SELECT (valeur #>> '{}')::int FROM public.config_routage WHERE cle = 'publication_min_items_frais'), 10);
    v_jours numeric := COALESCE((SELECT (valeur #>> '{}')::numeric FROM public.config_routage WHERE cle = 'publication_fraicheur_jours'), 7);
    v_stocks int;
    v_frais int;
    v_telegram boolean;
    v_items jsonb;
    v_faits int;
BEGIN
    SELECT * INTO ph FROM public.pharmacies WHERE id = p_pharmacie;
    IF NOT FOUND THEN RETURN NULL; END IF;
    e := COALESCE((SELECT etat FROM public.etat_onboarding_pharmacie WHERE pharmacie_id = p_pharmacie), '{}');
    SELECT count(*), count(*) FILTER (WHERE confirme_le > now() - make_interval(secs => v_jours * 86400))
      INTO v_stocks, v_frais FROM public.stocks WHERE pharmacie_id = p_pharmacie AND statut_stock <> 'archive';
    v_telegram := EXISTS (SELECT 1 FROM public.contacts_pharmacie c WHERE c.pharmacie_id = p_pharmacie AND c.canal = 'telegram'
                          AND c.verifie_le IS NOT NULL AND c.desabonne_le IS NULL AND c.bloque_le IS NULL);
    v_items := jsonb_build_array(
        jsonb_build_object('cle', 'mot_de_passe', 'fait', e ->> 'mot_de_passe_defini_le' IS NOT NULL),
        jsonb_build_object('cle', 'ma_pharmacie', 'fait', e ->> 'gps_confirme_le' IS NOT NULL AND ph.latitude IS NOT NULL AND ph.longitude IS NOT NULL
                                                         AND ph.horaires IS NOT NULL AND ph.horaires <> '{}'::jsonb AND ph.horaires <> 'null'::jsonb,
                           'horaires', ph.horaires IS NOT NULL AND ph.horaires <> '{}'::jsonb AND ph.horaires <> 'null'::jsonb,
                           'gps_present', ph.latitude IS NOT NULL AND ph.longitude IS NOT NULL, 'gps_confirme', e ->> 'gps_confirme_le' IS NOT NULL),
        jsonb_build_object('cle', 'telegram', 'fait', v_telegram OR e ->> 'sans_telegram_le' IS NOT NULL, 'telegram_actif', v_telegram,
                           'sans_telegram', e ->> 'sans_telegram_le' IS NOT NULL),
        -- Critère provisoire : au moins un stock enregistré (l'import guidé et son historique viendront avec l'étape suivante).
        jsonb_build_object('cle', 'import', 'fait', v_stocks >= 1, 'nb_stocks', v_stocks),
        jsonb_build_object('cle', 'confirmation', 'fait', e ->> 'stocks_confirmes_le' IS NOT NULL),
        jsonb_build_object('cle', 'seuil', 'fait', v_frais >= v_min, 'items_frais', v_frais, 'min_items_frais', v_min));
    SELECT count(*) INTO v_faits FROM jsonb_array_elements(v_items) i WHERE (i ->> 'fait')::boolean;
    RETURN jsonb_build_object('items', v_items, 'faits', v_faits, 'total', 6, 'statut', ph.statut, 'est_publiee', ph.est_publiee,
        'publiable', ph.statut = 'verifie' AND v_faits = 6, 'fraicheur_jours', v_jours, 'min_items_frais', v_min, 'items_frais', v_frais);
END $f$;

-- ── Règle de publication : publie si les conditions sont réunies (idempotent) ──
CREATE OR REPLACE FUNCTION public.evaluer_publication_interne(p_pharmacie uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE c jsonb := public.calculer_onboarding(p_pharmacie);
BEGIN
    IF c IS NULL OR NOT (c ->> 'publiable')::boolean OR (c ->> 'est_publiee')::boolean THEN RETURN false; END IF;
    UPDATE public.pharmacies SET est_publiee = true, publiee_le = now() WHERE id = p_pharmacie AND statut = 'verifie' AND NOT est_publiee;
    IF FOUND THEN
        PERFORM public.journaliser_onboarding(NULL, p_pharmacie, NULL, 'system', 'pharmacie_publiee', jsonb_build_object('items_frais', c -> 'items_frais'));
        RETURN true;
    END IF;
    RETURN false;
END $f$;

CREATE OR REPLACE FUNCTION public.exiger_pharmacien_interne() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $f$
DECLARE v uuid := public.auth_pharmacie_id();
BEGIN
    IF public.auth_role() <> 'pharmacien' OR v IS NULL THEN RAISE EXCEPTION 'Réservé à une pharmacie' USING ERRCODE = '42501'; END IF;
    RETURN v;
END $f$;

-- ── Espace Pro : lecture de MON état, marqueurs, confirmation des stocks ──
CREATE OR REPLACE FUNCTION public.etat_onboarding_mien() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $f$ BEGIN RETURN public.calculer_onboarding(public.exiger_pharmacien_interne()); END $f$;

-- Marqueurs déclaratifs : mot de passe défini, position GPS confirmée (jamais modifiée : le GPS reste réservé à l'admin),
-- « je n'utilise pas Telegram » (annulable). Le reste de la checklist est calculé, pas déclaré.
CREATE OR REPLACE FUNCTION public.onboarding_marquer(p_cle text, p_valeur boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE
    v_ph uuid := public.exiger_pharmacien_interne();
    v_champ text;
BEGIN
    v_champ := CASE p_cle WHEN 'mot_de_passe_defini' THEN 'mot_de_passe_defini_le' WHEN 'gps_confirme' THEN 'gps_confirme_le'
                          WHEN 'sans_telegram' THEN 'sans_telegram_le' ELSE NULL END;
    IF v_champ IS NULL THEN RAISE EXCEPTION 'Marqueur inconnu' USING ERRCODE = '22023'; END IF;
    IF NOT p_valeur AND p_cle <> 'sans_telegram' THEN RAISE EXCEPTION 'Ce marqueur ne s''annule pas' USING ERRCODE = '22023'; END IF;
    IF p_cle = 'gps_confirme' AND NOT EXISTS (SELECT 1 FROM public.pharmacies WHERE id = v_ph AND latitude IS NOT NULL AND longitude IS NOT NULL) THEN
        RAISE EXCEPTION 'Aucune position enregistrée : contactez l''équipe N''Gola Pharma' USING ERRCODE = '55000';
    END IF;
    INSERT INTO public.etat_onboarding_pharmacie (pharmacie_id, etat, mis_a_jour_le)
    VALUES (v_ph, CASE WHEN p_valeur THEN jsonb_build_object(v_champ, now()) ELSE '{}'::jsonb END, now())
    ON CONFLICT (pharmacie_id) DO UPDATE SET mis_a_jour_le = now(),
        etat = CASE WHEN p_valeur THEN public.etat_onboarding_pharmacie.etat || jsonb_build_object(v_champ, now())
                    ELSE public.etat_onboarding_pharmacie.etat - v_champ END;
    PERFORM public.journaliser_onboarding(NULL, v_ph, auth.uid(), 'pharmacy', 'marqueur', jsonb_build_object('cle', p_cle, 'valeur', p_valeur));
    PERFORM public.evaluer_publication_interne(v_ph);
    RETURN public.calculer_onboarding(v_ph);
END $f$;

-- « Je confirme mes stocks » : confirme_le = maintenant pour les lignes non archivées de MA pharmacie (valeurs inchangées).
CREATE OR REPLACE FUNCTION public.confirmer_mes_stocks() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE
    v_ph uuid := public.exiger_pharmacien_interne();
    n int;
    v_publiee boolean;
BEGIN
    UPDATE public.stocks SET confirme_le = now(), mis_a_jour_par = auth.uid() WHERE pharmacie_id = v_ph AND statut_stock <> 'archive';
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n = 0 THEN RETURN jsonb_build_object('confirmes', 0, 'publiee', false, 'etat', public.calculer_onboarding(v_ph)); END IF;
    INSERT INTO public.etat_onboarding_pharmacie (pharmacie_id, etat, mis_a_jour_le)
    VALUES (v_ph, jsonb_build_object('stocks_confirmes_le', now()), now())
    ON CONFLICT (pharmacie_id) DO UPDATE SET mis_a_jour_le = now(), etat = public.etat_onboarding_pharmacie.etat || jsonb_build_object('stocks_confirmes_le', now());
    PERFORM public.journaliser_onboarding(NULL, v_ph, auth.uid(), 'pharmacy', 'stocks_confirmes', jsonb_build_object('lignes', n));
    v_publiee := public.evaluer_publication_interne(v_ph);
    RETURN jsonb_build_object('confirmes', n, 'publiee', v_publiee, 'etat', public.calculer_onboarding(v_ph));
END $f$;

-- Une mise à jour de stock peut elle aussi faire franchir le seuil : réévaluation (appelée par l'Espace Pro après un ajout).
CREATE OR REPLACE FUNCTION public.reevaluer_ma_publication() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE v_ph uuid := public.exiger_pharmacien_interne(); v_publiee boolean;
BEGIN
    v_publiee := public.evaluer_publication_interne(v_ph);
    RETURN jsonb_build_object('publiee', v_publiee, 'etat', public.calculer_onboarding(v_ph));
END $f$;

-- ── Console admin : état d'onboarding de n'importe quelle pharmacie ──
CREATE OR REPLACE FUNCTION public.admin_etat_onboarding(p_pharmacie uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $f$ BEGIN PERFORM public.exiger_admin(); RETURN public.calculer_onboarding(p_pharmacie); END $f$;

-- Le détail d'une demande approuvée affiche l'avancement de l'onboarding.
CREATE OR REPLACE FUNCTION public.admin_detail_demande(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE d public.demandes_partenaire%ROWTYPE;
BEGIN
    PERFORM public.exiger_admin();
    SELECT * INTO d FROM public.demandes_partenaire WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Demande introuvable' USING ERRCODE = 'P0002'; END IF;
    RETURN jsonb_build_object(
        'demande', to_jsonb(d) - 'empreinte_ip' - 'jeton_complements_hash',
        'quartier', (SELECT nom FROM public.quartiers WHERE id = d.quartier_id),
        'documents', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', x.id, 'nature', x.nature, 'type_mime', x.type_mime, 'taille_octets', x.taille_octets, 'depose_le', x.depose_le) ORDER BY x.depose_le)
                               FROM public.documents_demande x WHERE x.demande_id = d.id), '[]'),
        'checklist', COALESCE((SELECT jsonb_agg(jsonb_build_object('element', c.element, 'coche_le', c.coche_le, 'coche_par', c.coche_par)) FROM public.checklist_demande c WHERE c.demande_id = d.id), '[]'),
        'journal', COALESCE((SELECT jsonb_agg(jsonb_build_object('t', e.cree_le, 'evenement', e.evenement, 'acteur_type', e.acteur_type, 'details', e.details) ORDER BY e.cree_le)
                             FROM public.evenements_onboarding e WHERE e.demande_id = d.id OR (d.pharmacie_id IS NOT NULL AND e.pharmacie_id = d.pharmacie_id)), '[]'),
        'onboarding', CASE WHEN d.pharmacie_id IS NOT NULL THEN public.calculer_onboarding(d.pharmacie_id) END);
END $f$;

REVOKE ALL ON FUNCTION public.calculer_onboarding(uuid), public.evaluer_publication_interne(uuid), public.exiger_pharmacien_interne() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.etat_onboarding_mien(), public.onboarding_marquer(text, boolean), public.confirmer_mes_stocks(), public.reevaluer_ma_publication(),
    public.admin_etat_onboarding(uuid), public.admin_detail_demande(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.etat_onboarding_mien(), public.onboarding_marquer(text, boolean), public.confirmer_mes_stocks(), public.reevaluer_ma_publication(),
    public.admin_etat_onboarding(uuid), public.admin_detail_demande(uuid) TO authenticated;

COMMIT;
