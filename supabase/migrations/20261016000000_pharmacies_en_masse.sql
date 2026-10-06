-- ============================================================
-- N'Gola Pharma — onboarding, étape 5 : création en masse de pharmacies par l'admin (SPEC 1 §4), vérification une par une avec checklist
-- obligatoire, invitation d'une pharmacie existante. PRODUCTION : à exécuter à la main, après sauvegarde et après 20261015000000. Rétro-compatible.
-- Colonnes du CSV : nom, quartier, adresse, telephone, latitude, longitude, titulaire, numero_ordre, email, telephone_mobile.
-- Tout est créé `non_verifie` et NON publié. Une pharmacie créée en masse ne peut PAS passer `verifie` sans les 5 cases de la checklist
-- (garde en base : déclencheur, y compris contre une écriture directe de l'admin). Réservé à l'admin (« admin seul pour l'instant »).
-- ============================================================
BEGIN;

-- ── 1. Tables ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.lots_pharmacies (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    auteur_id   uuid NOT NULL REFERENCES auth.users(id),
    nom_fichier text NOT NULL CHECK (char_length(btrim(nom_fichier)) BETWEEN 1 AND 200),
    statut      text NOT NULL DEFAULT 'parsed' CHECK (statut IN ('parsed', 'previewed', 'committed', 'rolled_back', 'failed')),
    est_demo    boolean NOT NULL DEFAULT false,
    compteurs   jsonb NOT NULL DEFAULT '{}',
    cree_le     timestamptz NOT NULL DEFAULT now(),
    valide_le   timestamptz,
    annule_le   timestamptz
);

CREATE TABLE IF NOT EXISTS public.lignes_lots_pharmacies (
    lot_id        uuid NOT NULL REFERENCES public.lots_pharmacies(id) ON DELETE CASCADE,
    numero        integer NOT NULL CHECK (numero > 0),
    brut          jsonb NOT NULL,                       -- ce que le fichier contenait
    nom           text, quartier_id uuid REFERENCES public.quartiers(id), adresse text, telephone text,
    latitude      numeric(9,6), longitude numeric(9,6),
    titulaire     text, numero_ordre text, email text, telephone_mobile text,
    etat          text NOT NULL CHECK (etat IN ('pret', 'doublon', 'erreur')),
    problemes     jsonb NOT NULL DEFAULT '[]',          -- [{code, niveau: 'bloquant'|'avertissement', detail?}]
    resolution    text NOT NULL DEFAULT 'skip' CHECK (resolution IN ('create', 'skip')),
    pharmacie_id  uuid REFERENCES public.pharmacies(id) ON DELETE SET NULL,   -- renseigné à la validation
    PRIMARY KEY (lot_id, numero)
);

-- Identité du titulaire (données de pharmaciens, jamais de patients) : admin seul.
CREATE TABLE IF NOT EXISTS public.identites_pharmacies (
    pharmacie_id     uuid PRIMARY KEY REFERENCES public.pharmacies(id) ON DELETE CASCADE,
    nom_titulaire    text, numero_ordre text, email_titulaire text, telephone_mobile text,
    cree_le          timestamptz NOT NULL DEFAULT now()
);

-- Checklist de vérification d'une pharmacie (mêmes 5 cases que celle d'une demande)
CREATE TABLE IF NOT EXISTS public.checklist_verification_pharmacie (
    pharmacie_id uuid NOT NULL REFERENCES public.pharmacies(id) ON DELETE CASCADE,
    element      text NOT NULL CHECK (element IN ('ordre_ok', 'autorisation_ok', 'rappel_tel_ok', 'adresse_gps_ok', 'pas_doublon')),
    coche_par    uuid NOT NULL REFERENCES auth.users(id),
    coche_le     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (pharmacie_id, element)
);

ALTER TABLE public.pharmacies ADD COLUMN IF NOT EXISTS lot_creation_id uuid REFERENCES public.lots_pharmacies(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_pharmacies_lot_creation ON public.pharmacies (lot_creation_id) WHERE lot_creation_id IS NOT NULL;

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['lots_pharmacies', 'lignes_lots_pharmacies', 'identites_pharmacies', 'checklist_verification_pharmacie'] LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
        EXECUTE format('DROP POLICY IF EXISTS "Admin lit %s" ON public.%I', t, t);
        EXECUTE format('CREATE POLICY "Admin lit %s" ON public.%I FOR SELECT USING (auth_role() = ''admin'')', t, t);
        EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    END LOOP;
END $$;

-- ── 2. Garde : une pharmacie créée en masse ne passe `verifie` que par la fonction de vérification (checklist complète) ──
CREATE OR REPLACE FUNCTION public.garde_verification_pharmacie() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.lot_creation_id IS NOT NULL AND NEW.statut = 'verifie' AND OLD.statut IS DISTINCT FROM 'verifie'
       AND current_setting('app.verification_checklist', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Une pharmacie créée en masse ne peut être vérifiée que par admin_verifier_pharmacie (checklist de 5 cases complète)' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_pharmacies_garde_verification ON public.pharmacies;
CREATE TRIGGER trg_pharmacies_garde_verification BEFORE UPDATE OF statut ON public.pharmacies
    FOR EACH ROW EXECUTE FUNCTION public.garde_verification_pharmacie();

-- ── 3. Création du lot et ajout de lignes (500 au plus par appel, 1 000 par lot) ──
CREATE OR REPLACE FUNCTION public.pm_creer_lot(p_nom_fichier text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE v_id uuid;
BEGIN
    PERFORM public.exiger_admin();
    IF char_length(btrim(coalesce(p_nom_fichier, ''))) = 0 THEN RAISE EXCEPTION 'Nom de fichier obligatoire' USING ERRCODE = '22023'; END IF;
    INSERT INTO public.lots_pharmacies (auteur_id, nom_fichier, est_demo) VALUES (auth.uid(), left(btrim(p_nom_fichier), 200), public.mode_application() = 'demo') RETURNING id INTO v_id;
    RETURN v_id;
END $f$;

CREATE OR REPLACE FUNCTION public.lot_pharmacies_admin(p_lot uuid, p_verrou boolean DEFAULT false) RETURNS public.lots_pharmacies
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE l public.lots_pharmacies%ROWTYPE;
BEGIN
    PERFORM public.exiger_admin();
    IF p_verrou THEN SELECT * INTO l FROM public.lots_pharmacies WHERE id = p_lot FOR UPDATE; ELSE SELECT * INTO l FROM public.lots_pharmacies WHERE id = p_lot; END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'Lot introuvable' USING ERRCODE = 'P0002'; END IF;
    RETURN l;
END $f$;
REVOKE ALL ON FUNCTION public.lot_pharmacies_admin(uuid, boolean) FROM PUBLIC, anon, authenticated;

-- Ligne : { numero, nom, quartier, adresse, telephone, latitude, longitude, titulaire, numero_ordre, email, telephone_mobile, gps_invalide }
CREATE OR REPLACE FUNCTION public.pm_ajouter_lignes(p_lot uuid, p_lignes jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE
    l public.lots_pharmacies%ROWTYPE := public.lot_pharmacies_admin(p_lot, true);
    r record; v_n int;
    v_nom text; v_q uuid; v_qn text; v_prob jsonb; v_etat text; v_raisons jsonb;
    v_tel text; v_mob text; v_email text; v_ordre text; v_lat numeric; v_lng numeric;
BEGIN
    IF l.statut <> 'parsed' THEN RAISE EXCEPTION 'Ce lot n''accepte plus de lignes' USING ERRCODE = '55000'; END IF;
    IF jsonb_typeof(p_lignes) <> 'array' OR jsonb_array_length(p_lignes) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION '1 à 500 lignes par appel' USING ERRCODE = '22023'; END IF;
    SELECT count(*) INTO v_n FROM public.lignes_lots_pharmacies WHERE lot_id = p_lot;
    IF v_n + jsonb_array_length(p_lignes) > 1000 THEN RAISE EXCEPTION 'Limite de 1 000 lignes par lot' USING ERRCODE = '54000'; END IF;

    FOR r IN SELECT * FROM jsonb_to_recordset(p_lignes) AS x(numero int, nom text, quartier text, adresse text, telephone text, latitude numeric, longitude numeric,
                                                              titulaire text, numero_ordre text, email text, telephone_mobile text, gps_invalide boolean)
    LOOP
        IF r.numero IS NULL OR r.numero < 1 THEN RAISE EXCEPTION 'Numéro de ligne invalide' USING ERRCODE = '22023'; END IF;
        v_prob := '[]'::jsonb; v_raisons := '[]'::jsonb; v_q := NULL;
        v_nom := left(btrim(coalesce(r.nom, '')), 120);
        IF char_length(v_nom) < 2 THEN v_prob := v_prob || jsonb_build_object('code', 'nom_absent', 'niveau', 'bloquant'); END IF;
        -- Quartier : nom ou slug, sans accents ni casse
        v_qn := public.normaliser_texte_medicament(r.quartier);
        IF v_qn = '' THEN v_prob := v_prob || jsonb_build_object('code', 'quartier_absent', 'niveau', 'bloquant');
        ELSE
            SELECT id INTO v_q FROM public.quartiers WHERE public.normaliser_texte_medicament(nom) = v_qn OR public.normaliser_texte_medicament(replace(slug, '-', ' ')) = v_qn LIMIT 1;
            IF v_q IS NULL THEN v_prob := v_prob || jsonb_build_object('code', 'quartier_inconnu', 'niveau', 'bloquant', 'detail', left(btrim(r.quartier), 60)); END IF;
        END IF;
        -- Position : les deux ou aucune, dans les limites du Cameroun (sinon la ligne est refusée : un GPS faux dérègle la proximité)
        v_lat := r.latitude; v_lng := r.longitude;
        IF r.gps_invalide IS TRUE OR (v_lat IS NULL) <> (v_lng IS NULL) OR (v_lat IS NOT NULL AND (v_lat NOT BETWEEN 1.6 AND 13.1 OR v_lng NOT BETWEEN 8.4 AND 16.3)) THEN
            v_prob := v_prob || jsonb_build_object('code', 'gps_invalide', 'niveau', 'bloquant', 'detail', 'latitude et longitude ensemble, dans les limites du Cameroun'); v_lat := NULL; v_lng := NULL;
        END IF;
        -- Coordonnées facultatives : une valeur illisible est écartée (avertissement), jamais enregistrée de travers
        v_tel := NULLIF(btrim(coalesce(r.telephone, '')), ''); v_mob := NULLIF(btrim(coalesce(r.telephone_mobile, '')), '');
        IF v_tel IS NOT NULL AND v_tel !~ '^\+237[2368][0-9]{8}$' THEN v_prob := v_prob || jsonb_build_object('code', 'telephone_invalide', 'niveau', 'avertissement'); v_tel := NULL; END IF;
        IF v_mob IS NOT NULL AND v_mob !~ '^\+237[2368][0-9]{8}$' THEN v_prob := v_prob || jsonb_build_object('code', 'telephone_mobile_invalide', 'niveau', 'avertissement'); v_mob := NULL; END IF;
        v_email := NULLIF(lower(btrim(coalesce(r.email, ''))), '');
        IF v_email IS NOT NULL AND (v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR char_length(v_email) > 200) THEN v_prob := v_prob || jsonb_build_object('code', 'email_invalide', 'niveau', 'avertissement'); v_email := NULL; END IF;
        v_ordre := NULLIF(left(btrim(coalesce(r.numero_ordre, '')), 40), '');

        -- Doublons (SPEC 1 §3) contre les pharmacies, les identités et les demandes existantes
        IF NOT jsonb_path_exists(v_prob, '$[*] ? (@.niveau == "bloquant")') THEN
            IF (public.chiffres_telephone(v_tel) <> '' AND (EXISTS (SELECT 1 FROM public.pharmacies p WHERE public.chiffres_telephone(p.telephone) = public.chiffres_telephone(v_tel))
                   OR EXISTS (SELECT 1 FROM public.identites_pharmacies i WHERE public.chiffres_telephone(i.telephone_mobile) = public.chiffres_telephone(v_tel))
                   OR EXISTS (SELECT 1 FROM public.demandes_partenaire d WHERE d.statut <> 'rejected' AND public.chiffres_telephone(d.telephone_fixe) = public.chiffres_telephone(v_tel))))
               OR (public.chiffres_telephone(v_mob) <> '' AND (EXISTS (SELECT 1 FROM public.identites_pharmacies i WHERE public.chiffres_telephone(i.telephone_mobile) = public.chiffres_telephone(v_mob))
                   OR EXISTS (SELECT 1 FROM public.demandes_partenaire d WHERE d.statut <> 'rejected' AND public.chiffres_telephone(d.telephone_mobile) = public.chiffres_telephone(v_mob)))) THEN
                v_raisons := v_raisons || '"telephone"'::jsonb; END IF;
            IF v_ordre IS NOT NULL AND (EXISTS (SELECT 1 FROM public.identites_pharmacies i WHERE lower(btrim(i.numero_ordre)) = lower(v_ordre))
                   OR EXISTS (SELECT 1 FROM public.demandes_partenaire d WHERE d.statut <> 'rejected' AND lower(btrim(d.numero_ordre)) = lower(v_ordre))) THEN
                v_raisons := v_raisons || '"numero_ordre"'::jsonb; END IF;
            IF public.normaliser_nom_pharmacie(v_nom) <> '' AND (EXISTS (SELECT 1 FROM public.pharmacies p WHERE p.quartier_id = v_q AND public.normaliser_nom_pharmacie(p.nom) = public.normaliser_nom_pharmacie(v_nom))
                   OR EXISTS (SELECT 1 FROM public.demandes_partenaire d WHERE d.statut <> 'rejected' AND d.quartier_id = v_q AND public.normaliser_nom_pharmacie(d.nom_pharmacie) = public.normaliser_nom_pharmacie(v_nom))) THEN
                v_raisons := v_raisons || '"nom_quartier"'::jsonb; END IF;
            IF v_lat IS NOT NULL AND EXISTS (SELECT 1 FROM public.pharmacies p WHERE p.coordinates IS NOT NULL
                   AND ST_DWithin(p.coordinates, ST_SetSRID(ST_MakePoint(v_lng::float8, v_lat::float8), 4326)::geography, 30)) THEN
                v_raisons := v_raisons || '"gps_30m"'::jsonb; END IF;
            IF jsonb_array_length(v_raisons) > 0 THEN v_prob := v_prob || jsonb_build_object('code', 'doublon', 'niveau', 'avertissement', 'detail', v_raisons); END IF;
        END IF;

        v_etat := CASE WHEN jsonb_path_exists(v_prob, '$[*] ? (@.niveau == "bloquant")') THEN 'erreur' WHEN jsonb_array_length(v_raisons) > 0 THEN 'doublon' ELSE 'pret' END;
        INSERT INTO public.lignes_lots_pharmacies (lot_id, numero, brut, nom, quartier_id, adresse, telephone, latitude, longitude, titulaire, numero_ordre, email, telephone_mobile,
                                                    etat, problemes, resolution)
        VALUES (p_lot, r.numero, jsonb_build_object('nom', v_nom, 'quartier', left(btrim(coalesce(r.quartier, '')), 80), 'adresse', left(btrim(coalesce(r.adresse, '')), 250)),
                v_nom, v_q, NULLIF(left(btrim(coalesce(r.adresse, '')), 250), ''), v_tel, v_lat, v_lng, NULLIF(left(btrim(coalesce(r.titulaire, '')), 120), ''), v_ordre, v_email, v_mob,
                v_etat, v_prob, CASE WHEN v_etat = 'pret' THEN 'create' ELSE 'skip' END);
    END LOOP;
    RETURN jsonb_build_object('lignes', (SELECT count(*) FROM public.lignes_lots_pharmacies WHERE lot_id = p_lot));
END $f$;

CREATE OR REPLACE FUNCTION public.pm_compter_interne(p_lot uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT jsonb_build_object('total', count(*), 'pret', count(*) FILTER (WHERE etat = 'pret'), 'doublon', count(*) FILTER (WHERE etat = 'doublon'),
        'erreur', count(*) FILTER (WHERE etat = 'erreur'), 'a_creer', count(*) FILTER (WHERE resolution = 'create' AND etat <> 'erreur'),
        'avertissements', count(*) FILTER (WHERE jsonb_path_exists(problemes, '$[*] ? (@.niveau == "avertissement")'))) FROM public.lignes_lots_pharmacies WHERE lot_id = p_lot $$;
REVOKE ALL ON FUNCTION public.pm_compter_interne(uuid) FROM PUBLIC, anon, authenticated;

-- Finalisation : doublons DANS le fichier (la première occurrence est gardée), passage à « previewed »
CREATE OR REPLACE FUNCTION public.pm_finaliser_lot(p_lot uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE l public.lots_pharmacies%ROWTYPE := public.lot_pharmacies_admin(p_lot, true);
BEGIN
    IF l.statut NOT IN ('parsed', 'previewed') THEN RAISE EXCEPTION 'Lot déjà traité' USING ERRCODE = '55000'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.lignes_lots_pharmacies WHERE lot_id = p_lot) THEN RAISE EXCEPTION 'Le fichier ne contient aucune ligne exploitable' USING ERRCODE = '55000'; END IF;
    UPDATE public.lignes_lots_pharmacies li
       SET etat = 'doublon', resolution = 'skip',
           problemes = li.problemes || jsonb_build_object('code', 'doublon_fichier', 'niveau', 'avertissement', 'detail', 'une ligne plus haut décrit la même pharmacie')
      FROM (SELECT lot_id, numero, row_number() OVER (PARTITION BY cle ORDER BY numero) AS rang FROM (
              SELECT lot_id, numero, 'n|' || coalesce(quartier_id::text, '') || '|' || public.normaliser_nom_pharmacie(nom) AS cle FROM public.lignes_lots_pharmacies WHERE lot_id = p_lot AND etat <> 'erreur'
              UNION ALL SELECT lot_id, numero, 't|' || public.chiffres_telephone(telephone) FROM public.lignes_lots_pharmacies WHERE lot_id = p_lot AND etat <> 'erreur' AND public.chiffres_telephone(telephone) <> ''
              UNION ALL SELECT lot_id, numero, 'o|' || lower(numero_ordre) FROM public.lignes_lots_pharmacies WHERE lot_id = p_lot AND etat <> 'erreur' AND numero_ordre IS NOT NULL) c) d
     WHERE li.lot_id = d.lot_id AND li.numero = d.numero AND d.rang > 1 AND li.etat <> 'doublon'
       AND EXISTS (SELECT 1 FROM public.lignes_lots_pharmacies x WHERE x.lot_id = p_lot AND x.numero < li.numero AND x.etat <> 'erreur');
    UPDATE public.lots_pharmacies SET statut = 'previewed', compteurs = public.pm_compter_interne(p_lot) WHERE id = p_lot;
    RETURN public.pm_compter_interne(p_lot);
END $f$;

CREATE OR REPLACE FUNCTION public.pm_lire_lot(p_lot uuid, p_filtre text DEFAULT 'tous', p_limite int DEFAULT 100, p_decalage int DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $f$
DECLARE l public.lots_pharmacies%ROWTYPE := public.lot_pharmacies_admin(p_lot);
BEGIN
    RETURN jsonb_build_object(
        'lot', jsonb_build_object('id', l.id, 'nom_fichier', l.nom_fichier, 'statut', l.statut, 'est_demo', l.est_demo, 'cree_le', l.cree_le, 'valide_le', l.valide_le),
        'compteurs', public.pm_compter_interne(p_lot),
        'lignes', COALESCE((SELECT jsonb_agg(jsonb_build_object('numero', x.numero, 'nom', x.nom, 'quartier', (SELECT q.nom FROM public.quartiers q WHERE q.id = x.quartier_id),
                  'brut', x.brut, 'adresse', x.adresse, 'telephone', x.telephone, 'a_gps', x.latitude IS NOT NULL, 'a_titulaire', x.titulaire IS NOT NULL,
                  'etat', x.etat, 'problemes', x.problemes, 'resolution', x.resolution, 'pharmacie_id', x.pharmacie_id) ORDER BY x.numero)
              FROM (SELECT * FROM public.lignes_lots_pharmacies y WHERE y.lot_id = p_lot AND (p_filtre = 'tous' OR y.etat = p_filtre OR (p_filtre = 'avertissement' AND jsonb_path_exists(y.problemes, '$[*] ? (@.niveau == "avertissement")')))
                     ORDER BY y.numero OFFSET GREATEST(p_decalage, 0) LIMIT LEAST(GREATEST(p_limite, 1), 500)) x), '[]'::jsonb));
END $f$;

-- Actions : creer (malgré un doublon signalé), ignorer
CREATE OR REPLACE FUNCTION public.pm_corriger_ligne(p_lot uuid, p_numero int, p_action text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE l public.lots_pharmacies%ROWTYPE := public.lot_pharmacies_admin(p_lot, true); li public.lignes_lots_pharmacies%ROWTYPE;
BEGIN
    IF l.statut NOT IN ('parsed', 'previewed') THEN RAISE EXCEPTION 'Lot déjà traité' USING ERRCODE = '55000'; END IF;
    SELECT * INTO li FROM public.lignes_lots_pharmacies WHERE lot_id = p_lot AND numero = p_numero FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Ligne introuvable' USING ERRCODE = 'P0002'; END IF;
    IF p_action = 'ignorer' THEN UPDATE public.lignes_lots_pharmacies SET resolution = 'skip' WHERE lot_id = p_lot AND numero = p_numero;
    ELSIF p_action = 'creer' THEN
        IF li.etat = 'erreur' THEN RAISE EXCEPTION 'Ligne en erreur : corrigez le fichier et réimportez' USING ERRCODE = '55000'; END IF;
        UPDATE public.lignes_lots_pharmacies SET resolution = 'create' WHERE lot_id = p_lot AND numero = p_numero;
    ELSE RAISE EXCEPTION 'Action inconnue' USING ERRCODE = '22023'; END IF;
    RETURN public.pm_compter_interne(p_lot);
END $f$;

-- ── 4. Validation atomique : pharmacies `non_verifie`, NON publiées ───
CREATE OR REPLACE FUNCTION public.pm_valider_lot(p_lot uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE
    l public.lots_pharmacies%ROWTYPE := public.lot_pharmacies_admin(p_lot, true);
    r record; v_id uuid; v_creees int := 0;
BEGIN
    IF l.statut <> 'previewed' THEN RAISE EXCEPTION 'L''aperçu doit être finalisé avant la validation' USING ERRCODE = '55000'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.lignes_lots_pharmacies WHERE lot_id = p_lot AND resolution = 'create' AND etat <> 'erreur') THEN
        RAISE EXCEPTION 'Aucune ligne à créer' USING ERRCODE = '55000'; END IF;
    FOR r IN SELECT * FROM public.lignes_lots_pharmacies WHERE lot_id = p_lot AND resolution = 'create' AND etat <> 'erreur' ORDER BY numero LOOP
        v_id := gen_random_uuid();
        INSERT INTO public.pharmacies (id, nom, slug, quartier_id, adresse, latitude, longitude, telephone, email, horaires, statut, source, est_publiee, est_demo, lot_creation_id)
        VALUES (v_id, r.nom, trim(both '-' FROM regexp_replace(public.normaliser_nom_pharmacie(r.nom), '\s+', '-', 'g')) || '-' || substr(replace(v_id::text, '-', ''), 1, 6),
                r.quartier_id, r.adresse, r.latitude, r.longitude, r.telephone, r.email, '{}', 'non_verifie', 'admin', false, l.est_demo, p_lot);
        IF r.titulaire IS NOT NULL OR r.numero_ordre IS NOT NULL OR r.email IS NOT NULL OR r.telephone_mobile IS NOT NULL THEN
            INSERT INTO public.identites_pharmacies (pharmacie_id, nom_titulaire, numero_ordre, email_titulaire, telephone_mobile) VALUES (v_id, r.titulaire, r.numero_ordre, r.email, r.telephone_mobile);
        END IF;
        UPDATE public.lignes_lots_pharmacies SET pharmacie_id = v_id WHERE lot_id = p_lot AND numero = r.numero;
        PERFORM public.journaliser_onboarding(NULL, v_id, auth.uid(), 'admin', 'pharmacie_creee_en_masse', jsonb_build_object('lot', p_lot));
        v_creees := v_creees + 1;
    END LOOP;
    UPDATE public.lots_pharmacies SET statut = 'committed', valide_le = now(), compteurs = public.pm_compter_interne(p_lot) || jsonb_build_object('creees', v_creees) WHERE id = p_lot;
    RETURN jsonb_build_object('creees', v_creees, 'ignorees', (SELECT count(*) FROM public.lignes_lots_pharmacies WHERE lot_id = p_lot AND pharmacie_id IS NULL), 'annulable_jusqu_a', now() + interval '24 hours');
END $f$;

-- ── 5. Annulation sous 24 h : supprime SEULEMENT les pharmacies encore intactes (non vérifiées, sans stock, compte, contact, demande ni checklist) ──
CREATE OR REPLACE FUNCTION public.pm_annuler_lot(p_lot uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE l public.lots_pharmacies%ROWTYPE := public.lot_pharmacies_admin(p_lot, true); v_supp int; v_gardees int;
BEGIN
    IF l.statut <> 'committed' THEN RAISE EXCEPTION 'Seul un lot validé peut être annulé' USING ERRCODE = '55000'; END IF;
    IF l.valide_le < now() - interval '24 hours' THEN RAISE EXCEPTION 'Annulation impossible : plus de 24 h se sont écoulées' USING ERRCODE = '55000'; END IF;
    DELETE FROM public.pharmacies p WHERE p.lot_creation_id = p_lot AND p.statut = 'non_verifie' AND NOT p.est_publiee
        AND NOT EXISTS (SELECT 1 FROM public.stocks s WHERE s.pharmacie_id = p.id)
        AND NOT EXISTS (SELECT 1 FROM public.profils pr WHERE pr.pharmacie_id = p.id)
        AND NOT EXISTS (SELECT 1 FROM public.contacts_pharmacie c WHERE c.pharmacie_id = p.id)
        AND NOT EXISTS (SELECT 1 FROM public.demandes_partenaire d WHERE d.pharmacie_id = p.id)
        AND NOT EXISTS (SELECT 1 FROM public.checklist_verification_pharmacie k WHERE k.pharmacie_id = p.id);
    GET DIAGNOSTICS v_supp = ROW_COUNT;
    SELECT count(*) INTO v_gardees FROM public.pharmacies WHERE lot_creation_id = p_lot;
    UPDATE public.lots_pharmacies SET statut = 'rolled_back', annule_le = now() WHERE id = p_lot;
    PERFORM public.journaliser_onboarding(NULL, NULL, auth.uid(), 'admin', 'lot_pharmacies_annule', jsonb_build_object('lot', p_lot, 'supprimees', v_supp, 'conservees', v_gardees));
    RETURN jsonb_build_object('supprimees', v_supp, 'conservees', v_gardees);
END $f$;

CREATE OR REPLACE FUNCTION public.pm_abandonner_lot(p_lot uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE l public.lots_pharmacies%ROWTYPE := public.lot_pharmacies_admin(p_lot, true);
BEGIN
    IF l.statut NOT IN ('parsed', 'previewed') THEN RAISE EXCEPTION 'Seul un lot non validé peut être abandonné' USING ERRCODE = '55000'; END IF;
    UPDATE public.lots_pharmacies SET statut = 'failed' WHERE id = p_lot;
    DELETE FROM public.lignes_lots_pharmacies WHERE lot_id = p_lot;
END $f$;

CREATE OR REPLACE FUNCTION public.pm_historique() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $f$
BEGIN
    PERFORM public.exiger_admin();
    RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', l.id, 'nom_fichier', l.nom_fichier, 'statut', l.statut, 'cree_le', l.cree_le, 'valide_le', l.valide_le, 'compteurs', l.compteurs,
              'est_demo', l.est_demo, 'annulable', l.statut = 'committed' AND l.valide_le > now() - interval '24 hours') ORDER BY l.cree_le DESC)
        FROM (SELECT * FROM public.lots_pharmacies WHERE statut <> 'failed' ORDER BY cree_le DESC LIMIT 30) l), '[]'::jsonb);
END $f$;

-- ── 6. Vérification une par une : checklist de 5 cases OBLIGATOIRE ────
CREATE OR REPLACE FUNCTION public.admin_pharmacies_a_verifier(p_recherche text DEFAULT NULL, p_limite int DEFAULT 50, p_decalage int DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions
AS $f$
BEGIN
    PERFORM public.exiger_admin();
    RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'nom', t.nom, 'quartier', t.quartier, 'telephone', t.telephone, 'est_demo', t.est_demo, 'en_masse', t.lot_creation_id IS NOT NULL,
              'cases', t.cases, 'a_identite', t.a_identite) ORDER BY t.nom)
        FROM (SELECT p.id, p.nom, q.nom AS quartier, p.telephone, p.est_demo, p.lot_creation_id,
                     (SELECT count(*)::int FROM public.checklist_verification_pharmacie k WHERE k.pharmacie_id = p.id) AS cases,
                     EXISTS (SELECT 1 FROM public.identites_pharmacies i WHERE i.pharmacie_id = p.id) AS a_identite
                FROM public.pharmacies p JOIN public.quartiers q ON q.id = p.quartier_id
               WHERE p.statut = 'non_verifie' AND (p_recherche IS NULL OR public.normaliser_texte_medicament(p.nom) LIKE '%' || replace(public.normaliser_texte_medicament(p_recherche), ' ', '%') || '%')
               ORDER BY p.nom OFFSET GREATEST(p_decalage, 0) LIMIT LEAST(GREATEST(p_limite, 1), 200)) t), '[]'::jsonb);
END $f$;

-- Pharmacies vérifiées sans compte et dont l'email du titulaire est connu : à inviter.
CREATE OR REPLACE FUNCTION public.admin_pharmacies_a_inviter() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $f$
BEGIN
    PERFORM public.exiger_admin();
    RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'nom', p.nom, 'quartier', q.nom, 'est_demo', p.est_demo,
              'derniere_invitation', (SELECT max(j.cree_le) FROM public.jetons_activation j WHERE j.pharmacie_id = p.id)) ORDER BY p.nom)
        FROM public.pharmacies p JOIN public.quartiers q ON q.id = p.quartier_id JOIN public.identites_pharmacies i ON i.pharmacie_id = p.id
       WHERE p.statut = 'verifie' AND i.email_titulaire IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.profils pr WHERE pr.pharmacie_id = p.id)
         AND NOT EXISTS (SELECT 1 FROM public.demandes_partenaire d WHERE d.pharmacie_id = p.id)), '[]'::jsonb);
