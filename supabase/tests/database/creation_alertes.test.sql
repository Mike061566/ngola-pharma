-- pgTAP — creer_alerte_routage : liste de blocage, consentement SMS, fusion (30 min), limite de 5 par jour
-- (numéro et IP), garde-fou réglementaire (needs_review), accès réservé au serveur.
BEGIN;
SELECT plan(26);

INSERT INTO auth.users (id, email) VALUES ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local');
INSERT INTO profils (id, role) VALUES ('00000000-0000-0000-0000-0000000000a1', 'admin');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test');
INSERT INTO medicaments (id, nom, dosage, restreint, est_demo) VALUES
    ('00000000-0000-0000-0000-00000000e001', 'Produit libre', '100mg', false, true),
    ('00000000-0000-0000-0000-00000000e002', 'Exemple restreint (démo)', NULL, true, true),
    ('00000000-0000-0000-0000-00000000e003', 'Produit autre', '200mg', false, true),
    ('00000000-0000-0000-0000-00000000e004', 'Produit non démo', '300mg', false, false);

-- Raccourci : crée une alerte avec les paramètres usuels
CREATE FUNCTION pg_temp.creer(p_id text, p_med uuid, p_emp text, p_ip text DEFAULT 'ip1', p_canal text DEFAULT 'none',
                              p_consent boolean DEFAULT false, p_brute text DEFAULT NULL)
RETURNS TABLE (alerte_id uuid, id_public text, statut text, raison_revue text, fusionnee boolean, refus text)
LANGUAGE sql AS $$
    SELECT * FROM public.creer_alerte_routage(p_id, p_med, p_brute, '00000000-0000-0000-0000-00000000f001', NULL, NULL,
        'normal', p_canal, NULL, p_emp, p_ip, p_consent, now() + interval '2 hours')
$$;

-- ── Statut initial et garde-fou ───────────────────────────────────────
SELECT is((SELECT statut FROM pg_temp.creer('NG-A0000001', '00000000-0000-0000-0000-00000000e001', 'h1')), 'new',
    'médicament de démo non restreint (mode démo) : new');
SELECT is((SELECT statut || '/' || raison_revue FROM pg_temp.creer('NG-A0000002', '00000000-0000-0000-0000-00000000e002', 'h2')),
    'needs_review/restreint', 'médicament restreint : needs_review');
SELECT is((SELECT statut || '/' || raison_revue FROM pg_temp.creer('NG-A0000003', NULL, 'h3', 'ip3', 'none', false, 'truc inconnu')),
    'needs_review/non_reconnu', 'texte libre non reconnu : needs_review');
SELECT is((SELECT requete_brute FROM alertes_routage WHERE id_public = 'NG-A0000003'), 'truc inconnu', 'texte libre conservé (jamais envoyé aux pharmacies)');
SELECT is((SELECT requete_brute FROM alertes_routage WHERE id_public = 'NG-A0000001'), NULL, 'médicament reconnu : pas de texte libre');
UPDATE config_routage SET valeur = '"demo"' WHERE cle = 'mode_application';
SELECT is((SELECT statut || '/' || raison_revue FROM pg_temp.creer('NG-A0000004', '00000000-0000-0000-0000-00000000e004', 'h4', 'ip4')),
    'needs_review/classification_non_validee', 'fiche non démo et non validée : needs_review');

-- ── Consentement SMS ──────────────────────────────────────────────────
SELECT is((SELECT refus FROM pg_temp.creer('NG-B0000001', '00000000-0000-0000-0000-00000000e001', 'h5', 'ip5', 'sms', false)),
    'consentement_requis', 'SMS sans consentement : refusé');
SELECT * INTO TEMP TABLE _b2 FROM pg_temp.creer('NG-B0000002', '00000000-0000-0000-0000-00000000e001', 'h5', 'ip5', 'sms', true);
SELECT is((SELECT consentement_le IS NOT NULL FROM alertes_routage WHERE id_public = 'NG-B0000002'), true, 'SMS avec consentement : horodaté');

