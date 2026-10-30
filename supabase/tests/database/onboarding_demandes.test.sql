-- pgTAP — onboarding : demandes de pré-inscription (admin seul), doublons suspects, limite par IP, checklist,
-- décisions (approbation = pharmacie vérifiée mais NON publiée ; checklist complète obligatoire ; motifs obligatoires).
BEGIN;
SELECT plan(63);

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test'),
                                              ('00000000-0000-0000-0000-00000000f002', 'Autre quartier', 'autre-quartier');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude, telephone, statut, est_publiee, est_demo, horaires) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie de l''Étoile', 'etoile', '00000000-0000-0000-0000-00000000f001', 3.850000, 11.500000, '+237 222 11 22 33', 'verifie', true, true, '{}');
INSERT INTO profils (id, role, pharmacie_id) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1');

CREATE FUNCTION pg_temp.demande(p_nom text, p_ordre text, p_fixe text, p_mobile text, p_quartier uuid DEFAULT '00000000-0000-0000-0000-00000000f001',
                                p_lat numeric DEFAULT NULL, p_lng numeric DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('nom_pharmacie', p_nom, 'quartier_id', p_quartier, 'adresse', 'Rue test 1', 'telephone_fixe', p_fixe,
        'nom_titulaire', 'Dr Test', 'numero_ordre', p_ordre, 'email_titulaire', 'Titulaire@Exemple.test', 'telephone_mobile', p_mobile,
        'latitude', p_lat, 'longitude', p_lng, 'horaires', '{"lun":{"ouv":"08:00","fer":"20:00"}}'::jsonb, 'participe_garde', true) $f$;

-- ── Soumission (service) ──
SELECT is((soumettre_demande_interne(pg_temp.demande('Pharmacie Neuve', 'ORD-001', '+237222000001', '+237699000001', '00000000-0000-0000-0000-00000000f002'), 'ip1') ->> 'doublon_suspect')::boolean,
          false, 'demande saine : pas de doublon');
SELECT is((SELECT statut FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), 'submitted', 'statut initial submitted');
SELECT is((SELECT email_titulaire FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), 'titulaire@exemple.test', 'email normalisé en minuscules');
SELECT is((SELECT est_demo FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), true, 'mode démo : demande étiquetée démo');
SELECT is((SELECT count(*)::int FROM evenements_onboarding WHERE evenement = 'demande_soumise'), 1, 'audit : demande_soumise');

SELECT is(soumettre_demande_interne(pg_temp.demande('Autre', 'ord-001', '+237222000009', '+237699000009'), 'ip2') -> 'doublon_suspect', 'true'::jsonb, 'même n° d''Ordre : doublon');
SELECT is((SELECT doublon_raisons FROM demandes_partenaire WHERE telephone_fixe = '+237222000009'), '["numero_ordre"]'::jsonb, 'raison : numero_ordre');
SELECT is(soumettre_demande_interne(pg_temp.demande('Truc', 'ORD-002', '+237 222 11 22 33', '+237699000002'), 'ip3') -> 'doublon_suspect', 'true'::jsonb, 'téléphone d''une pharmacie existante : doublon');
SELECT is(soumettre_demande_interne(pg_temp.demande('PHARMACIE DE L''ÉTOILE', 'ORD-003', '+237222000003', '+237699000003'), 'ip4') -> 'doublon_suspect', 'true'::jsonb, 'même nom normalisé (accents, « pharmacie ») dans le même quartier : doublon');
SELECT is(soumettre_demande_interne(pg_temp.demande('Pharmacie Étoile', 'ORD-004', '+237222000004', '+237699000004', '00000000-0000-0000-0000-00000000f002'), 'ip5') -> 'doublon_suspect', 'false'::jsonb, 'même nom dans un autre quartier : pas de doublon');
SELECT is(soumettre_demande_interne(pg_temp.demande('Loin', 'ORD-005', '+237222000005', '+237699000005', '00000000-0000-0000-0000-00000000f002', 3.850100, 11.500000), 'ip6') -> 'doublon_suspect', 'true'::jsonb, 'GPS à ~11 m d''une pharmacie : doublon');
SELECT is(soumettre_demande_interne(pg_temp.demande('Loin2', 'ORD-006', '+237222000006', '+237699000006', '00000000-0000-0000-0000-00000000f002', 3.851000, 11.500000), 'ip7') -> 'doublon_suspect', 'false'::jsonb, 'GPS à ~110 m : pas de doublon');

-- ── Limite par IP : 3 par jour ──
SELECT lives_ok($$SELECT soumettre_demande_interne(pg_temp.demande('L1', 'ORD-101', '+237222000101', '+237699000101', '00000000-0000-0000-0000-00000000f002'), 'ipX')$$, 'IP : 1re');
SELECT lives_ok($$SELECT soumettre_demande_interne(pg_temp.demande('L2', 'ORD-102', '+237222000102', '+237699000102', '00000000-0000-0000-0000-00000000f002'), 'ipX')$$, 'IP : 2e');
SELECT lives_ok($$SELECT soumettre_demande_interne(pg_temp.demande('L3', 'ORD-103', '+237222000103', '+237699000103', '00000000-0000-0000-0000-00000000f002'), 'ipX')$$, 'IP : 3e');
SELECT is(soumettre_demande_interne(pg_temp.demande('L4', 'ORD-104', '+237222000104', '+237699000104', '00000000-0000-0000-0000-00000000f002'), 'ipX') ->> 'erreur', 'limite_quotidienne', 'IP : 4e refusée');
SELECT is((SELECT count(*)::int FROM demandes_partenaire WHERE numero_ordre = 'ORD-104'), 0, 'IP : la 4e n''est pas créée');

-- ── Accès : anon et pharmacien n'ont rien ──
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT * FROM demandes_partenaire$$, '42501', NULL, 'anon : demandes illisibles');
SELECT throws_ok($$INSERT INTO demandes_partenaire (nom_pharmacie) VALUES ('x')$$, '42501', NULL, 'anon : pas d''écriture directe');
SELECT throws_ok($$SELECT soumettre_demande_interne('{}', 'x')$$, '42501', NULL, 'anon : soumission directe refusée (passe par l''Edge Function)');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT is((SELECT count(*)::int FROM demandes_partenaire), 0, 'pharmacien : ne voit aucune demande');
SELECT is((SELECT count(*)::int FROM evenements_onboarding), 0, 'pharmacien : ne voit pas le journal');
SELECT throws_ok($$SELECT * FROM admin_lister_demandes()$$, '42501', NULL, 'pharmacien : liste refusée');
SELECT throws_ok($$SELECT admin_demarrer_revue((SELECT id FROM demandes_partenaire LIMIT 1))$$, '42501', NULL, 'pharmacien : démarrer la revue refusé');
SELECT throws_ok($$SELECT decider_demande_interne(gen_random_uuid(), 'approve', NULL, '00000000-0000-0000-0000-0000000000b1')$$, '42501', NULL, 'pharmacien : décision interne refusée (non exécutable)');
RESET ROLE;

