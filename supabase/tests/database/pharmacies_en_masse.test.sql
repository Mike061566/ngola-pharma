-- pgTAP — création en masse de pharmacies (admin seul) : validation par ligne, doublons (base et fichier), aperçu, corrections, validation atomique
-- (non_verifie, NON publiées), garde « pas de verifie sans checklist complète », annulation sous 24 h, invitation d'une pharmacie vérifiée.
BEGIN;
SELECT plan(77);

INSERT INTO auth.users (id, email) VALUES ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'), ('00000000-0000-0000-0000-0000000000b1', 'p1@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Bastos', 'bastos'), ('00000000-0000-0000-0000-00000000f002', 'Mvog-Ada', 'mvog-ada');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude, telephone, statut, est_demo, horaires) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie de l''Étoile', 'etoile', '00000000-0000-0000-0000-00000000f001', 3.850000, 11.500000, '+237 222 11 22 33', 'verifie', true, '{}'),
    ('00000000-0000-0000-0000-0000000000d2', 'Pharmacie ancienne', 'ancienne', '00000000-0000-0000-0000-00000000f002', 3.80, 11.40, '+237 222 44 55 66', 'non_verifie', true, '{}');
INSERT INTO identites_pharmacies (pharmacie_id, nom_titulaire, numero_ordre) VALUES ('00000000-0000-0000-0000-0000000000d1', 'Dr Existant', 'ORD-EXIST');
INSERT INTO profils (id, role, pharmacie_id) VALUES ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL), ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1');
CREATE TEMP TABLE ctx (cle text PRIMARY KEY, valeur text);
GRANT ALL ON ctx TO PUBLIC;

-- ── Accès : admin seul ──
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT pm_creer_lot('x.csv')$$, '42501', NULL, 'anon : création de lot refusée');
SELECT throws_ok($$SELECT * FROM lots_pharmacies$$, '42501', NULL, 'anon : lots illisibles');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT pm_creer_lot('x.csv')$$, '42501', NULL, 'pharmacien : création de lot refusée');
SELECT throws_ok($$SELECT pm_historique()$$, '42501', NULL, 'pharmacien : historique refusé');
SELECT throws_ok($$SELECT admin_pharmacies_a_verifier()$$, '42501', NULL, 'pharmacien : liste à vérifier refusée');
SELECT throws_ok($$SELECT admin_verifier_pharmacie('00000000-0000-0000-0000-0000000000d2')$$, '42501', NULL, 'pharmacien : vérification refusée');
SELECT is((SELECT count(*)::int FROM identites_pharmacies), 0, 'pharmacien : identités de titulaires illisibles (RLS)');
SELECT is((SELECT count(*)::int FROM lignes_lots_pharmacies), 0, 'pharmacien : lignes de lots illisibles (RLS)');
RESET ROLE;