-- ── Fusion : même patient + même médicament < 30 min ──────────────────
SELECT is((SELECT fusionnee || '/' || id_public FROM pg_temp.creer('NG-C0000001', '00000000-0000-0000-0000-00000000e001', 'h1')),
    'true/NG-A0000001', 'même patient, même médicament : alerte existante renvoyée');
SELECT is((SELECT count(*)::int FROM alertes_routage WHERE empreinte_patient = 'h1'), 1, 'pas de doublon créé');
UPDATE alertes_routage SET cree_le = now() - interval '31 minutes' WHERE id_public = 'NG-A0000001';
SELECT is((SELECT fusionnee FROM pg_temp.creer('NG-C0000002', '00000000-0000-0000-0000-00000000e001', 'h1')), false, 'après 30 min : nouvelle alerte');
UPDATE alertes_routage SET statut = 'cancelled' WHERE id_public = 'NG-C0000002';
SELECT is((SELECT fusionnee FROM pg_temp.creer('NG-C0000003', '00000000-0000-0000-0000-00000000e001', 'h1')), false, 'alerte annulée : pas de fusion');
SELECT is((SELECT fusionnee FROM pg_temp.creer('NG-C0000004', '00000000-0000-0000-0000-00000000e003', 'h1')), false, 'autre médicament : pas de fusion');

-- ── Limite : 5 par jour et par numéro ; la 6e est refusée ─────────────
INSERT INTO alertes_routage (id_public, medicament_id, quartier_id, empreinte_patient, empreinte_ip, expire_le, cree_le, statut)
SELECT 'NG-L000000' || g, '00000000-0000-0000-0000-00000000e001', '00000000-0000-0000-0000-00000000f001', 'hlim', 'iplim' || g, now() + interval '1 hour',
       now() - interval '1 hour', 'expired' FROM generate_series(1, 5) g;
SELECT is((SELECT refus FROM pg_temp.creer('NG-L0000099', '00000000-0000-0000-0000-00000000e001', 'hlim', 'ipneuf')), 'limite_quotidienne',
    '6e alerte du même numéro dans la journée : refusée');
INSERT INTO alertes_routage (id_public, medicament_id, quartier_id, empreinte_patient, empreinte_ip, expire_le, cree_le, statut)
SELECT 'NG-M000000' || g, '00000000-0000-0000-0000-00000000e001', '00000000-0000-0000-0000-00000000f001', 'hm' || g, 'ipmax', now() + interval '1 hour',
       now() - interval '1 hour', 'expired' FROM generate_series(1, 5) g;
SELECT is((SELECT refus FROM pg_temp.creer('NG-M0000099', '00000000-0000-0000-0000-00000000e001', 'hautre', 'ipmax')), 'limite_quotidienne',
    '6e alerte depuis la même IP : refusée');
UPDATE alertes_routage SET cree_le = now() - interval '25 hours' WHERE empreinte_patient = 'hlim';
SELECT is((SELECT refus FROM pg_temp.creer('NG-L0000100', '00000000-0000-0000-0000-00000000e001', 'hlim', 'ipneuf2')), NULL, 'après 24 h : de nouveau accepté');

-- ── Liste de blocage ──────────────────────────────────────────────────
INSERT INTO patients_bloques (empreinte_patient, motif) VALUES ('hbloque', 'test'), ('ipbloquee', 'test');
SELECT is((SELECT refus FROM pg_temp.creer('NG-D0000001', '00000000-0000-0000-0000-00000000e001', 'hbloque', 'ipx')), 'bloque', 'numéro bloqué : refusé');
SELECT is((SELECT refus FROM pg_temp.creer('NG-D0000002', '00000000-0000-0000-0000-00000000e001', 'hok', 'ipbloquee')), 'bloque', 'IP bloquée : refusée');