END $f$;

CREATE OR REPLACE FUNCTION public.admin_detail_verification(p_pharmacie uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $f$
DECLARE p public.pharmacies%ROWTYPE;
BEGIN
    PERFORM public.exiger_admin();
    SELECT * INTO p FROM public.pharmacies WHERE id = p_pharmacie;
    IF NOT FOUND THEN RAISE EXCEPTION 'Pharmacie introuvable' USING ERRCODE = 'P0002'; END IF;
    RETURN jsonb_build_object('pharmacie', jsonb_build_object('id', p.id, 'nom', p.nom, 'adresse', p.adresse, 'telephone', p.telephone, 'statut', p.statut, 'est_demo', p.est_demo,
            'latitude', p.latitude, 'longitude', p.longitude, 'en_masse', p.lot_creation_id IS NOT NULL, 'quartier', (SELECT nom FROM public.quartiers WHERE id = p.quartier_id)),
        'identite', (SELECT to_jsonb(i) - 'pharmacie_id' - 'cree_le' FROM public.identites_pharmacies i WHERE i.pharmacie_id = p_pharmacie),
        'checklist', COALESCE((SELECT jsonb_agg(jsonb_build_object('element', k.element, 'coche_le', k.coche_le)) FROM public.checklist_verification_pharmacie k WHERE k.pharmacie_id = p_pharmacie), '[]'),
        'compte', EXISTS (SELECT 1 FROM public.profils pr WHERE pr.pharmacie_id = p_pharmacie));
END $f$;

CREATE OR REPLACE FUNCTION public.admin_basculer_checklist_pharmacie(p_pharmacie uuid, p_element text, p_coche boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
BEGIN
    PERFORM public.exiger_admin();
    IF NOT EXISTS (SELECT 1 FROM public.pharmacies WHERE id = p_pharmacie AND statut = 'non_verifie') THEN RAISE EXCEPTION 'La checklist ne concerne que les pharmacies non vérifiées' USING ERRCODE = '55000'; END IF;
    IF p_coche THEN
        INSERT INTO public.checklist_verification_pharmacie (pharmacie_id, element, coche_par) VALUES (p_pharmacie, p_element, auth.uid())
        ON CONFLICT (pharmacie_id, element) DO UPDATE SET coche_par = auth.uid(), coche_le = now();
    ELSE DELETE FROM public.checklist_verification_pharmacie WHERE pharmacie_id = p_pharmacie AND element = p_element; END IF;
    PERFORM public.journaliser_onboarding(NULL, p_pharmacie, auth.uid(), 'admin', CASE WHEN p_coche THEN 'verification_case_cochee' ELSE 'verification_case_decochee' END, jsonb_build_object('element', p_element));
END $f$;

CREATE OR REPLACE FUNCTION public.admin_verifier_pharmacie(p_pharmacie uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
BEGIN
    PERFORM public.exiger_admin();
    IF NOT EXISTS (SELECT 1 FROM public.pharmacies WHERE id = p_pharmacie AND statut = 'non_verifie') THEN RAISE EXCEPTION 'Pharmacie introuvable ou déjà vérifiée' USING ERRCODE = 'P0002'; END IF;
    IF (SELECT count(*) FROM public.checklist_verification_pharmacie WHERE pharmacie_id = p_pharmacie) < 5 THEN
        RAISE EXCEPTION 'Checklist incomplète : les 5 cases doivent être cochées' USING ERRCODE = '55000'; END IF;
    PERFORM set_config('app.verification_checklist', 'on', true);
    UPDATE public.pharmacies SET statut = 'verifie', verified_at = now() WHERE id = p_pharmacie;
    PERFORM set_config('app.verification_checklist', 'off', true);
    PERFORM public.journaliser_onboarding(NULL, p_pharmacie, auth.uid(), 'admin', 'pharmacie_verifiee', '{}');
END $f$;

-- ── 7. Invitation d'une pharmacie existante (sans demande) ────────────
-- Le jeton d'activation peut désormais se rattacher à une pharmacie vérifiée (au lieu d'une demande approuvée).
ALTER TABLE public.jetons_activation ALTER COLUMN demande_id DROP NOT NULL;
ALTER TABLE public.jetons_activation ADD COLUMN IF NOT EXISTS pharmacie_id uuid REFERENCES public.pharmacies(id) ON DELETE CASCADE;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'jetons_activation_cible') THEN
        ALTER TABLE public.jetons_activation ADD CONSTRAINT jetons_activation_cible CHECK (demande_id IS NOT NULL OR pharmacie_id IS NOT NULL);
    END IF;
END $$;

-- Prépare l'invitation (service role, après contrôle de l'admin par l'Edge Function) : pharmacie VÉRIFIÉE, email du titulaire connu, pas de compte déjà lié.
CREATE OR REPLACE FUNCTION public.inviter_pharmacie_interne(p_pharmacie uuid, p_admin uuid, p_hash text, p_heures int DEFAULT 72) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE p public.pharmacies%ROWTYPE; v_email text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.profils WHERE id = p_admin AND role = 'admin') THEN RAISE EXCEPTION 'Réservé à l''administrateur' USING ERRCODE = '42501'; END IF;
    SELECT * INTO p FROM public.pharmacies WHERE id = p_pharmacie;
    IF NOT FOUND THEN RAISE EXCEPTION 'Pharmacie introuvable' USING ERRCODE = 'P0002'; END IF;
    IF p.statut <> 'verifie' THEN RAISE EXCEPTION 'Seule une pharmacie vérifiée peut être invitée' USING ERRCODE = '55000'; END IF;
    SELECT email_titulaire INTO v_email FROM public.identites_pharmacies WHERE pharmacie_id = p_pharmacie;
    IF v_email IS NULL THEN RAISE EXCEPTION 'Email du titulaire inconnu : impossible d''inviter' USING ERRCODE = '55000'; END IF;
    UPDATE public.jetons_activation SET utilise_le = COALESCE(utilise_le, now()) WHERE pharmacie_id = p_pharmacie AND utilise_le IS NULL;
    INSERT INTO public.jetons_activation (jeton_hash, demande_id, pharmacie_id, expire_le) VALUES (p_hash, NULL, p_pharmacie, now() + make_interval(hours => p_heures));
    PERFORM public.journaliser_onboarding(NULL, p_pharmacie, p_admin, 'admin', 'invitation_envoyee');
    RETURN jsonb_build_object('email', v_email, 'nom', p.nom, 'est_demo', p.est_demo);
