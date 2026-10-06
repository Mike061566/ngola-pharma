-- pgTAP — conditionnement (pack_size) : colonne, unicité nom + dosage + conditionnement, vue de compatibilité, rapprochement à l'import,
-- avertissements (non vérifiable / différent), et PREUVE que la classification n'est jamais touchée.
BEGIN;
SELECT plan(30);

INSERT INTO auth.users (id, email) VALUES ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'), ('00000000-0000-0000-0000-0000000000b1', 'p1@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Q', 'q');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude, statut, est_demo, horaires) VALUES ('00000000-0000-0000-0000-0000000000d1', 'A', 'a', '00000000-0000-0000-0000-00000000f001', 3.85, 11.5, 'verifie', true, '{}');
INSERT INTO profils (id, role, pharmacie_id) VALUES ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL), ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1');

-- ── Colonne et classification ──
SELECT has_column('public', 'medicaments', 'conditionnement', 'colonne conditionnement présente');
INSERT INTO medicaments (id, nom, dosage, forme) VALUES ('00000000-0000-0000-0000-00000000e0f1', 'Fiche sans décision', '10mg', 'comprimé');
SELECT is((SELECT restreint FROM medicaments WHERE id = '00000000-0000-0000-0000-00000000e0f1'), true, 'une nouvelle fiche reste restreinte par défaut (la migration ne change pas ce défaut)');
SELECT is((SELECT ordonnance FROM medicaments WHERE id = '00000000-0000-0000-0000-00000000e0f1'), false, 'requires_prescription : défaut inchangé');
SELECT is((SELECT classification_validee_le FROM medicaments WHERE id = '00000000-0000-0000-0000-00000000e0f1'), NULL, 'classification_validated_at : toujours NULL');
INSERT INTO medicaments (id, nom, dosage, forme, restreint, ordonnance, classification_validee_le) VALUES ('00000000-0000-0000-0000-00000000e0f2', 'Fiche décidée', '20mg', 'comprimé', false, true, now() - interval '1 day');
UPDATE medicaments SET conditionnement = 'Boîte de 20' WHERE id IN ('00000000-0000-0000-0000-00000000e0f1', '00000000-0000-0000-0000-00000000e0f2');
SELECT is((SELECT restreint::text || '/' || ordonnance::text || '/' || (classification_validee_le IS NULL)::text FROM medicaments WHERE id = '00000000-0000-0000-0000-00000000e0f2'), 'false/true/false', 'renseigner le conditionnement ne modifie ni restricted, ni requires_prescription, ni la validation');
SELECT is((SELECT restreint::text || '/' || ordonnance::text FROM medicaments WHERE id = '00000000-0000-0000-0000-00000000e0f1'), 'true/false', 'idem pour une fiche non classée');

-- ── Unicité nom + dosage + conditionnement ──
INSERT INTO medicaments (id, nom, nom_commercial, dosage, forme, conditionnement, est_demo) VALUES
    ('00000000-0000-0000-0000-00000000e001', 'Paracétamol', 'Doliprane', '500mg', 'comprimé', 'Boîte de 8', true),
    ('00000000-0000-0000-0000-00000000e002', 'Paracétamol', 'Doliprane', '500mg', 'comprimé', 'Boîte de 16', true);
SELECT pass('deux fiches de même nom et dosage mais de conditionnements différents coexistent');
SELECT throws_ok($$INSERT INTO medicaments (nom, dosage, forme, conditionnement) VALUES ('paracétamol ', '500 MG', 'comprimé', 'boîte  de 8')$$, '23505', NULL, 'même nom, dosage et conditionnement (casse, espaces) : refusé');
INSERT INTO medicaments (id, nom, dosage, forme, est_demo) VALUES ('00000000-0000-0000-0000-00000000e003', 'Ibuprofène', '400mg', 'comprimé', true);
SELECT throws_ok($$INSERT INTO medicaments (nom, dosage, forme) VALUES ('Ibuprofène', '400mg', 'sirop')$$, '23505', NULL, 'sans conditionnement : l''unicité nom + dosage d''avant est conservée');
SELECT lives_ok($$INSERT INTO medicaments (nom, dosage, forme, conditionnement) VALUES ('Ibuprofène', '400mg', 'comprimé', 'Boîte de 30')$$, 'même nom et dosage avec un conditionnement : accepté');
SELECT is((SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'uq_medicaments_nom_dosage'), 'uq_medicaments_nom_dosage', 'l''index garde son nom historique (diagnostics et retour arrière de la fusion)');
SELECT is((SELECT pack_size FROM drug_catalog WHERE id = '00000000-0000-0000-0000-00000000e001'), 'Boîte de 8', 'vue drug_catalog : pack_size exposé');

