-- ============================================================
-- N'Gola Pharma — PR 4 : création d'alertes (public), file needs_review, planificateur
-- SPEC 2 §2, §3, §4.3, §4.4, §6. PRODUCTION : à exécuter à la main, après relecture, après 20261006000000.
-- Cette migration n'envoie rien. La création passe par une fonction atomique réservée au serveur (service role) :
-- le navigateur n'écrit jamais dans `alertes_routage`.
-- ============================================================
BEGIN;

-- ── 1. Colonnes de suivi ─────────────────────────────────────────────
ALTER TABLE public.alertes_routage
    ADD COLUMN IF NOT EXISTS empreinte_ip text,                  -- limitation par IP (hachée, jamais l'adresse)
    ADD COLUMN IF NOT EXISTS raison_revue text,                  -- pourquoi l'alerte est en needs_review
    ADD COLUMN IF NOT EXISTS debut_routage_le timestamptz,
    ADD COLUMN IF NOT EXISTS escalade_le timestamptz,
    ADD COLUMN IF NOT EXISTS patient_notifie_le timestamptz,     -- 1er message « disponible » envoyé au patient
    ADD COLUMN IF NOT EXISTS second_message_le timestamptz;      -- 2e message court (plafonné à 1, §4.4)
ALTER TABLE public.envois_alerte
    ADD COLUMN IF NOT EXISTS relance_sms_le timestamptz;         -- SMS de relance d'une alerte urgente (§6.1)
CREATE INDEX IF NOT EXISTS idx_alertes_routage_ip ON public.alertes_routage (empreinte_ip, cree_le) WHERE empreinte_ip IS NOT NULL;

-- Colonnes non secrètes lisibles par l'admin connecté (le contact patient chiffré reste masqué).
GRANT SELECT (empreinte_ip, raison_revue, debut_routage_le, escalade_le, patient_notifie_le, second_message_le)
    ON public.alertes_routage TO authenticated;
GRANT SELECT (relance_sms_le) ON public.envois_alerte TO authenticated;

INSERT INTO public.config_routage (cle, valeur) VALUES
    ('alertes_max_par_jour',          '5'),     -- §3 : 5 alertes par jour et par numéro / IP
    ('fusion_alertes_min',            '30'),    -- §3 : même patient + même médicament en moins de 30 min
    ('jeton_telegram_patient_h',      '72')
ON CONFLICT (cle) DO NOTHING;

-- ── 2. Création atomique d'une alerte ────────────────────────────────
-- Appelée par l'Edge Function `creer-alerte` (service role), APRÈS vérification du captcha.
-- Ordre : liste de blocage -> consentement -> fusion (même patient, même médicament, < 30 min) -> limite
-- quotidienne -> insertion. Un verrou consultatif par empreinte rend la limite fiable sous requêtes parallèles.
-- Le statut initial est `needs_review` si le médicament est inconnu, restreint ou non classé comme routable
-- (garde-fou §4.0, medicament_routable) : l'alerte n'est alors JAMAIS routée automatiquement.
CREATE OR REPLACE FUNCTION public.creer_alerte_routage(
    p_id_public         text,
    p_medicament_id     uuid,
    p_requete_brute     text,
    p_quartier_id       uuid,
    p_lat               numeric,
    p_lng               numeric,
    p_urgence           text,
    p_canal_patient     text,
    p_contact_chiffre   bytea,
    p_empreinte_patient text,      -- hachage du numéro si fourni, sinon de l'IP
    p_empreinte_ip      text,
    p_consentement      boolean,
    p_expire_le         timestamptz)
RETURNS TABLE (alerte_id uuid, id_public text, statut text, raison_revue text, fusionnee boolean, refus text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_max int;
    v_fusion_min int;
    v_existante public.alertes_routage%ROWTYPE;
    v_statut text := 'new';
    v_raison text := NULL;
    v_nb int;
BEGIN
    IF p_empreinte_patient IS NULL OR p_empreinte_patient = '' THEN RAISE EXCEPTION 'empreinte obligatoire'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(p_empreinte_patient, 0));
    IF p_empreinte_ip IS NOT NULL THEN PERFORM pg_advisory_xact_lock(hashtextextended('ip:' || p_empreinte_ip, 0)); END IF;

    IF EXISTS (SELECT 1 FROM public.patients_bloques b WHERE b.empreinte_patient IN (p_empreinte_patient, COALESCE(p_empreinte_ip, p_empreinte_patient))) THEN
        RETURN QUERY SELECT NULL::uuid, NULL::text, NULL::text, NULL::text, false, 'bloque'::text; RETURN;
    END IF;
    IF p_canal_patient = 'sms' AND p_consentement IS NOT TRUE THEN
        RETURN QUERY SELECT NULL::uuid, NULL::text, NULL::text, NULL::text, false, 'consentement_requis'::text; RETURN;
    END IF;

    SELECT COALESCE((SELECT (valeur #>> '{}')::int FROM public.config_routage WHERE cle = 'alertes_max_par_jour'), 5) INTO v_max;
    SELECT COALESCE((SELECT (valeur #>> '{}')::int FROM public.config_routage WHERE cle = 'fusion_alertes_min'), 30) INTO v_fusion_min;

    -- Fusion : même patient, même médicament (reconnu), alerte encore active, créée il y a moins de N minutes.
    IF p_medicament_id IS NOT NULL THEN
        SELECT * INTO v_existante FROM public.alertes_routage a
        WHERE a.empreinte_patient = p_empreinte_patient AND a.medicament_id = p_medicament_id
          AND a.statut NOT IN ('fulfilled', 'expired', 'cancelled')
          AND a.cree_le > now() - make_interval(mins => v_fusion_min)
        ORDER BY a.cree_le DESC LIMIT 1;
        IF FOUND THEN
            RETURN QUERY SELECT v_existante.id, v_existante.id_public, v_existante.statut, v_existante.raison_revue, true, NULL::text; RETURN;
        END IF;
    END IF;

    -- Limite : p_max alertes par 24 h et par numéro, et par IP. La (v_max+1)e est refusée.
    SELECT count(*) INTO v_nb FROM public.alertes_routage a
        WHERE a.empreinte_patient = p_empreinte_patient AND a.cree_le > now() - interval '24 hours';
    IF v_nb >= v_max THEN
        RETURN QUERY SELECT NULL::uuid, NULL::text, NULL::text, NULL::text, false, 'limite_quotidienne'::text; RETURN;
    END IF;
    IF p_empreinte_ip IS NOT NULL THEN
        SELECT count(*) INTO v_nb FROM public.alertes_routage a
            WHERE a.empreinte_ip = p_empreinte_ip AND a.cree_le > now() - interval '24 hours';
        IF v_nb >= v_max THEN
            RETURN QUERY SELECT NULL::uuid, NULL::text, NULL::text, NULL::text, false, 'limite_quotidienne'::text; RETURN;
        END IF;
    END IF;

    -- Garde-fou réglementaire : non reconnu, restreint ou non routable -> revue admin.
    IF p_medicament_id IS NULL THEN
        v_statut := 'needs_review'; v_raison := 'non_reconnu';
    ELSIF NOT public.medicament_routable(p_medicament_id) THEN
        v_statut := 'needs_review';
        v_raison := CASE WHEN (SELECT m.restreint FROM public.medicaments m WHERE m.id = p_medicament_id) THEN 'restreint'
                         ELSE 'classification_non_validee' END;
    END IF;

    RETURN QUERY
    INSERT INTO public.alertes_routage AS a (id_public, medicament_id, requete_brute, quartier_id, lat, lng, urgence, statut,
            canal_patient, contact_patient_chiffre, empreinte_patient, empreinte_ip, consentement_le, raison_revue, expire_le)
        VALUES (p_id_public, p_medicament_id, CASE WHEN p_medicament_id IS NULL THEN p_requete_brute ELSE NULL END,
                p_quartier_id, p_lat, p_lng, p_urgence, v_statut, p_canal_patient, p_contact_chiffre,
                p_empreinte_patient, p_empreinte_ip,
                CASE WHEN p_consentement IS TRUE THEN now() END, v_raison, p_expire_le)
        RETURNING a.id, a.id_public, a.statut, a.raison_revue, false, NULL::text;
END;
$$;
REVOKE ALL ON FUNCTION public.creer_alerte_routage(text, uuid, text, uuid, numeric, numeric, text, text, bytea, text, text, boolean, timestamptz)
    FROM PUBLIC, anon, authenticated;

-- ── 3. Données d'entrée du moteur de routage (une requête pour toutes les pharmacies) ──
-- Renvoie, pour un médicament, le tableau attendu par planDispatch (supabase/functions/_shared/routage.js).
-- Le moteur applique lui-même les filtres éliminatoires : on lui passe TOUTES les pharmacies, pour que l'audit
-- consigne aussi les exclues et leur raison. Aucune donnée patient ici.
CREATE OR REPLACE FUNCTION public.donnees_routage_pharmacies(p_medicament_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', p.id, 'statut', p.statut, 'est_publiee', p.est_publiee, 'est_demo', p.est_demo,
        'quartier_id', p.quartier_id, 'latitude', p.latitude, 'longitude', p.longitude, 'horaires', p.horaires,
        'est_de_garde', p.est_de_garde, 'garde_jusqu_a', p.garde_jusqu_a,
        'contacts_actifs', (SELECT count(*) FROM public.contacts_pharmacie c
                            WHERE c.pharmacie_id = p.id AND c.desabonne_le IS NULL AND c.bloque_le IS NULL
                              AND (c.canal <> 'telegram' OR c.verifie_le IS NOT NULL)),
        'envois_derniere_heure', (SELECT count(*) FROM public.envois_alerte e WHERE e.pharmacie_id = p.id AND e.envoye_le > now() - interval '1 hour'),
        'derniere_sollicitation', (SELECT max(e.envoye_le) FROM public.envois_alerte e WHERE e.pharmacie_id = p.id),
        'taux_reponse_30j', (SELECT CASE WHEN count(*) = 0 THEN NULL
                                         ELSE round(count(r.id)::numeric / count(*), 4) END
                             FROM public.envois_alerte e LEFT JOIN public.reponses_alerte r ON r.envoi_id = e.id
                             WHERE e.pharmacie_id = p.id AND e.envoye_le > now() - interval '30 days'),
        'stock', (SELECT jsonb_build_object('statut_stock', s.statut_stock, 'confirme_le', s.confirme_le)
                  FROM public.stocks s WHERE s.pharmacie_id = p.id AND s.medicament_id = p_medicament_id)
    )), '[]'::jsonb)
    FROM public.pharmacies p
$$;
REVOKE ALL ON FUNCTION public.donnees_routage_pharmacies(uuid) FROM PUBLIC, anon, authenticated;

COMMIT;