END $f$;

CREATE OR REPLACE FUNCTION public.consommer_jeton_activation_interne(p_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE j public.jetons_activation%ROWTYPE; d public.demandes_partenaire%ROWTYPE; v_email text; v_ph uuid;
BEGIN
    SELECT * INTO j FROM public.jetons_activation WHERE jeton_hash = p_hash FOR UPDATE;
    IF NOT FOUND OR j.utilise_le IS NOT NULL OR j.expire_le < now() THEN RETURN jsonb_build_object('erreur', 'lien_invalide'); END IF;
    IF j.demande_id IS NOT NULL THEN
        SELECT * INTO d FROM public.demandes_partenaire WHERE id = j.demande_id;
        IF d.statut <> 'approved' OR d.pharmacie_id IS NULL THEN RETURN jsonb_build_object('erreur', 'lien_invalide'); END IF;
        v_email := d.email_titulaire; v_ph := d.pharmacie_id;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM public.pharmacies WHERE id = j.pharmacie_id AND statut = 'verifie') THEN RETURN jsonb_build_object('erreur', 'lien_invalide'); END IF;
        SELECT email_titulaire INTO v_email FROM public.identites_pharmacies WHERE pharmacie_id = j.pharmacie_id;
        IF v_email IS NULL THEN RETURN jsonb_build_object('erreur', 'lien_invalide'); END IF;
        v_ph := j.pharmacie_id;
    END IF;
    UPDATE public.jetons_activation SET utilise_le = now() WHERE jeton_hash = p_hash;
    PERFORM public.journaliser_onboarding(j.demande_id, v_ph, NULL, 'pharmacy', 'compte_active');
    RETURN jsonb_build_object('email', v_email, 'pharmacie_id', v_ph, 'demande_id', j.demande_id);
