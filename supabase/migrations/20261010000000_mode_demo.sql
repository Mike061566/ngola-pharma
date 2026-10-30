-- ============================================================
-- N'Gola Pharma — PR 6bis : mode démo (présentation aux pharmaciens)
-- SPEC 2 §4.0bis. PRODUCTION : à exécuter à la main, après relecture, après 20261009000000. Cette migration n'envoie rien.
--
-- Le mode démo ne contourne JAMAIS le garde-fou réglementaire : un médicament restreint reste bloqué, démo ou non.
-- Ici : bannière (lecture publique du mode), étiquette « Données de démonstration », liste blanche des comptes de test
-- (est_contact_demo) gérée par l'admin, messages « aurait été envoyé » visibles, et remise à zéro rejouable des données de démo.
-- ============================================================
BEGIN;

-- ── 1. Mode lisible par tous (bannière « MODE DÉMO — données fictives ») ──
-- Le mode n'est pas un secret ; config_routage, elle, reste réservée à l'admin.
CREATE OR REPLACE FUNCTION public.mode_public() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT public.mode_application() $$;
REVOKE ALL ON FUNCTION public.mode_public() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mode_public() TO anon, authenticated;

-- ── 2. Étiquette « Données de démonstration » : colonne ajoutée EN FIN de vue (les colonnes existantes ne bougent pas) ──
CREATE OR REPLACE VIEW public.v_pharmacies AS
SELECT p.id, p.nom, p.slug, p.quartier_id, p.adresse, p.coordinates, p.latitude, p.longitude, p.telephone, p.email, p.site_web,
       p.horaires, p.est_de_garde, p.garde_jusqu_a, p.statut, p.source, p.logo_url, p.note_moyenne, p.nombre_avis,
       p.created_at, p.updated_at, p.verified_at, q.nom AS quartier_nom, q.slug AS quartier_slug,
       p.est_demo
FROM public.pharmacies p
JOIN public.quartiers q ON q.id = p.quartier_id;

CREATE OR REPLACE VIEW public.v_meilleurs_prix AS
SELECT DISTINCT ON (s.medicament_id)
    s.medicament_id, m.nom AS medicament_nom, m.dci, m.dosage, s.pharmacie_id, ph.nom AS pharmacie_nom, ph.quartier_id,
    q.nom AS quartier_nom, s.prix_fcfa, s.en_stock,
    ph.est_demo AS pharmacie_est_demo
FROM public.stocks s
JOIN public.medicaments m ON m.id = s.medicament_id
JOIN public.pharmacies ph ON ph.id = s.pharmacie_id
JOIN public.quartiers q ON q.id = ph.quartier_id
WHERE s.en_stock = true
ORDER BY s.medicament_id, s.prix_fcfa ASC;