-- ── Comparaison de conditionnements ──
SELECT is(jetons_nombres('Boîte de 16'), jetons_nombres('16 comprimés'), 'même nombre : « Boîte de 16 » = « 16 comprimés »');
SELECT isnt(jetons_nombres('Boîte de 16'), jetons_nombres('Boîte de 8'), 'nombres différents');
SELECT is(conditionnements_compatibles(NULL, '16'), 0, 'ligne sans conditionnement : inconnu');
SELECT is(conditionnements_compatibles('16', NULL), 0, 'fiche sans conditionnement : inconnu');
SELECT is(avertissement_conditionnement('', '00000000-0000-0000-0000-00000000e001'), NULL, 'aucun avertissement sans conditionnement dans la ligne');
SELECT is(avertissement_conditionnement('boîte de 16 comprimés', '00000000-0000-0000-0000-00000000e002') IS NULL, true, 'conditionnement identique : aucun avertissement');
SELECT is(avertissement_conditionnement('Boîte de 20', '00000000-0000-0000-0000-00000000e002') ->> 'code', 'conditionnement_different', 'conditionnement différent : avertissement');
SELECT is(avertissement_conditionnement('Boîte de 20', '00000000-0000-0000-0000-00000000e003') ->> 'code', 'conditionnement_non_verifie', 'fiche sans conditionnement : avertissement « non vérifié »');
SELECT is(avertissement_conditionnement('Boîte de 20', '00000000-0000-0000-0000-00000000e003') ->> 'niveau', 'avertissement', 'jamais bloquant');

-- ── Import : rapprochement ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT set_config('app.lot', import_creer_lot('c.csv', 'merge')::text, true);
SELECT import_ajouter_lignes(current_setting('app.lot')::uuid, $j$[
 {"numero":1,"nom":"Doliprane 500","conditionnement":"Boîte de 16","prix":1500},
 {"numero":2,"nom":"Doliprane 500","conditionnement":"8 comprimés","prix":900},
 {"numero":3,"nom":"Doliprane 500","prix":1000},
 {"numero":4,"nom":"Doliprane 500","conditionnement":"Boîte de 50","prix":2000},
 {"numero":5,"nom":"Ibuprofène 400mg","conditionnement":"Boîte de 20","prix":1800},
 {"numero":6,"nom":"Ibuprofène 400mg","prix":1800}
]$j$::jsonb);
RESET ROLE;
SELECT is((SELECT medicament_id::text || '/' || etat FROM lignes_import WHERE numero = 1 AND lot_id = current_setting('app.lot')::uuid), '00000000-0000-0000-0000-00000000e002/reconnu', 'Doliprane + « Boîte de 16 » -> la fiche de 16, reconnue');
SELECT is((SELECT medicament_id::text || '/' || etat FROM lignes_import WHERE numero = 2 AND lot_id = current_setting('app.lot')::uuid), '00000000-0000-0000-0000-00000000e001/reconnu', 'Doliprane + « 8 comprimés » -> la fiche de 8, reconnue');
SELECT is((SELECT etat || '/' || (problemes -> 0 ->> 'code') FROM lignes_import WHERE numero = 3 AND lot_id = current_setting('app.lot')::uuid), 'a_confirmer/ambigu', 'Doliprane sans conditionnement : deux présentations -> à confirmer (jamais choisi au hasard)');
SELECT is((SELECT etat FROM lignes_import WHERE numero = 4 AND lot_id = current_setting('app.lot')::uuid) <> 'reconnu', true, 'conditionnement qui ne correspond à aucune fiche : jamais « reconnu »');
SELECT is((SELECT problemes @> '[{"code": "conditionnement_non_verifie"}]' FROM lignes_import WHERE numero = 5 AND lot_id = current_setting('app.lot')::uuid), true, 'ligne 5 : fiche sans conditionnement + conditionnement dans le fichier -> avertissement « non vérifié »');
SELECT is((SELECT problemes @> '[{"code": "conditionnement_non_verifie"}]' FROM lignes_import WHERE numero = 6 AND lot_id = current_setting('app.lot')::uuid), false, 'ligne 6 : pas de conditionnement -> pas d''avertissement');

-- ── Choix manuel : l'avertissement de conditionnement est recalculé (jamais cumulé) ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT import_corriger_ligne(current_setting('app.lot')::uuid, 4, 'mapper', '00000000-0000-0000-0000-00000000e001');
SELECT import_corriger_ligne(current_setting('app.lot')::uuid, 4, 'mapper', '00000000-0000-0000-0000-00000000e002');
RESET ROLE;
SELECT is((SELECT jsonb_array_length(jsonb_path_query_array(problemes, '$[*] ? (@.code == "conditionnement_different")')) FROM lignes_import WHERE numero = 4 AND lot_id = current_setting('app.lot')::uuid), 1, 'ligne 4 mappée deux fois : un seul avertissement « différent »');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT import_corriger_ligne(current_setting('app.lot')::uuid, 5, 'mapper', '00000000-0000-0000-0000-00000000e002');
RESET ROLE;
SELECT is((SELECT problemes @> '[{"code": "conditionnement_different"}]' AND NOT problemes @> '[{"code": "conditionnement_non_verifie"}]' FROM lignes_import WHERE numero = 5 AND lot_id = current_setting('app.lot')::uuid), true, 'ligne 5 mappée sur une fiche de conditionnement différent : « non vérifié » remplacé par « différent »');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT import_corriger_ligne(current_setting('app.lot')::uuid, 5, 'mapper', '00000000-0000-0000-0000-00000000e003');
RESET ROLE;
SELECT is((SELECT problemes @> '[{"code": "conditionnement_non_verifie"}]' AND NOT problemes @> '[{"code": "conditionnement_different"}]' FROM lignes_import WHERE numero = 5 AND lot_id = current_setting('app.lot')::uuid), true, 'ligne 5 remappée sur la fiche sans conditionnement : « non vérifié » seul');

SELECT * FROM finish();
ROLLBACK;