END $$;

-- ── 7bis. Remise à zéro de la démonstration : l'échantillon exclut les pharmacies créées en masse (la garde de vérification les protège) ──
CREATE OR REPLACE FUNCTION public.reinitialiser_demo(p_nb_pharmacies int DEFAULT 6)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_horaires jsonb := '{"lun":{"ouv":"00:00","fer":"23:59"},"mar":{"ouv":"00:00","fer":"23:59"},"mer":{"ouv":"00:00","fer":"23:59"},"jeu":{"ouv":"00:00","fer":"23:59"},"ven":{"ouv":"00:00","fer":"23:59"},"sam":{"ouv":"00:00","fer":"23:59"},"dim":{"ouv":"00:00","fer":"23:59"}}';
    v_ids uuid[]; v_slugs text[]; v_alertes int; v_msgs int; v_stocks int; v_empreinte text; v_warn jsonb := '[]'; v_n int;
BEGIN
    IF auth.uid() IS NOT NULL AND auth_role() <> 'admin' THEN RAISE EXCEPTION 'Réservé à l''administrateur' USING ERRCODE = '42501'; END IF;
    IF public.mode_application() <> 'demo' THEN RAISE EXCEPTION 'Remise à zéro refusée : l''application n''est pas en mode démo' USING ERRCODE = '55000'; END IF;
    v_n := LEAST(GREATEST(COALESCE(p_nb_pharmacies, 6), 1), 50);

    -- 1. Alertes et dépendances
    DELETE FROM public.journal_admin_alertes WHERE action <> 'config';
    SELECT count(*) INTO v_msgs FROM public.notifications_outbox;
    DELETE FROM public.notifications_outbox;
    DELETE FROM public.jetons_telegram WHERE objet = 'patient_alert' OR utilise_le IS NOT NULL OR expire_le < now();
    DELETE FROM public.patients_bloques;
    SELECT count(*) INTO v_alertes FROM public.alertes_routage;
    DELETE FROM public.alertes_routage;       -- cascade : envois, réponses, ordres

    -- 2. Contacts de la liste blanche : réactivés (un /stop pendant la démo ne doit pas bloquer la suivante)
    UPDATE public.contacts_pharmacie SET desabonne_le = NULL, bloque_le = NULL WHERE est_contact_demo;

    -- 3. Fiche fictive du garde-fou (§4.0bis) : restreinte, non validée, de démonstration
    INSERT INTO public.medicaments (nom, nom_commercial, dci, forme, dosage, categorie, ordonnance, description, est_demo, restreint, statut_catalogue)
        SELECT 'Exemple restreint (démo)', NULL, NULL, 'fictif', NULL, 'démonstration', false,
               'Médicament fictif pour montrer le garde-fou : jamais routé automatiquement.', true, true, 'actif'
        WHERE NOT EXISTS (SELECT 1 FROM public.medicaments m WHERE lower(btrim(m.nom)) = lower('Exemple restreint (démo)') AND COALESCE(m.dosage, '') = '');
    UPDATE public.medicaments SET restreint = true, est_demo = true, statut_catalogue = 'actif', classification_validee_le = NULL, validation_classification_id = NULL
        WHERE nom = 'Exemple restreint (démo)';

    -- 4. Pharmacies : échantillon déterministe vérifié et publié, les autres dépubliées
    SELECT array_agg(id ORDER BY slug), array_agg(slug ORDER BY slug) INTO v_ids, v_slugs
    FROM (SELECT id, slug FROM public.pharmacies WHERE est_demo AND lot_creation_id IS NULL ORDER BY slug LIMIT v_n) s;   -- hors pharmacies créées en masse : elles restent à vérifier une par une
    UPDATE public.pharmacies SET est_publiee = false, publiee_le = NULL WHERE est_demo AND NOT (id = ANY (COALESCE(v_ids, '{}')));
    IF v_ids IS NOT NULL THEN
        UPDATE public.pharmacies SET statut = 'verifie', est_publiee = true, publiee_le = now(), est_de_garde = false, garde_jusqu_a = NULL, horaires = v_horaires
        WHERE id = ANY (v_ids);
    END IF;

    -- 5. Stocks de l'échantillon : prix et états dérivés d'un hachage (identiques à chaque exécution)
    DELETE FROM public.stocks WHERE pharmacie_id = ANY (COALESCE(v_ids, '{}'));
    INSERT INTO public.stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock, statut_stock, date_maj, confirme_le, source)
    SELECT p.id, m.id,
           500 + 50 * abs(hashtextextended(m.nom || COALESCE(m.dosage, ''), 0) % 40) + 25 * abs(hashtextextended(p.slug || m.nom, 1) % 5),
           etat.st <> 'rupture', etat.st,
           now() - make_interval(hours => abs(hashtextextended(p.slug || m.nom, 3) % 96)::int),
           now() - make_interval(hours => abs(hashtextextended(p.slug || m.nom, 3) % 96)::int), 'admin'
    FROM public.pharmacies p
    CROSS JOIN public.medicaments m
    CROSS JOIN LATERAL (SELECT CASE WHEN abs(hashtextextended(p.slug || '|' || m.nom || COALESCE(m.dosage, ''), 2) % 100) < 70 THEN 'en_stock'
                                    WHEN abs(hashtextextended(p.slug || '|' || m.nom || COALESCE(m.dosage, ''), 2) % 100) < 85 THEN 'faible' ELSE 'rupture' END AS st) etat
    WHERE p.id = ANY (COALESCE(v_ids, '{}')) AND m.est_demo AND m.statut_catalogue = 'actif' AND m.nom <> 'Exemple restreint (démo)';
    GET DIAGNOSTICS v_stocks = ROW_COUNT;

    -- 6. Empreinte de l'état rétabli (sans horodatage) : identique d'une exécution à l'autre
    SELECT md5(COALESCE(string_agg(p.slug || '|' || m.nom || '|' || COALESCE(m.dosage, '') || '|' || s.prix_fcfa || '|' || s.statut_stock, ';' ORDER BY p.slug, m.nom, m.dosage), '')
               || '/' || COALESCE(array_to_string(v_slugs, ','), ''))
        INTO v_empreinte
    FROM public.stocks s JOIN public.pharmacies p ON p.id = s.pharmacie_id JOIN public.medicaments m ON m.id = s.medicament_id
    WHERE s.pharmacie_id = ANY (COALESCE(v_ids, '{}'));

    -- 7. Avertissements : ce qu'il manque pour jouer le scénario (jamais « corrigé » à la place du propriétaire)
    IF v_ids IS NULL THEN v_warn := v_warn || '"aucune_pharmacie_de_demo"'::jsonb; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.medicaments m WHERE m.est_demo AND m.statut_catalogue = 'actif' AND NOT m.restreint) THEN
        v_warn := v_warn || '"aucun_medicament_demo_non_restreint : la classification est une decision du proprietaire (console, onglet Classification)"'::jsonb; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.contacts_pharmacie c WHERE c.est_contact_demo AND c.desabonne_le IS NULL AND c.bloque_le IS NULL AND (c.canal <> 'telegram' OR c.verifie_le IS NOT NULL)) THEN
        v_warn := v_warn || '"aucun_compte_de_test : ajoutez les comptes a la liste blanche (console, Comptes de test)"'::jsonb; END IF;

    PERFORM public.journaliser_admin('reinitialiser_demo', NULL, jsonb_build_object('pharmacies', COALESCE(array_length(v_ids, 1), 0), 'stocks', v_stocks));
    RETURN jsonb_build_object('pharmacies_scenario', COALESCE(to_jsonb(v_slugs), '[]'), 'stocks', v_stocks, 'alertes_supprimees', v_alertes,
        'messages_supprimes', v_msgs, 'empreinte', v_empreinte, 'avertissements', v_warn);