-- ── Admin : revue, checklist, décisions ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT ok((SELECT count(*) FROM demandes_partenaire) >= 8, 'admin : voit les demandes');
SELECT throws_ok($$SELECT jeton_complements_hash FROM demandes_partenaire$$, '42501', NULL, 'admin : le hachage des jetons n''est pas lisible');
SELECT is((SELECT count(*)::int FROM admin_lister_demandes('submitted', true)), 4, 'admin : filtre doublons suspects (4)');
SELECT throws_ok($$SELECT admin_basculer_checklist((SELECT id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), 'ordre_ok', true)$$, '55000', NULL, 'checklist : avant la revue, refusée');
SELECT lives_ok($$SELECT admin_demarrer_revue((SELECT id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'))$$, 'revue démarrée');
SELECT is((SELECT statut FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), 'in_review', 'statut in_review');
SELECT lives_ok($$SELECT admin_basculer_checklist((SELECT id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), 'ordre_ok', true)$$, 'case cochée');
SELECT throws_ok($$SELECT admin_basculer_checklist((SELECT id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), 'inconnue', true)$$, '23514', NULL, 'case inconnue refusée');
RESET ROLE;

-- Approbation avec 1 case sur 5 : refusée
SELECT throws_ok($$SELECT decider_demande_interne((SELECT id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), 'approve', NULL, '00000000-0000-0000-0000-0000000000a1')$$,
                 '55000', NULL, 'approbation refusée tant que la checklist n''est pas complète');
INSERT INTO checklist_demande (demande_id, element, coche_par)
SELECT d.id, e, '00000000-0000-0000-0000-0000000000a1' FROM demandes_partenaire d, unnest(ARRAY['autorisation_ok', 'rappel_tel_ok', 'adresse_gps_ok', 'pas_doublon']) e
WHERE d.numero_ordre = 'ORD-001';
SELECT is((decider_demande_interne((SELECT id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), 'approve', NULL, '00000000-0000-0000-0000-0000000000a1') ->> 'pharmacie_id') IS NOT NULL, true, 'approbation : pharmacie créée');
SELECT is((SELECT statut::text FROM pharmacies WHERE id = (SELECT pharmacie_id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001')), 'verifie', 'pharmacie créée : vérifiée');
SELECT is((SELECT est_publiee FROM pharmacies WHERE id = (SELECT pharmacie_id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001')), false, 'pharmacie créée : NON publiée (règle de publication)');
SELECT is((SELECT est_demo FROM pharmacies WHERE id = (SELECT pharmacie_id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001')), true, 'pharmacie créée en mode démo : est_demo');
SELECT is((decider_demande_interne((SELECT id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), 'approve', NULL, '00000000-0000-0000-0000-0000000000a1') ->> 'deja_approuvee')::boolean, true, 'approbation idempotente (relance d''invitation)');
SELECT is((SELECT count(*)::int FROM pharmacies WHERE nom = 'Pharmacie Neuve'), 1, 'pas de seconde pharmacie');

-- Refus / compléments : motif obligatoire
UPDATE demandes_partenaire SET statut = 'in_review' WHERE numero_ordre = 'ORD-005';
SELECT throws_ok($$SELECT decider_demande_interne((SELECT id FROM demandes_partenaire WHERE numero_ordre = 'ORD-005'), 'reject', '', '00000000-0000-0000-0000-0000000000a1')$$, '22023', NULL, 'refus sans motif refusé');
SELECT is(decider_demande_interne((SELECT id FROM demandes_partenaire WHERE numero_ordre = 'ORD-005'), 'request_info', 'Attestation illisible', '00000000-0000-0000-0000-0000000000a1') ->> 'complements_demandes', 'true', 'compléments demandés avec motif');
SELECT is((SELECT statut FROM demandes_partenaire WHERE numero_ordre = 'ORD-005'), 'needs_info', 'statut needs_info');
SELECT throws_ok($$SELECT decider_demande_interne((SELECT id FROM demandes_partenaire WHERE numero_ordre = 'ORD-002'), 'reject', 'Hors périmètre', '00000000-0000-0000-0000-0000000000a1')$$, '55000', NULL, 'décision hors revue refusée (submitted)');
SELECT ok((SELECT count(*) FROM evenements_onboarding WHERE evenement IN ('demande_approuvee', 'complements_demandes', 'case_cochee')) >= 3, 'audit : chaque décision journalisée');

-- ── Jetons : activation (72 h, usage unique), compléments, profil ──
SELECT is((SELECT statut FROM demandes_partenaire WHERE numero_ordre = 'ORD-005'), 'needs_info', 'compléments : état de départ');
SELECT definir_jeton_complements_interne((SELECT id FROM demandes_partenaire WHERE numero_ordre = 'ORD-005'), 'hash-compl', now() + interval '14 days');
SELECT is(deposer_complements_interne('mauvais', 'x', '[]') ->> 'erreur', 'lien_invalide', 'compléments : jeton inconnu refusé');
SELECT is(deposer_complements_interne('hash-compl', 'Voici', '[{"chemin_stockage":"complements/x/a.pdf","type_mime":"application/pdf","taille_octets":10}]') ->> 'ok', 'true', 'compléments : déposés');
SELECT is((SELECT statut FROM demandes_partenaire WHERE numero_ordre = 'ORD-005'), 'in_review', 'compléments : la demande repasse en revue');
SELECT is((SELECT count(*)::int FROM documents_demande d JOIN demandes_partenaire p ON p.id = d.demande_id WHERE p.numero_ordre = 'ORD-005' AND d.nature = 'autre'), 1, 'compléments : document enregistré');
SELECT is(deposer_complements_interne('hash-compl', 'encore', '[]') ->> 'erreur', 'lien_invalide', 'compléments : usage unique');
UPDATE demandes_partenaire SET statut = 'needs_info', jeton_complements_hash = 'hash-expire', complements_expire_le = now() - interval '1 hour' WHERE numero_ordre = 'ORD-005';
SELECT is(deposer_complements_interne('hash-expire', 'tard', '[]') ->> 'erreur', 'lien_invalide', 'compléments : lien expiré refusé');

SELECT creer_jeton_activation_interne((SELECT id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), 'act-1', 72);
SELECT creer_jeton_activation_interne((SELECT id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), 'act-2', 72);
SELECT is(consommer_jeton_activation_interne('act-1') ->> 'erreur', 'lien_invalide', 'activation : un nouveau jeton invalide le précédent');
SELECT is(consommer_jeton_activation_interne('act-2') ->> 'email', 'titulaire@exemple.test', 'activation : jeton valide -> email du titulaire');
SELECT is(consommer_jeton_activation_interne('act-2') ->> 'erreur', 'lien_invalide', 'activation : usage unique');
SELECT creer_jeton_activation_interne((SELECT id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), 'act-3', 72);
UPDATE jetons_activation SET expire_le = now() - interval '1 minute' WHERE jeton_hash = 'act-3';
SELECT is(consommer_jeton_activation_interne('act-3') ->> 'erreur', 'lien_invalide', 'activation : jeton expiré (72 h)');

SELECT is(lier_profil_pharmacien_interne('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1', 'X') ->> 'erreur', 'compte_conflit', 'profil : un admin n''est jamais écrasé');
SELECT is(lier_profil_pharmacien_interne('00000000-0000-0000-0000-0000000000b1', (SELECT pharmacie_id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), 'X') ->> 'erreur', 'compte_conflit', 'profil : le compte d''une autre pharmacie n''est pas écrasé');
INSERT INTO auth.users (id, email) VALUES ('00000000-0000-0000-0000-0000000000b2', 'nouveau@test.local');
SELECT is(lier_profil_pharmacien_interne('00000000-0000-0000-0000-0000000000b2', (SELECT pharmacie_id FROM demandes_partenaire WHERE numero_ordre = 'ORD-001'), 'Dr Test') ->> 'ok', 'true', 'profil : nouvel utilisateur lié à sa pharmacie');
SELECT is((SELECT role FROM profils WHERE id = '00000000-0000-0000-0000-0000000000b2'), 'pharmacien', 'profil : rôle pharmacien (jamais admin)');
SELECT is(utilisateur_par_email_interne('NOUVEAU@test.local'), '00000000-0000-0000-0000-0000000000b2'::uuid, 'recherche d''utilisateur par email (insensible à la casse)');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT consommer_jeton_activation_interne('act-2')$$, '42501', NULL, 'pharmacien : activation directe refusée');
SELECT throws_ok($$SELECT lier_profil_pharmacien_interne('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000d1', 'x')$$, '42501', NULL, 'pharmacien : ne peut pas se lier lui-même');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