-- ── Lot : lignes, validation par ligne, doublons ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT pm_creer_lot('  ')$$, '22023', NULL, 'nom de fichier obligatoire');
INSERT INTO ctx VALUES ('lot', pm_creer_lot('pharmacies.csv')::text);
SELECT throws_ok($$SELECT pm_finaliser_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'))$$, '55000', NULL, 'finalisation refusée : lot vide');
SELECT throws_ok($$SELECT pm_ajouter_lignes((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), (SELECT jsonb_agg(jsonb_build_object('numero', g, 'nom', 'X', 'quartier', 'bastos')) FROM generate_series(1, 501) g))$$, '22023', NULL, 'plus de 500 lignes par appel refusé');
SELECT is((pm_ajouter_lignes((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), $j$[
 {"numero":1,"nom":"Pharmacie Nouvelle Aube","quartier":"bastos","adresse":"Rue 1.234","telephone":"+237222000001","latitude":3.90,"longitude":11.55,"titulaire":"Dr A","numero_ordre":"ORD-100","email":"A@Ex.test","telephone_mobile":"+237699000001"},
 {"numero":2,"nom":"Pharmacie du Marché","quartier":"MVOG ADA","telephone":"+237222000002"},
 {"numero":3,"nom":"Pharmacie Fantôme","quartier":"Inconnuville"},
 {"numero":4,"nom":"","quartier":"bastos"},
 {"numero":5,"nom":"Pharmacie Hors Pays","quartier":"bastos","latitude":48.8,"longitude":2.3},
 {"numero":6,"nom":"Pharmacie Moitié GPS","quartier":"bastos","latitude":3.9},
 {"numero":7,"nom":"Pharmacie Téléphone Illisible","quartier":"bastos","telephone":"123","email":"pas-un-email"},
 {"numero":8,"nom":"Pharmacie Doublon Tel","quartier":"mvog-ada","telephone":"+237222112233"},
 {"numero":9,"nom":"Pharmacie Doublon Ordre","quartier":"mvog-ada","numero_ordre":"ord-exist"},
 {"numero":10,"nom":"PHARMACIE DE L'ETOILE","quartier":"Bastos"},
 {"numero":11,"nom":"Pharmacie Voisine","quartier":"mvog-ada","latitude":3.8501,"longitude":11.5000},
 {"numero":12,"nom":"Pharmacie Nouvelle Aube","quartier":"bastos"}
]$j$::jsonb) ->> 'lignes')::int, 12, '12 lignes ajoutées');
RESET ROLE;
SELECT is((SELECT etat || '/' || resolution FROM lignes_lots_pharmacies WHERE numero = 1 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'pret/create', 'ligne 1 : prête, à créer');
SELECT is((SELECT etat FROM lignes_lots_pharmacies WHERE numero = 2 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')) || '/' || (SELECT quartier_id::text FROM lignes_lots_pharmacies WHERE numero = 2 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'pret/00000000-0000-0000-0000-00000000f002', 'ligne 2 : « MVOG ADA » reconnu (casse, tiret)');
SELECT is((SELECT problemes -> 0 ->> 'code' FROM lignes_lots_pharmacies WHERE numero = 3 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'quartier_inconnu', 'ligne 3 : quartier inconnu -> erreur');
SELECT is((SELECT etat FROM lignes_lots_pharmacies WHERE numero = 4 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'erreur', 'ligne 4 : nom absent -> erreur');
SELECT is((SELECT problemes -> 0 ->> 'code' FROM lignes_lots_pharmacies WHERE numero = 5 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'gps_invalide', 'ligne 5 : GPS hors du Cameroun -> erreur');
SELECT is((SELECT problemes -> 0 ->> 'code' FROM lignes_lots_pharmacies WHERE numero = 6 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'gps_invalide', 'ligne 6 : latitude sans longitude -> erreur');
SELECT is((SELECT etat || '/' || coalesce(telephone, 'NULL') || '/' || coalesce(email, 'NULL') FROM lignes_lots_pharmacies WHERE numero = 7 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'pret/NULL/NULL', 'ligne 7 : téléphone et email illisibles écartés (jamais enregistrés de travers), ligne créée');
SELECT is((SELECT jsonb_array_length(problemes) FROM lignes_lots_pharmacies WHERE numero = 7 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 2, 'ligne 7 : deux avertissements');
SELECT is((SELECT email FROM lignes_lots_pharmacies WHERE numero = 1 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'a@ex.test', 'email normalisé en minuscules');
SELECT is((SELECT problemes -> 0 -> 'detail' FROM lignes_lots_pharmacies WHERE numero = 8 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), '["telephone"]'::jsonb, 'ligne 8 : même téléphone qu''une pharmacie existante');
SELECT is((SELECT problemes -> 0 -> 'detail' FROM lignes_lots_pharmacies WHERE numero = 9 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), '["numero_ordre"]'::jsonb, 'ligne 9 : même numéro d''Ordre (casse ignorée)');
SELECT is((SELECT problemes -> 0 -> 'detail' FROM lignes_lots_pharmacies WHERE numero = 10 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), '["nom_quartier"]'::jsonb, 'ligne 10 : même nom normalisé dans le même quartier');
SELECT is((SELECT problemes -> 0 -> 'detail' FROM lignes_lots_pharmacies WHERE numero = 11 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), '["gps_30m"]'::jsonb, 'ligne 11 : à moins de 30 m d''une pharmacie existante');
SELECT is((SELECT count(*)::int FROM lignes_lots_pharmacies WHERE lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot') AND etat = 'doublon' AND resolution = 'skip'), 4, 'les doublons détectés sont ignorés par défaut (4 avant finalisation)');

-- ── Finalisation et corrections ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT pm_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'))$$, '55000', NULL, 'validation refusée avant la finalisation de l''aperçu');
SELECT is(pm_finaliser_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot')) - 'avertissements', '{"total": 12, "pret": 3, "doublon": 5, "erreur": 4, "a_creer": 3}'::jsonb, 'finalisation : 3 prêtes, 5 doublons (dont 1 dans le fichier), 4 erreurs');
SELECT is(jsonb_array_length(pm_lire_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 'doublon') -> 'lignes'), 5, 'aperçu filtré : 5 doublons');
SELECT is(pm_lire_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 'tous', 1, 0) -> 'lignes' -> 0 ->> 'quartier', 'Bastos', 'aperçu : le quartier est affiché par son nom');
RESET ROLE;
SELECT is((SELECT problemes @> '[{"code": "doublon_fichier"}]' FROM lignes_lots_pharmacies WHERE numero = 12 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), true, 'ligne 12 : doublon de la ligne 1 dans le fichier (la première est gardée)');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT pm_corriger_ligne((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 3, 'creer')$$, '55000', NULL, 'ligne en erreur : « créer » refusé');
SELECT throws_ok($$SELECT pm_corriger_ligne((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 3, 'danser')$$, '22023', NULL, 'action inconnue refusée');
SELECT is((pm_corriger_ligne((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 8, 'creer') ->> 'a_creer')::int, 4, 'doublon 8 créé malgré l''avertissement (décision de l''admin) : 4 à créer');
SELECT is((pm_corriger_ligne((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 2, 'ignorer') ->> 'a_creer')::int, 3, 'ligne 2 ignorée : 3 à créer');

-- ── Validation ──
SELECT is(pm_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot')) - 'annulable_jusqu_a', '{"creees": 3, "ignorees": 9}'::jsonb, 'validation : 3 pharmacies créées');
SELECT throws_ok($$SELECT pm_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'))$$, '55000', NULL, 'double validation refusée');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM pharmacies WHERE lot_creation_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot') AND statut = 'non_verifie' AND NOT est_publiee), 3, 'toutes créées « non_verifie » et NON publiées');
SELECT is((SELECT est_demo FROM pharmacies WHERE nom = 'Pharmacie Nouvelle Aube'), true, 'mode démo : pharmacies créées étiquetées démo');
SELECT is((SELECT count(*)::int FROM identites_pharmacies i JOIN pharmacies p ON p.id = i.pharmacie_id WHERE p.lot_creation_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 1, 'identité du titulaire enregistrée seulement quand elle est fournie (1 sur 3)');
SELECT is((SELECT i.numero_ordre FROM identites_pharmacies i JOIN pharmacies p ON p.id = i.pharmacie_id WHERE p.nom = 'Pharmacie Nouvelle Aube'), 'ORD-100', 'numéro d''Ordre conservé');
SELECT ok((SELECT slug ~ '^nouvelle-aube-[0-9a-f]{6}$' FROM pharmacies WHERE nom = 'Pharmacie Nouvelle Aube'), 'slug lisible et unique');
SELECT is((SELECT count(*)::int FROM evenements_onboarding WHERE evenement = 'pharmacie_creee_en_masse'), 3, 'audit : une entrée par pharmacie créée');

-- ── Garde : jamais `verifie` sans checklist complète ──
SELECT throws_ok($$UPDATE pharmacies SET statut = 'verifie' WHERE nom = 'Pharmacie Nouvelle Aube'$$, '42501', NULL, 'écriture directe vers « verifie » refusée pour une pharmacie créée en masse (même en SQL)');
SELECT lives_ok($$UPDATE pharmacies SET statut = 'verifie' WHERE id = '00000000-0000-0000-0000-0000000000d2'$$, 'les autres pharmacies (hors import en masse) ne sont pas concernées par la garde');
UPDATE pharmacies SET statut = 'non_verifie' WHERE id = '00000000-0000-0000-0000-0000000000d2';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
INSERT INTO ctx SELECT 'aube', id::text FROM pharmacies WHERE nom = 'Pharmacie Nouvelle Aube';
SELECT is(jsonb_array_length(admin_pharmacies_a_verifier()), 4, 'à vérifier : 3 créées en masse + la pharmacie ancienne');
SELECT is(jsonb_array_length(admin_pharmacies_a_verifier('aube')), 1, 'à vérifier : recherche par nom');
SELECT throws_ok($$SELECT admin_verifier_pharmacie((SELECT valeur::uuid FROM ctx WHERE cle = 'aube'))$$, '55000', NULL, 'vérification refusée : checklist vide');
SELECT throws_ok($$SELECT admin_basculer_checklist_pharmacie((SELECT valeur::uuid FROM ctx WHERE cle = 'aube'), 'inconnue', true)$$, '23514', NULL, 'case inconnue refusée');
SELECT admin_basculer_checklist_pharmacie((SELECT valeur::uuid FROM ctx WHERE cle = 'aube'), e, true) FROM unnest(ARRAY['ordre_ok', 'autorisation_ok', 'rappel_tel_ok', 'adresse_gps_ok']) e;
SELECT throws_ok($$SELECT admin_verifier_pharmacie((SELECT valeur::uuid FROM ctx WHERE cle = 'aube'))$$, '55000', NULL, 'vérification refusée : 4 cases sur 5');
SELECT is((admin_detail_verification((SELECT valeur::uuid FROM ctx WHERE cle = 'aube')) -> 'identite' ->> 'nom_titulaire'), 'Dr A', 'détail : identité du titulaire visible de l''admin');
SELECT admin_basculer_checklist_pharmacie((SELECT valeur::uuid FROM ctx WHERE cle = 'aube'), 'pas_doublon', true);
SELECT lives_ok($$SELECT admin_verifier_pharmacie((SELECT valeur::uuid FROM ctx WHERE cle = 'aube'))$$, 'vérification acceptée avec les 5 cases');
RESET ROLE;
SELECT is((SELECT statut::text || '/' || est_publiee::text || '/' || (verified_at IS NOT NULL)::text FROM pharmacies WHERE nom = 'Pharmacie Nouvelle Aube'), 'verifie/false/true', 'vérifiée mais NON publiée (la règle de publication s''applique ensuite)');
SELECT is((SELECT count(*)::int FROM evenements_onboarding WHERE evenement = 'pharmacie_verifiee'), 1, 'audit : pharmacie_verifiee');

-- ── Invitation d'une pharmacie vérifiée (sans demande) ──
SELECT throws_ok($$SELECT inviter_pharmacie_interne((SELECT id FROM pharmacies WHERE nom = 'Pharmacie ancienne'), '00000000-0000-0000-0000-0000000000a1', 'h0')$$, '55000', NULL, 'invitation refusée : pharmacie non vérifiée');
SELECT throws_ok($$SELECT inviter_pharmacie_interne((SELECT valeur::uuid FROM ctx WHERE cle = 'aube'), '00000000-0000-0000-0000-0000000000b1', 'h0')$$, '42501', NULL, 'invitation refusée : appelant non admin');
SELECT is(inviter_pharmacie_interne((SELECT valeur::uuid FROM ctx WHERE cle = 'aube'), '00000000-0000-0000-0000-0000000000a1', 'inv-1') ->> 'email', 'a@ex.test', 'invitation : email du titulaire');
SELECT is(inviter_pharmacie_interne((SELECT valeur::uuid FROM ctx WHERE cle = 'aube'), '00000000-0000-0000-0000-0000000000a1', 'inv-2') ->> 'nom', 'Pharmacie Nouvelle Aube', 'nouvelle invitation');
SELECT is(consommer_jeton_activation_interne('inv-1') ->> 'erreur', 'lien_invalide', 'ancien jeton invalidé par le nouveau');
SELECT is(consommer_jeton_activation_interne('inv-2') ->> 'email', 'a@ex.test', 'activation d''une pharmacie sans demande : email du titulaire');
SELECT is(consommer_jeton_activation_interne('inv-2') ->> 'erreur', 'lien_invalide', 'usage unique');

-- ── Annulation : supprime seulement les pharmacies intactes ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT is(pm_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), '{"supprimees": 2, "conservees": 1}'::jsonb, 'annulation : 2 pharmacies intactes supprimées, la vérifiée conservée');
SELECT throws_ok($$SELECT pm_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'))$$, '55000', NULL, 'double annulation refusée');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM pharmacies WHERE nom IN ('Pharmacie du Marché', 'Pharmacie Doublon Tel', 'Pharmacie Téléphone Illisible')), 0, 'les pharmacies non touchées ont disparu');
SELECT is((SELECT count(*)::int FROM pharmacies WHERE nom = 'Pharmacie Nouvelle Aube'), 1, 'la pharmacie vérifiée est conservée (rien ne disparaît après une décision d''admin)');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
INSERT INTO ctx VALUES ('lot2', pm_creer_lot('petit.csv')::text);
SELECT pm_ajouter_lignes((SELECT valeur::uuid FROM ctx WHERE cle = 'lot2'), '[{"numero":1,"nom":"Pharmacie Éphémère","quartier":"bastos"}]'::jsonb);
SELECT pm_finaliser_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot2'));
SELECT pm_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot2'));
RESET ROLE;
UPDATE lots_pharmacies SET valide_le = now() - interval '25 hours' WHERE id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot2');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT pm_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot2'))$$, '55000', NULL, 'annulation refusée après 24 h');
INSERT INTO ctx VALUES ('lot3', pm_creer_lot('abandon.csv')::text);
SELECT pm_ajouter_lignes((SELECT valeur::uuid FROM ctx WHERE cle = 'lot3'), '[{"numero":1,"nom":"Pharmacie Abandonnée","quartier":"bastos"}]'::jsonb);
SELECT lives_ok($$SELECT pm_abandonner_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot3'))$$, 'abandon d''un lot non validé');
SELECT throws_ok($$SELECT pm_abandonner_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot2'))$$, '55000', NULL, 'un lot validé ne s''abandonne pas');
SELECT is(jsonb_array_length(pm_historique()), 2, 'historique : 2 lots (l''abandonné n''y figure plus)');
SELECT is((pm_historique() -> 0 ->> 'annulable')::boolean, false, 'historique : plus annulable après 24 h');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM lignes_lots_pharmacies WHERE lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot3')), 0, 'abandon : aucune ligne de fichier conservée');
SELECT is((SELECT count(*)::int FROM pharmacies WHERE nom = 'Pharmacie Abandonnée'), 0, 'abandon : aucune pharmacie créée');

-- ── Liste des pharmacies à inviter ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT is(jsonb_array_length(admin_pharmacies_a_inviter()), 1, 'à inviter : la pharmacie vérifiée avec email de titulaire et sans compte');
SELECT is(admin_pharmacies_a_inviter() -> 0 ->> 'nom', 'Pharmacie Nouvelle Aube', 'à inviter : Nouvelle Aube');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT admin_pharmacies_a_inviter()$$, '42501', NULL, 'pharmacien : liste à inviter refusée');
RESET ROLE;

-- ── La remise à zéro de la démo n'est pas bloquée par la garde et n'écrase pas la vérification des pharmacies créées en masse ──
INSERT INTO pharmacies (id, nom, slug, quartier_id, statut, est_demo, horaires, lot_creation_id) VALUES ('00000000-0000-0000-0000-0000000000d9', 'Pharmacie en masse (démo)', 'en-masse-demo', '00000000-0000-0000-0000-00000000f001', 'non_verifie', true, '{}', (SELECT valeur::uuid FROM ctx WHERE cle = 'lot'));
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT lives_ok($$SELECT reinitialiser_demo(50)$$, 'remise à zéro de la démo : aucune erreur malgré une pharmacie créée en masse non vérifiée');
SELECT is((SELECT statut::text FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d9'), 'non_verifie', 'la pharmacie créée en masse reste non vérifiée après la remise à zéro');

SELECT * FROM finish();
ROLLBACK;