END;
$$;

-- ── 8. Droits d'exécution ─────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.pm_creer_lot(text), public.pm_ajouter_lignes(uuid, jsonb), public.pm_finaliser_lot(uuid), public.pm_lire_lot(uuid, text, int, int),
    public.pm_corriger_ligne(uuid, int, text), public.pm_valider_lot(uuid), public.pm_annuler_lot(uuid), public.pm_abandonner_lot(uuid), public.pm_historique(),
    public.admin_pharmacies_a_verifier(text, int, int), public.admin_pharmacies_a_inviter(), public.admin_detail_verification(uuid), public.admin_basculer_checklist_pharmacie(uuid, text, boolean),
    public.admin_verifier_pharmacie(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pm_creer_lot(text), public.pm_ajouter_lignes(uuid, jsonb), public.pm_finaliser_lot(uuid), public.pm_lire_lot(uuid, text, int, int),
    public.pm_corriger_ligne(uuid, int, text), public.pm_valider_lot(uuid), public.pm_annuler_lot(uuid), public.pm_abandonner_lot(uuid), public.pm_historique(),
    public.admin_pharmacies_a_verifier(text, int, int), public.admin_pharmacies_a_inviter(), public.admin_detail_verification(uuid), public.admin_basculer_checklist_pharmacie(uuid, text, boolean),
    public.admin_verifier_pharmacie(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.inviter_pharmacie_interne(uuid, uuid, text, int) FROM PUBLIC, anon, authenticated;

COMMIT;