-- ── Données du moteur de routage ──────────────────────────────────────
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude, statut, est_publiee) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie 1', 'pharmacie-1', '00000000-0000-0000-0000-00000000f001', 3.85, 11.50, 'verifie', true),
    ('00000000-0000-0000-0000-0000000000d2', 'Pharmacie 2', 'pharmacie-2', '00000000-0000-0000-0000-00000000f001', 3.86, 11.51, 'non_verifie', false);
INSERT INTO contacts_pharmacie (pharmacie_id, canal, adresse, consentement_le, verifie_le) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'telegram', '1234', now(), now()),
    ('00000000-0000-0000-0000-0000000000d1', 'sms', '+237600000001', now(), NULL);
INSERT INTO contacts_pharmacie (pharmacie_id, canal, adresse, consentement_le, verifie_le) VALUES
    ('00000000-0000-0000-0000-0000000000d2', 'telegram', '5678', now(), NULL);   -- Telegram non vérifié : ne compte pas
INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock) VALUES
    ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000e001', 1500, false);
SELECT is(jsonb_array_length(public.donnees_routage_pharmacies('00000000-0000-0000-0000-00000000e001')), 2, 'routage : toutes les pharmacies sont renvoyées (le moteur filtre)');
SELECT is((SELECT (x->>'contacts_actifs')::int FROM jsonb_array_elements(public.donnees_routage_pharmacies('00000000-0000-0000-0000-00000000e001')) x WHERE x->>'id' = '00000000-0000-0000-0000-0000000000d1'), 2, 'routage : contacts actifs comptés');
SELECT is((SELECT (x->>'contacts_actifs')::int FROM jsonb_array_elements(public.donnees_routage_pharmacies('00000000-0000-0000-0000-00000000e001')) x WHERE x->>'id' = '00000000-0000-0000-0000-0000000000d2'), 0, 'routage : Telegram non vérifié ignoré');
SELECT is((SELECT x->'stock'->>'statut_stock' FROM jsonb_array_elements(public.donnees_routage_pharmacies('00000000-0000-0000-0000-00000000e001')) x WHERE x->>'id' = '00000000-0000-0000-0000-0000000000d1'), 'rupture', 'routage : stock du médicament joint');
SELECT is((SELECT x->'taux_reponse_30j' FROM jsonb_array_elements(public.donnees_routage_pharmacies('00000000-0000-0000-0000-00000000e001')) x WHERE x->>'id' = '00000000-0000-0000-0000-0000000000d1'), 'null'::jsonb, 'routage : nouvelle pharmacie, taux de réponse nul');
INSERT INTO envois_alerte (alerte_id, pharmacie_id, vague, score, detail_score, code_reponse)
    SELECT id, '00000000-0000-0000-0000-0000000000d1', 1, 50, '{}', 'C1' FROM alertes_routage WHERE id_public = 'NG-A0000002';
SELECT is((SELECT (x->>'envois_derniere_heure')::int FROM jsonb_array_elements(public.donnees_routage_pharmacies('00000000-0000-0000-0000-00000000e001')) x WHERE x->>'id' = '00000000-0000-0000-0000-0000000000d1'), 1, 'routage : demandes de la dernière heure comptées');

-- ── Droits : serveur uniquement ───────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT * FROM public.creer_alerte_routage('NG-Z0000001', NULL, 'x', '00000000-0000-0000-0000-00000000f001', NULL, NULL, 'normal', 'none', NULL, 'hz', 'ipz', false, now())$$,
    '42501', NULL, 'admin navigateur : création directe refusée');
SET LOCAL ROLE anon;
SELECT throws_ok($$INSERT INTO alertes_routage (id_public, quartier_id, requete_brute, empreinte_patient, expire_le) VALUES ('NG-Z0000002', '00000000-0000-0000-0000-00000000f001', 'x', 'hz', now())$$,
    '42501', NULL, 'anonyme : écriture directe refusée');

SELECT * FROM finish();
ROLLBACK;