-- ── 3. Liste blanche des comptes de test (admin) ──────────────────────
-- Les adresses ne sortent JAMAIS en clair : seul un suffixe masqué est renvoyé.
CREATE OR REPLACE FUNCTION public.admin_liste_contacts(p_limite int DEFAULT 300)
RETURNS TABLE (contact_id uuid, pharmacie_id uuid, pharmacie_nom text, pharmacie_est_demo boolean, canal text, adresse_masquee text,
               est_contact_demo boolean, verifie boolean, desabonne boolean, bloque boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    PERFORM public.exiger_admin();
    RETURN QUERY
    SELECT c.id, p.id, p.nom, p.est_demo, c.canal,
           CASE WHEN c.adresse LIKE 'en_attente:%' THEN 'activation en cours' ELSE '••••' || right(c.adresse, 3) END,
           c.est_contact_demo, c.verifie_le IS NOT NULL, c.desabonne_le IS NOT NULL, c.bloque_le IS NOT NULL
    FROM public.contacts_pharmacie c JOIN public.pharmacies p ON p.id = c.pharmacie_id
    ORDER BY c.est_contact_demo DESC, p.nom, c.canal
    LIMIT LEAST(GREATEST(p_limite, 1), 1000);
END;
$$;

-- Ajouter / retirer un compte de la liste blanche (compte d'un pharmacien participant qui a activé le bot lui-même).
CREATE OR REPLACE FUNCTION public.admin_marquer_contact_demo(p_contact_id uuid, p_demo boolean)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE c public.contacts_pharmacie%ROWTYPE;
BEGIN
    PERFORM public.exiger_admin();
    SELECT * INTO c FROM public.contacts_pharmacie WHERE id = p_contact_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Contact introuvable' USING ERRCODE = 'P0002'; END IF;
    IF p_demo AND c.verifie_le IS NULL AND c.canal = 'telegram' THEN
        RAISE EXCEPTION 'Ce compte Telegram n''est pas encore activé (le bot ne peut écrire qu''après /start)' USING ERRCODE = '55000';
    END IF;
    UPDATE public.contacts_pharmacie SET est_contact_demo = p_demo WHERE id = c.id;
    PERFORM public.journaliser_admin(CASE WHEN p_demo THEN 'contact_demo_ajoute' ELSE 'contact_demo_retire' END, NULL,
        jsonb_build_object('contact_id', c.id, 'pharmacie_id', c.pharmacie_id, 'canal', c.canal));
END;
$$;

-- Compte de test de l'admin : crée un contact Telegram « en attente » sur une pharmacie (de démonstration), déjà dans la liste blanche,
-- et renvoie le jeton d'activation (affiché une seule fois ; seule son empreinte est stockée). Après /start, ce compte reçoit les
-- messages en vrai, et peut aussi jouer le rôle du patient (un compte de la liste blanche est joignable comme patient).
CREATE OR REPLACE FUNCTION public.admin_activer_telegram_demo(p_pharmacie_id uuid)
RETURNS TABLE (contact_id uuid, jeton text, expire_le timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_max int; v_h int; v_jeton text; v_id uuid; v_exp timestamptz;
BEGIN
    PERFORM public.exiger_admin();
    IF NOT EXISTS (SELECT 1 FROM public.pharmacies p WHERE p.id = p_pharmacie_id) THEN RAISE EXCEPTION 'Pharmacie introuvable' USING ERRCODE = 'P0002'; END IF;
    SELECT COALESCE((SELECT (valeur #>> '{}')::int FROM public.config_routage WHERE cle = 'max_contacts_telegram_par_pharmacie'), 3) INTO v_max;
    SELECT COALESCE((SELECT (valeur #>> '{}')::int FROM public.config_routage WHERE cle = 'jeton_telegram_pharmacie_h'), 72) INTO v_h;
    DELETE FROM public.contacts_pharmacie c WHERE c.pharmacie_id = p_pharmacie_id AND c.canal = 'telegram' AND c.verifie_le IS NULL
        AND NOT EXISTS (SELECT 1 FROM public.jetons_telegram j WHERE j.ref_id = c.id AND j.utilise_le IS NULL AND j.expire_le > now());
    IF (SELECT count(*) FROM public.contacts_pharmacie c WHERE c.pharmacie_id = p_pharmacie_id AND c.canal = 'telegram' AND c.desabonne_le IS NULL AND c.bloque_le IS NULL) >= v_max THEN
        RAISE EXCEPTION 'Nombre maximal de contacts Telegram atteint pour cette pharmacie' USING ERRCODE = '23514';
    END IF;
    v_jeton := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
    v_exp := now() + make_interval(hours => v_h);
    INSERT INTO public.contacts_pharmacie (pharmacie_id, canal, adresse, consentement_le, est_contact_demo)
        VALUES (p_pharmacie_id, 'telegram', 'en_attente:' || gen_random_uuid()::text, now(), true) RETURNING id INTO v_id;
    INSERT INTO public.jetons_telegram (jeton_hash, objet, ref_id, expire_le) VALUES (encode(sha256(convert_to(v_jeton, 'UTF8')), 'hex'), 'pharmacy_contact', v_id, v_exp);
    PERFORM public.journaliser_admin('compte_test_cree', NULL, jsonb_build_object('contact_id', v_id, 'pharmacie_id', p_pharmacie_id));
    RETURN QUERY SELECT v_id, v_jeton, v_exp;
END;
$$;

-- Messages qui « auraient été envoyés » (statut suppressed_demo) : jamais d'adresse, jamais de contenu.
CREATE OR REPLACE FUNCTION public.file_messages_demo(p_limite int DEFAULT 50)
RETURNS TABLE (cree_le timestamptz, type_destinataire text, canal text, modele text, alerte_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    PERFORM public.exiger_admin();
    RETURN QUERY
    SELECT o.cree_le, o.type_destinataire, o.canal, o.modele,
           COALESCE((SELECT e.alerte_id FROM public.envois_alerte e WHERE e.id::text = o.cle_base),
                    (SELECT a.id FROM public.alertes_routage a WHERE o.cle_base LIKE 'alerte:' || a.id::text || ':%' LIMIT 1))
    FROM public.notifications_outbox o WHERE o.statut = 'suppressed_demo' ORDER BY o.cree_le DESC LIMIT LEAST(GREATEST(p_limite, 1), 200);
END;
$$;

-- ── 4. Remise à zéro rejouable des données de démonstration ───────────
-- Appelée par scripts/demo-reset.js (service role) ou par l'admin. REFUSE de s'exécuter hors mode démo.
-- Efface : alertes (et leurs envois, réponses, ordres), file de messages, jetons patients, liste de blocage, journal des actions.
-- Conserve : catalogue, pharmacies, contacts et leur appartenance à la liste blanche (comptes réels des participants : ils sont
-- seulement réactivés si un /stop les avait désabonnés), réglages.
-- Rétablit : un échantillon DÉTERMINISTE de pharmacies de démonstration (les p_nb_pharmacies premières par slug) vérifiées, publiées,
-- ouvertes 24 h/24 ; leurs stocks (prix et états dérivés d'un hachage : toujours les mêmes) ; les autres pharmacies de démo dépubliées ;
-- la fiche fictive « Exemple restreint (démo) » (restreinte). N'ENVOIE RIEN. NE DÉCIDE JAMAIS de la classification d'un vrai médicament.
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
    FROM (SELECT id, slug FROM public.pharmacies WHERE est_demo ORDER BY slug LIMIT v_n) s;
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

REVOKE ALL ON FUNCTION public.admin_liste_contacts(int), public.admin_marquer_contact_demo(uuid, boolean), public.admin_activer_telegram_demo(uuid),
    public.file_messages_demo(int), public.reinitialiser_demo(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_liste_contacts(int), public.admin_marquer_contact_demo(uuid, boolean), public.admin_activer_telegram_demo(uuid),
    public.file_messages_demo(int), public.reinitialiser_demo(int) TO authenticated;     -- l'admin ; le service role passe par ses propres droits

COMMIT;
