-- ============================================================
-- N'Gola Pharma — onboarding (SPEC 1 §3, §4, §6) : demandes de pré-inscription, justificatifs, checklist de vérification,
-- journal d'audit, jetons d'activation. PRODUCTION : à exécuter à la main, après relecture, après 20261010000000.
-- Aucune écriture anonyme directe : la soumission passe par l'Edge Function `creer-demande` (service role, captcha, limite par IP).
-- Tables lisibles et modifiables par l'admin seul (« admin seul pour l'instant »). Aucune ordonnance n'est collectée.
-- ============================================================
BEGIN;

-- ── 1. Tables ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.demandes_partenaire (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    statut                   text NOT NULL DEFAULT 'submitted'
                             CHECK (statut IN ('submitted', 'in_review', 'needs_info', 'rejected', 'approved')),
    nom_pharmacie            text NOT NULL CHECK (char_length(btrim(nom_pharmacie)) BETWEEN 2 AND 120),
    quartier_id              uuid NOT NULL REFERENCES public.quartiers(id),
    adresse                  text NOT NULL CHECK (char_length(btrim(adresse)) BETWEEN 3 AND 250),
    telephone_fixe           text NOT NULL,                       -- E.164
    nom_titulaire            text NOT NULL CHECK (char_length(btrim(nom_titulaire)) BETWEEN 2 AND 120),
    numero_ordre             text NOT NULL CHECK (char_length(btrim(numero_ordre)) BETWEEN 2 AND 40),
    email_titulaire          text NOT NULL CHECK (email_titulaire ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND char_length(email_titulaire) <= 200),
    telephone_mobile         text NOT NULL,                       -- E.164
    latitude                 numeric(9,6) CHECK (latitude BETWEEN -90 AND 90),
    longitude                numeric(9,6) CHECK (longitude BETWEEN -180 AND 180),
    horaires                 jsonb NOT NULL DEFAULT '{}',
    participe_garde          boolean NOT NULL DEFAULT false,
    consentement_conditions_le timestamptz NOT NULL,
    consentement_messages_le   timestamptz NOT NULL,
    doublon_suspect          boolean NOT NULL DEFAULT false,
    doublon_raisons          jsonb NOT NULL DEFAULT '[]',
    reviewer_id              uuid REFERENCES auth.users(id),
    motif_decision           text,
    pharmacie_id             uuid REFERENCES public.pharmacies(id),
    empreinte_ip             text,                                -- HMAC de l'IP : jamais l'adresse
    est_demo                 boolean NOT NULL DEFAULT false,
    jeton_complements_hash   text,                                -- lien signé pour répondre à une demande de compléments
    complements_expire_le    timestamptz,
    compte_cree_le           timestamptz,                         -- compte Auth + profil créés
    invitation_envoyee_le    timestamptz,
    cree_le                  timestamptz NOT NULL DEFAULT now(),
    decidee_le               timestamptz,
    CONSTRAINT demandes_pharmacie_si_approuvee CHECK (statut <> 'approved' OR pharmacie_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_demandes_statut ON public.demandes_partenaire (statut, cree_le);
CREATE INDEX IF NOT EXISTS idx_demandes_ip ON public.demandes_partenaire (empreinte_ip, cree_le) WHERE empreinte_ip IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_demandes_ordre ON public.demandes_partenaire (lower(btrim(numero_ordre)));

CREATE TABLE IF NOT EXISTS public.documents_demande (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    demande_id      uuid NOT NULL REFERENCES public.demandes_partenaire(id) ON DELETE CASCADE,
    nature          text NOT NULL CHECK (nature IN ('ordre_attestation', 'autorisation_exploitation', 'id_titulaire', 'autre')),
    chemin_stockage text NOT NULL,                                -- bucket privé « documents-demandes »
    type_mime       text NOT NULL CHECK (type_mime IN ('application/pdf', 'image/jpeg', 'image/png')),
    taille_octets   integer NOT NULL CHECK (taille_octets BETWEEN 1 AND 5242880),
    depose_le       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_documents_demande ON public.documents_demande (demande_id);

CREATE TABLE IF NOT EXISTS public.checklist_demande (
    demande_id uuid NOT NULL REFERENCES public.demandes_partenaire(id) ON DELETE CASCADE,
    element    text NOT NULL CHECK (element IN ('ordre_ok', 'autorisation_ok', 'rappel_tel_ok', 'adresse_gps_ok', 'pas_doublon')),
    coche_par  uuid NOT NULL REFERENCES auth.users(id),
    coche_le   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (demande_id, element)
);

CREATE TABLE IF NOT EXISTS public.evenements_onboarding (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    demande_id   uuid,
    pharmacie_id uuid,
    acteur_id    uuid,
    acteur_type  text NOT NULL CHECK (acteur_type IN ('pharmacy', 'admin', 'system')),
    evenement    text NOT NULL,
    details      jsonb NOT NULL DEFAULT '{}',               -- jamais de contact ni de pièce
    cree_le      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_evenements_onboarding_demande ON public.evenements_onboarding (demande_id, cree_le);

-- Jeton d'activation du compte (72 h, usage unique) : seul son hachage est stocké.
CREATE TABLE IF NOT EXISTS public.jetons_activation (
    jeton_hash   text PRIMARY KEY,
    demande_id   uuid NOT NULL REFERENCES public.demandes_partenaire(id) ON DELETE CASCADE,
    expire_le    timestamptz NOT NULL,
    utilise_le   timestamptz,
    cree_le      timestamptz NOT NULL DEFAULT now()
);

-- ── 2. RLS : admin seul ───────────────────────────────────────────────
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['demandes_partenaire', 'documents_demande', 'checklist_demande', 'evenements_onboarding', 'jetons_activation'] LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    END LOOP;
END $$;
-- Lecture admin (jamais le hachage des jetons) ; toute écriture passe par les fonctions ci-dessous.
DROP POLICY IF EXISTS "Admin lit les demandes" ON public.demandes_partenaire;
DROP POLICY IF EXISTS "Admin lit les documents" ON public.documents_demande;
DROP POLICY IF EXISTS "Admin lit la checklist" ON public.checklist_demande;
DROP POLICY IF EXISTS "Admin lit le journal d'onboarding" ON public.evenements_onboarding;
CREATE POLICY "Admin lit les demandes" ON public.demandes_partenaire FOR SELECT USING (auth_role() = 'admin');
CREATE POLICY "Admin lit les documents" ON public.documents_demande FOR SELECT USING (auth_role() = 'admin');
CREATE POLICY "Admin lit la checklist" ON public.checklist_demande FOR SELECT USING (auth_role() = 'admin');
CREATE POLICY "Admin lit le journal d'onboarding" ON public.evenements_onboarding FOR SELECT USING (auth_role() = 'admin');
GRANT SELECT ON public.demandes_partenaire, public.documents_demande, public.checklist_demande, public.evenements_onboarding TO authenticated;
-- Le hachage des jetons de la demande n'est pas exposé, même à l'admin.
REVOKE SELECT ON public.demandes_partenaire FROM authenticated;
GRANT SELECT (id, statut, nom_pharmacie, quartier_id, adresse, telephone_fixe, nom_titulaire, numero_ordre, email_titulaire, telephone_mobile,
              latitude, longitude, horaires, participe_garde, consentement_conditions_le, consentement_messages_le, doublon_suspect,
              doublon_raisons, reviewer_id, motif_decision, pharmacie_id, est_demo, compte_cree_le, invitation_envoyee_le, cree_le, decidee_le)
    ON public.demandes_partenaire TO authenticated;

-- ── 3. Bucket privé des justificatifs (jamais d'URL publique ; URL signée de 5 min côté admin) ──
DO $$
BEGIN
    IF to_regclass('storage.buckets') IS NOT NULL THEN
        INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
        VALUES ('documents-demandes', 'documents-demandes', false, 5242880, ARRAY['application/pdf', 'image/jpeg', 'image/png'])
        ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = 5242880,
            allowed_mime_types = ARRAY['application/pdf', 'image/jpeg', 'image/png'];
    END IF;
END $$;

-- ── 4. Aides ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.normaliser_nom_pharmacie(p text) RETURNS text
LANGUAGE sql IMMUTABLE
AS $$ SELECT btrim(regexp_replace(regexp_replace(lower(translate(coalesce(p, ''),
        'àâäáãåçéèêëíìîïñóòôöõúùûüýÿÀÂÄÁÃÅÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜÝ', 'aaaaaaceeeeiiiinooooouuuuyyAAAAAACEEEEIIIINOOOOOUUUUY')),
        '\mpharmacie\M', '', 'g'), '[^a-z0-9]+', ' ', 'g')) $$;

CREATE OR REPLACE FUNCTION public.chiffres_telephone(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 9) $$;

CREATE OR REPLACE FUNCTION public.journaliser_onboarding(p_demande uuid, p_pharmacie uuid, p_acteur uuid, p_type text, p_evenement text, p_details jsonb DEFAULT '{}')
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$ INSERT INTO public.evenements_onboarding (demande_id, pharmacie_id, acteur_id, acteur_type, evenement, details)
      VALUES (p_demande, p_pharmacie, p_acteur, p_type, p_evenement, COALESCE(p_details, '{}')) $$;
REVOKE ALL ON FUNCTION public.normaliser_nom_pharmacie(text), public.chiffres_telephone(text),
    public.journaliser_onboarding(uuid, uuid, uuid, text, text, jsonb) FROM PUBLIC, anon, authenticated;

-- ── 5. Soumission (service role, après captcha) ───────────────────────
-- Limite : 3 demandes par empreinte d'IP et par jour (verrou consultatif : fiable sous requêtes parallèles).
-- Doublons (SPEC 1 §3) : même téléphone fixe ou mobile, même n° d'Ordre, même nom normalisé dans le même quartier,
-- ou GPS à moins de 30 m d'une pharmacie existante -> la demande est créée mais marquée `doublon_suspect`.
CREATE OR REPLACE FUNCTION public.soumettre_demande_interne(p jsonb, p_empreinte_ip text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_id uuid := gen_random_uuid();
    v_n int;
    v_raisons jsonb := '[]';
    v_fixe text := public.chiffres_telephone(p ->> 'telephone_fixe');
    v_mobile text := public.chiffres_telephone(p ->> 'telephone_mobile');
    v_nom text := public.normaliser_nom_pharmacie(p ->> 'nom_pharmacie');
    v_ordre text := lower(btrim(p ->> 'numero_ordre'));
    v_lat numeric := NULLIF(p ->> 'latitude', '')::numeric;
    v_lng numeric := NULLIF(p ->> 'longitude', '')::numeric;
BEGIN
    IF p_empreinte_ip IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtext('demande_ip:' || p_empreinte_ip));
        SELECT count(*) INTO v_n FROM public.demandes_partenaire
         WHERE empreinte_ip = p_empreinte_ip AND cree_le > now() - interval '1 day';
        IF v_n >= 3 THEN RETURN jsonb_build_object('erreur', 'limite_quotidienne'); END IF;
    END IF;

    IF EXISTS (SELECT 1 FROM public.pharmacies WHERE public.chiffres_telephone(telephone) IN (v_fixe, v_mobile) AND v_fixe <> '')
       OR EXISTS (SELECT 1 FROM public.demandes_partenaire d WHERE d.statut <> 'rejected'
                  AND (public.chiffres_telephone(d.telephone_fixe) IN (v_fixe, v_mobile) OR public.chiffres_telephone(d.telephone_mobile) IN (v_fixe, v_mobile))) THEN
        v_raisons := v_raisons || '"telephone"'::jsonb;
    END IF;
    IF EXISTS (SELECT 1 FROM public.demandes_partenaire d WHERE d.statut <> 'rejected' AND lower(btrim(d.numero_ordre)) = v_ordre) THEN
        v_raisons := v_raisons || '"numero_ordre"'::jsonb;
    END IF;
    IF v_nom <> '' AND (EXISTS (SELECT 1 FROM public.pharmacies ph WHERE ph.quartier_id = (p ->> 'quartier_id')::uuid AND public.normaliser_nom_pharmacie(ph.nom) = v_nom)
        OR EXISTS (SELECT 1 FROM public.demandes_partenaire d WHERE d.statut <> 'rejected' AND d.quartier_id = (p ->> 'quartier_id')::uuid
                   AND public.normaliser_nom_pharmacie(d.nom_pharmacie) = v_nom)) THEN
        v_raisons := v_raisons || '"nom_quartier"'::jsonb;
    END IF;
    IF v_lat IS NOT NULL AND v_lng IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.pharmacies ph WHERE ph.coordinates IS NOT NULL
           AND ST_DWithin(ph.coordinates, ST_SetSRID(ST_MakePoint(v_lng::float8, v_lat::float8), 4326)::geography, 30)) THEN
        v_raisons := v_raisons || '"gps_30m"'::jsonb;
    END IF;

    INSERT INTO public.demandes_partenaire (id, nom_pharmacie, quartier_id, adresse, telephone_fixe, nom_titulaire, numero_ordre, email_titulaire,
        telephone_mobile, latitude, longitude, horaires, participe_garde, consentement_conditions_le, consentement_messages_le,
        doublon_suspect, doublon_raisons, empreinte_ip, est_demo)
    VALUES (v_id, btrim(p ->> 'nom_pharmacie'), (p ->> 'quartier_id')::uuid, btrim(p ->> 'adresse'), p ->> 'telephone_fixe',
        btrim(p ->> 'nom_titulaire'), btrim(p ->> 'numero_ordre'), lower(btrim(p ->> 'email_titulaire')), p ->> 'telephone_mobile',
        v_lat, v_lng, COALESCE(p -> 'horaires', '{}'), COALESCE((p ->> 'participe_garde')::boolean, false), now(), now(),
        jsonb_array_length(v_raisons) > 0, v_raisons, p_empreinte_ip, public.mode_application() = 'demo');
    INSERT INTO public.documents_demande (demande_id, nature, chemin_stockage, type_mime, taille_octets)
    SELECT v_id, x ->> 'nature', x ->> 'chemin_stockage', x ->> 'type_mime', (x ->> 'taille_octets')::int
      FROM jsonb_array_elements(COALESCE(p -> 'documents', '[]')) x;
    PERFORM public.journaliser_onboarding(v_id, NULL, NULL, 'pharmacy', 'demande_soumise', jsonb_build_object('doublon_suspect', jsonb_array_length(v_raisons) > 0));
    RETURN jsonb_build_object('id', v_id, 'doublon_suspect', jsonb_array_length(v_raisons) > 0);
END $$;
REVOKE ALL ON FUNCTION public.soumettre_demande_interne(jsonb, text) FROM PUBLIC, anon, authenticated;

-- ── 6. Console admin : liste, détail, checklist ───────────────────────
CREATE OR REPLACE FUNCTION public.admin_lister_demandes(p_statut text DEFAULT NULL, p_doublons boolean DEFAULT NULL)
RETURNS TABLE (id uuid, statut text, nom_pharmacie text, quartier text, nom_titulaire text, doublon_suspect boolean, est_demo boolean,
               cree_le timestamptz, age_heures integer, en_retard boolean, cases_cochees integer, nb_documents integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    PERFORM public.exiger_admin();
    RETURN QUERY
    SELECT d.id, d.statut, d.nom_pharmacie, q.nom, d.nom_titulaire, d.doublon_suspect, d.est_demo, d.cree_le,
           (extract(epoch FROM now() - d.cree_le) / 3600)::int,
           d.statut IN ('submitted', 'in_review') AND now() - d.cree_le > interval '48 hours',   -- SLA : 48 h (calendaires ; cible spec en heures ouvrées)
           (SELECT count(*)::int FROM public.checklist_demande c WHERE c.demande_id = d.id),
           (SELECT count(*)::int FROM public.documents_demande x WHERE x.demande_id = d.id)
    FROM public.demandes_partenaire d JOIN public.quartiers q ON q.id = d.quartier_id
    WHERE (p_statut IS NULL OR d.statut = p_statut) AND (p_doublons IS NULL OR d.doublon_suspect = p_doublons)
    ORDER BY (d.statut IN ('submitted', 'in_review')) DESC, d.cree_le;
END $$;

CREATE OR REPLACE FUNCTION public.admin_detail_demande(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
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
                             FROM public.evenements_onboarding e WHERE e.demande_id = d.id), '[]'));
END $$;

CREATE OR REPLACE FUNCTION public.admin_demarrer_revue(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    PERFORM public.exiger_admin();
    UPDATE public.demandes_partenaire SET statut = 'in_review', reviewer_id = auth.uid() WHERE id = p_id AND statut IN ('submitted', 'needs_info');
    IF NOT FOUND THEN RAISE EXCEPTION 'Demande introuvable ou déjà décidée' USING ERRCODE = 'P0002'; END IF;
    PERFORM public.journaliser_onboarding(p_id, NULL, auth.uid(), 'admin', 'revue_demarree');
END $$;

CREATE OR REPLACE FUNCTION public.admin_basculer_checklist(p_id uuid, p_element text, p_coche boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    PERFORM public.exiger_admin();
    IF NOT EXISTS (SELECT 1 FROM public.demandes_partenaire WHERE id = p_id AND statut = 'in_review') THEN
        RAISE EXCEPTION 'La checklist se remplit pendant la revue (statut in_review)' USING ERRCODE = '55000';
    END IF;
    IF p_coche THEN
        INSERT INTO public.checklist_demande (demande_id, element, coche_par) VALUES (p_id, p_element, auth.uid())
        ON CONFLICT (demande_id, element) DO UPDATE SET coche_par = auth.uid(), coche_le = now();
    ELSE
        DELETE FROM public.checklist_demande WHERE demande_id = p_id AND element = p_element;
    END IF;
    PERFORM public.journaliser_onboarding(p_id, NULL, auth.uid(), 'admin', CASE WHEN p_coche THEN 'case_cochee' ELSE 'case_decochee' END, jsonb_build_object('element', p_element));
END $$;
REVOKE ALL ON FUNCTION public.admin_lister_demandes(text, boolean), public.admin_detail_demande(uuid), public.admin_demarrer_revue(uuid),
    public.admin_basculer_checklist(uuid, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_lister_demandes(text, boolean), public.admin_detail_demande(uuid), public.admin_demarrer_revue(uuid),
    public.admin_basculer_checklist(uuid, text, boolean) TO authenticated;

-- ── 7. Décisions (service role : appelées par l'Edge Function `decider-demande`, qui a vérifié l'admin) ──
-- Approuver : checklist de 5 cases obligatoire ; crée la pharmacie (verifie, NON publiée) dans la même transaction.
-- Idempotent : une demande déjà approuvée renvoie sa pharmacie (permet de relancer l'invitation).
CREATE OR REPLACE FUNCTION public.decider_demande_interne(p_id uuid, p_decision text, p_motif text, p_admin uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    d public.demandes_partenaire%ROWTYPE;
    v_phid uuid;
    v_slug text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.profils WHERE id = p_admin AND role = 'admin') THEN
        RAISE EXCEPTION 'Réservé à l''administrateur' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO d FROM public.demandes_partenaire WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Demande introuvable' USING ERRCODE = 'P0002'; END IF;
    IF p_decision NOT IN ('approve', 'reject', 'request_info') THEN RAISE EXCEPTION 'Décision inconnue' USING ERRCODE = '22023'; END IF;
    IF d.statut = 'approved' AND p_decision = 'approve' THEN
        RETURN jsonb_build_object('pharmacie_id', d.pharmacie_id, 'deja_approuvee', true);
    END IF;
    IF d.statut <> 'in_review' THEN RAISE EXCEPTION 'La demande doit être en revue (in_review)' USING ERRCODE = '55000'; END IF;

    IF p_decision IN ('reject', 'request_info') AND char_length(btrim(COALESCE(p_motif, ''))) < 3 THEN
        RAISE EXCEPTION 'Motif obligatoire' USING ERRCODE = '22023';
    END IF;

    IF p_decision = 'approve' THEN
        IF (SELECT count(*) FROM public.checklist_demande WHERE demande_id = p_id) < 5 THEN
            RAISE EXCEPTION 'Checklist incomplète : les 5 cases doivent être cochées' USING ERRCODE = '55000';
        END IF;
        v_slug := trim(both '-' FROM regexp_replace(public.normaliser_nom_pharmacie(d.nom_pharmacie), '\s+', '-', 'g')) || '-' || substr(replace(p_id::text, '-', ''), 1, 6);
        INSERT INTO public.pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, email, horaires, statut, source,
                                       est_publiee, est_demo, verified_at)
        VALUES (d.nom_pharmacie, v_slug, d.quartier_id, d.adresse, d.latitude, d.longitude, d.telephone_fixe, d.email_titulaire, d.horaires,
                'verifie', 'pharmacien', false, d.est_demo, now())
        RETURNING id INTO v_phid;
        UPDATE public.demandes_partenaire SET statut = 'approved', pharmacie_id = v_phid, reviewer_id = p_admin, decidee_le = now(), motif_decision = NULL WHERE id = p_id;
        INSERT INTO public.etat_onboarding_pharmacie (pharmacie_id, etat) VALUES (v_phid, '{}') ON CONFLICT (pharmacie_id) DO NOTHING;
        PERFORM public.journaliser_onboarding(p_id, v_phid, p_admin, 'admin', 'demande_approuvee');
        RETURN jsonb_build_object('pharmacie_id', v_phid);
    ELSIF p_decision = 'reject' THEN
        UPDATE public.demandes_partenaire SET statut = 'rejected', reviewer_id = p_admin, decidee_le = now(), motif_decision = btrim(p_motif) WHERE id = p_id;
        PERFORM public.journaliser_onboarding(p_id, NULL, p_admin, 'admin', 'demande_refusee', jsonb_build_object('motif', btrim(p_motif)));
        RETURN jsonb_build_object('refusee', true);
    ELSE
        UPDATE public.demandes_partenaire SET statut = 'needs_info', reviewer_id = p_admin, motif_decision = btrim(p_motif) WHERE id = p_id;
        PERFORM public.journaliser_onboarding(p_id, NULL, p_admin, 'admin', 'complements_demandes', jsonb_build_object('motif', btrim(p_motif)));
        RETURN jsonb_build_object('complements_demandes', true);
    END IF;
END $$;
REVOKE ALL ON FUNCTION public.decider_demande_interne(uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;

-- ── 8. Compléments : lien signé, sans compte (SPEC 1 §4) ──────────────
-- L'Edge Function `decider-demande` génère le jeton (seul son hachage est stocké) après une demande de compléments.
CREATE OR REPLACE FUNCTION public.definir_jeton_complements_interne(p_id uuid, p_hash text, p_expire timestamptz) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$ UPDATE public.demandes_partenaire SET jeton_complements_hash = p_hash, complements_expire_le = p_expire WHERE id = p_id AND statut = 'needs_info' $$;

-- Dépôt des compléments : jeton valide (hachage, non expiré, usage unique) -> la demande repasse en revue.
CREATE OR REPLACE FUNCTION public.deposer_complements_interne(p_hash text, p_message text, p_documents jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE d public.demandes_partenaire%ROWTYPE;
BEGIN
    SELECT * INTO d FROM public.demandes_partenaire WHERE jeton_complements_hash = p_hash FOR UPDATE;
    IF NOT FOUND OR d.statut <> 'needs_info' OR d.complements_expire_le IS NULL OR d.complements_expire_le < now() THEN
        RETURN jsonb_build_object('erreur', 'lien_invalide');
    END IF;
    INSERT INTO public.documents_demande (demande_id, nature, chemin_stockage, type_mime, taille_octets)
    SELECT d.id, 'autre', x ->> 'chemin_stockage', x ->> 'type_mime', (x ->> 'taille_octets')::int FROM jsonb_array_elements(COALESCE(p_documents, '[]')) x;
    UPDATE public.demandes_partenaire SET statut = 'in_review', jeton_complements_hash = NULL, complements_expire_le = NULL WHERE id = d.id;
    PERFORM public.journaliser_onboarding(d.id, NULL, NULL, 'pharmacy', 'complements_recus',
        jsonb_build_object('message', left(btrim(COALESCE(p_message, '')), 1000), 'nb_documents', jsonb_array_length(COALESCE(p_documents, '[]'))));
    RETURN jsonb_build_object('ok', true);
END $$;

-- ── 9. Activation du compte (service role : Edge Functions `decider-demande` et `activer-compte`) ──
CREATE OR REPLACE FUNCTION public.creer_jeton_activation_interne(p_demande uuid, p_hash text, p_heures int DEFAULT 72) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    -- Un seul jeton valide à la fois : les précédents sont invalidés.
    UPDATE public.jetons_activation SET utilise_le = COALESCE(utilise_le, now()) WHERE demande_id = p_demande AND utilise_le IS NULL;
    INSERT INTO public.jetons_activation (jeton_hash, demande_id, expire_le) VALUES (p_hash, p_demande, now() + make_interval(hours => p_heures));
END $$;

-- Consomme le jeton (usage unique, 72 h) et renvoie de quoi connecter l'utilisateur.
CREATE OR REPLACE FUNCTION public.consommer_jeton_activation_interne(p_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE j public.jetons_activation%ROWTYPE; d public.demandes_partenaire%ROWTYPE;
BEGIN
    SELECT * INTO j FROM public.jetons_activation WHERE jeton_hash = p_hash FOR UPDATE;
    IF NOT FOUND OR j.utilise_le IS NOT NULL OR j.expire_le < now() THEN RETURN jsonb_build_object('erreur', 'lien_invalide'); END IF;
    SELECT * INTO d FROM public.demandes_partenaire WHERE id = j.demande_id;
    IF d.statut <> 'approved' OR d.pharmacie_id IS NULL THEN RETURN jsonb_build_object('erreur', 'lien_invalide'); END IF;
    UPDATE public.jetons_activation SET utilise_le = now() WHERE jeton_hash = p_hash;
    PERFORM public.journaliser_onboarding(d.id, d.pharmacie_id, NULL, 'pharmacy', 'compte_active');
    RETURN jsonb_build_object('email', d.email_titulaire, 'pharmacie_id', d.pharmacie_id, 'demande_id', d.id);
END $$;

CREATE OR REPLACE FUNCTION public.marquer_invitation_interne(p_demande uuid, p_compte boolean, p_invitation boolean) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$ UPDATE public.demandes_partenaire SET compte_cree_le = CASE WHEN p_compte THEN COALESCE(compte_cree_le, now()) ELSE compte_cree_le END,
        invitation_envoyee_le = CASE WHEN p_invitation THEN now() ELSE invitation_envoyee_le END WHERE id = p_demande $$;

REVOKE ALL ON FUNCTION public.definir_jeton_complements_interne(uuid, text, timestamptz), public.deposer_complements_interne(text, text, jsonb),
    public.creer_jeton_activation_interne(uuid, text, int), public.consommer_jeton_activation_interne(text),
    public.marquer_invitation_interne(uuid, boolean, boolean) FROM PUBLIC, anon, authenticated;

-- Lie un utilisateur Auth à sa pharmacie (profil `pharmacien`). Refuse d'écraser un admin ou le profil d'une AUTRE pharmacie.
CREATE OR REPLACE FUNCTION public.lier_profil_pharmacien_interne(p_user uuid, p_pharmacie uuid, p_nom text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE pr public.profils%ROWTYPE;
BEGIN
    SELECT * INTO pr FROM public.profils WHERE id = p_user FOR UPDATE;
    IF FOUND AND (pr.role = 'admin' OR (pr.pharmacie_id IS NOT NULL AND pr.pharmacie_id <> p_pharmacie)) THEN
        RETURN jsonb_build_object('erreur', 'compte_conflit');
    END IF;
    INSERT INTO public.profils (id, role, pharmacie_id, nom_complet) VALUES (p_user, 'pharmacien', p_pharmacie, left(p_nom, 120))
    ON CONFLICT (id) DO UPDATE SET role = 'pharmacien', pharmacie_id = p_pharmacie;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION public.utilisateur_par_email_interne(p_email text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth
AS $$ SELECT id FROM auth.users WHERE lower(email) = lower(p_email) LIMIT 1 $$;

REVOKE ALL ON FUNCTION public.lier_profil_pharmacien_interne(uuid, uuid, text), public.utilisateur_par_email_interne(text) FROM PUBLIC, anon, authenticated;

COMMIT;
