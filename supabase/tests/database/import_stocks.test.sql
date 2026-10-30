-- pgTAP — import guidé des stocks : rapprochement (alias, trigramme, ambiguïté), erreurs par ligne, doublons, écart de prix, corrections,
-- validation atomique, annulation exacte sous 24 h, mode « Remplacer », isolation entre pharmacies, tâche d'onboarding.
BEGIN;
SELECT plan(97);

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000b1', 'p1@test.local'),
    ('00000000-0000-0000-0000-0000000000b2', 'p2@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Q', 'q');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude, statut, est_demo, horaires)
SELECT ('00000000-0000-0000-0000-0000000000d' || g)::uuid, 'Pharmacie ' || g, 'p' || g, '00000000-0000-0000-0000-00000000f001', 3.85, 11.5, 'verifie', true, '{}' FROM generate_series(1, 7) g;
INSERT INTO profils (id, role, pharmacie_id) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1'),
    ('00000000-0000-0000-0000-0000000000b2', 'pharmacien', '00000000-0000-0000-0000-0000000000d2');
INSERT INTO medicaments (id, nom, nom_commercial, dci, dosage, forme, restreint, est_demo, statut_catalogue) VALUES
    ('00000000-0000-0000-0000-00000000e001', 'Paracétamol', 'Doliprane', 'Paracétamol', '500mg', 'comprimé', false, true, 'actif'),
    ('00000000-0000-0000-0000-00000000e002', 'Paracétamol', 'Efferalgan', 'Paracétamol', '1000mg', 'comprimé', false, true, 'actif'),
    ('00000000-0000-0000-0000-00000000e003', 'Ibuprofène', NULL, 'Ibuprofène', '400mg', 'comprimé', true, true, 'actif'),
    ('00000000-0000-0000-0000-00000000e004', 'Amoxicilline', NULL, 'Amoxicilline', '500mg', 'gélule', false, true, 'actif'),
    ('00000000-0000-0000-0000-00000000e005', 'Coartem', NULL, 'Artéméther + Luméfantrine', '20/120mg', 'comprimé', false, true, 'actif'),
    ('00000000-0000-0000-0000-00000000e006', 'Ancien produit', NULL, NULL, '10mg', 'comprimé', false, true, 'archive');
INSERT INTO alias_medicaments (alias_normalise, medicament_id) VALUES ('amoxi', '00000000-0000-0000-0000-00000000e004');
-- Stocks existants de A : Ibuprofène (ancien prix, rupture, confirmé il y a 10 jours) et Coartem (à conserver en mode merge)
INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock, date_maj, source) VALUES
    ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000e003', 1500, false, now() - interval '10 days', 'admin'),
    ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000e004', 700, true, now() - interval '9 days', 'admin');
UPDATE stocks SET confirme_le = now() - interval '2 days' WHERE medicament_id = '00000000-0000-0000-0000-00000000e003';
-- 5 autres pharmacies vendent le Doliprane autour de 5 000 FCFA (médiane) : sert à l'avertissement d'écart de prix
INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock)
SELECT ('00000000-0000-0000-0000-0000000000d' || g)::uuid, '00000000-0000-0000-0000-00000000e001', 4800 + g * 100, true FROM generate_series(3, 7) g;
CREATE TEMP TABLE ctx (cle text PRIMARY KEY, valeur text);
GRANT ALL ON ctx TO PUBLIC;
INSERT INTO ctx SELECT 'ibu_date_maj', date_maj::text FROM stocks WHERE medicament_id = '00000000-0000-0000-0000-00000000e003';
INSERT INTO ctx SELECT 'ibu_confirme', confirme_le::text FROM stocks WHERE medicament_id = '00000000-0000-0000-0000-00000000e003';
CREATE FUNCTION pg_temp.lot_rapide(p_mode text, p_lignes jsonb) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v uuid := import_creer_lot('rapide.csv', p_mode);
BEGIN PERFORM import_ajouter_lignes(v, p_lignes); PERFORM import_finaliser_lot(v); RETURN v; END $f$;

-- ── Accès ──
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT import_creer_lot('x.csv', 'merge')$$, '42501', NULL, 'anon : création refusée');
SELECT throws_ok($$SELECT * FROM lots_import$$, '42501', NULL, 'anon : tables illisibles');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT import_creer_lot('x.csv', 'merge')$$, '42501', NULL, 'admin : pas de pharmacie, import refusé');
RESET ROLE;

-- ── Fonctions de normalisation ──
SELECT is(normaliser_texte_medicament('  Paracétamol 500 mg / Comprimé'), 'paracetamol 500mg comprime', 'normalisation : accents, unité collée, ponctuation');
SELECT is(normaliser_texte_medicament('Dolo 0,5 g'), 'dolo 0.5g', 'normalisation : virgule décimale');
SELECT is(dosages_compatibles('500', '500mg'), 1, 'dosage sans unité : compatible');
SELECT is(dosages_compatibles('500mg', '500mg'), 2, 'dosage identique');
SELECT is(dosages_compatibles('500mg', '500g'), -1, '500 mg ≠ 500 g');
SELECT is(dosages_compatibles('20 120', '20 120mg'), 1, 'Coartem 20/120 sans unité : compatible');
SELECT is(dosages_compatibles('', '500mg'), 0, 'dosage absent : inconnu');

-- ── Lot de A ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT import_creer_lot('x.csv', 'tout')$$, '22023', NULL, 'mode inconnu refusé');
SELECT throws_ok($$SELECT import_creer_lot('  ', 'merge')$$, '22023', NULL, 'nom de fichier obligatoire');
INSERT INTO ctx VALUES ('lot', import_creer_lot('stock.csv', 'merge')::text);
SELECT throws_ok($$SELECT import_finaliser_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'))$$, '55000', NULL, 'finalisation refusée : lot vide');
SELECT throws_ok($$SELECT import_ajouter_lignes((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), '[]')$$, '22023', NULL, '0 ligne refusée');
SELECT throws_ok($$SELECT import_ajouter_lignes((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), (SELECT jsonb_agg(jsonb_build_object('numero', g, 'nom', 'x', 'prix', 100)) FROM generate_series(1, 501) g))$$, '22023', NULL, 'plus de 500 lignes par appel refusé');
SELECT is((import_ajouter_lignes((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), $j$[
 {"numero":1,"nom":"Doliprane 500","prix":9500,"prix_brut":"9 500 FCFA","en_stock":true},
 {"numero":2,"nom":"Ibuprofène 400 mg","prix":2000,"en_stock":true},
 {"numero":3,"nom":"Amoxicilline","dosage":"500 mg","prix":1500,"en_stock":false},
 {"numero":4,"nom":"Amoxicilin 500mg","prix":1500},
 {"numero":5,"nom":"Paracetamol","prix":1000},
 {"numero":6,"nom":"Produit inconnu xyz","prix":1000},
 {"numero":7,"nom":"Coartem 20/120","prix":5400},
 {"numero":8,"nom":"Doliprane 500","prix":5500},
 {"numero":9,"nom":"Doliprane","prix":null,"prix_brut":"abc"},
 {"numero":10,"nom":"Doliprane","prix":600000,"prix_brut":"600000"},
 {"numero":11,"nom":"","prix":1000},
 {"numero":12,"nom":"Efferalgan","prix":900,"en_stock_invalide":true},
 {"numero":13,"nom":"Amoxi","prix":1200},
 {"numero":14,"nom":"Ancien produit 10mg","prix":300}
]$j$::jsonb) ->> 'lignes')::int, 14, '14 lignes ajoutées');
RESET ROLE;

SELECT is((SELECT etat || '/' || methode || '/' || resolution FROM lignes_import WHERE numero = 1 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'reconnu/alias/accepted', 'ligne 1 « Doliprane 500 » : alias exact, pré-acceptée');
SELECT is((SELECT medicament_id::text FROM lignes_import WHERE numero = 1 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), '00000000-0000-0000-0000-00000000e001', 'ligne 1 -> Doliprane 500mg');
SELECT is((SELECT etat FROM lignes_import WHERE numero = 2 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'reconnu', 'ligne 2 : « Ibuprofène 400 mg » reconnu (produit restreint importable)');
SELECT is((SELECT etat || '/' || resolution FROM lignes_import WHERE numero = 4 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'a_confirmer/skipped', 'ligne 4 : faute de frappe -> à confirmer, non écrite tant qu''elle n''est pas confirmée');
SELECT ok((SELECT confiance FROM lignes_import WHERE numero = 4 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')) BETWEEN 0.50 AND 0.79, 'ligne 4 : confiance entre 0,50 et 0,79');
SELECT is((SELECT etat || '/' || (problemes -> 0 ->> 'code') FROM lignes_import WHERE numero = 5 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'a_confirmer/ambigu', 'ligne 5 : « Paracetamol » sans dosage -> ambigu, jamais pré-sélectionné');
SELECT is((SELECT etat FROM lignes_import WHERE numero = 6 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'non_reconnu', 'ligne 6 : produit inconnu -> non reconnu');
SELECT is((SELECT etat FROM lignes_import WHERE numero = 7 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'reconnu', 'ligne 7 : « Coartem 20/120 » reconnu');
SELECT is((SELECT problemes -> 0 ->> 'code' FROM lignes_import WHERE numero = 9 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'prix_invalide', 'ligne 9 : prix non numérique -> erreur bloquante');
SELECT is((SELECT etat FROM lignes_import WHERE numero = 10 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'erreur', 'ligne 10 : prix > 500 000 -> erreur');
SELECT is((SELECT problemes -> 0 ->> 'code' FROM lignes_import WHERE numero = 11 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'nom_absent', 'ligne 11 : nom absent -> erreur');
SELECT is((SELECT etat FROM lignes_import WHERE numero = 12 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'erreur', 'ligne 12 : valeur en_stock illisible -> erreur');
SELECT is((SELECT etat || '/' || medicament_id::text FROM lignes_import WHERE numero = 13 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'reconnu/00000000-0000-0000-0000-00000000e004', 'ligne 13 : alias « amoxi » -> Amoxicilline');
SELECT is((SELECT etat FROM lignes_import WHERE numero = 14 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'non_reconnu', 'ligne 14 : fiche archivée du catalogue jamais proposée');

-- ── Finalisation : doublons, écart de prix ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'))$$, '55000', NULL, 'validation refusée avant la finalisation de l''aperçu');
SELECT is((import_finaliser_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot')) ->> 'erreur')::int, 4, 'finalisation : 4 lignes en erreur (non bloquantes pour le lot)');
RESET ROLE;
SELECT is((SELECT resolution FROM lignes_import WHERE numero = 1 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'skipped', 'doublon : la 1re ligne « Doliprane » est écartée (la dernière l''emporte)');
SELECT is((SELECT resolution FROM lignes_import WHERE numero = 8 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'accepted', 'doublon : la dernière ligne l''emporte');
SELECT ok((SELECT problemes::text LIKE '%doublon_fichier%' FROM lignes_import WHERE numero = 1 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'doublon : avertissement posé');
UPDATE lignes_import SET prix = 9500 WHERE numero = 8 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT is(import_finaliser_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot')) ->> 'avertissements', '4', 'finalisation répétable : 4 lignes avec avertissement (ambigu, doublons Doliprane et Amoxicilline, écart de prix)');
RESET ROLE;
SELECT ok((SELECT problemes::text LIKE '%prix_ecart_median%' FROM lignes_import WHERE numero = 8 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'écart de prix : 9 500 vs médiane ~5 000 (5 autres pharmacies) -> avertissement');
SELECT ok((SELECT NOT (problemes::text LIKE '%prix_ecart_median%') FROM lignes_import WHERE numero = 2 AND lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'pas d''avertissement sans 5 autres pharmacies');

-- ── Aperçu et corrections ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT is(jsonb_array_length(import_lire_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 'erreur') -> 'lignes'), 4, 'aperçu filtré : 4 erreurs');
SELECT is(jsonb_array_length(import_lire_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 'a_confirmer') -> 'lignes'), 2, 'aperçu filtré : 2 lignes à confirmer');
SELECT is(jsonb_array_length(import_lire_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 'tous', 5, 0) -> 'lignes'), 5, 'aperçu paginé');
SELECT throws_ok($$SELECT import_corriger_ligne((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 9, 'accepter')$$, '55000', NULL, 'ligne en erreur : correction refusée (corriger le fichier)');
SELECT throws_ok($$SELECT import_corriger_ligne((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 6, 'accepter')$$, '55000', NULL, 'rien à accepter sans suggestion');
SELECT throws_ok($$SELECT import_corriger_ligne((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 6, 'mapper', '00000000-0000-0000-0000-00000000e006')$$, 'P0002', NULL, 'mapper vers une fiche archivée refusé');
SELECT throws_ok($$SELECT import_corriger_ligne((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 6, 'danser')$$, '22023', NULL, 'action inconnue refusée');
SELECT is((import_corriger_ligne((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 4, 'accepter') ->> 'a_confirmer')::int, 1, 'ligne 4 acceptée : plus qu''une ligne à confirmer');
SELECT is((import_corriger_ligne((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 5, 'mapper', '00000000-0000-0000-0000-00000000e002') ->> 'a_confirmer')::int, 0, 'ligne 5 mappée à la main sur Efferalgan');
SELECT is(jsonb_array_length(import_chercher_catalogue('doliprane')), 1, 'recherche catalogue : Doliprane');
SELECT is(jsonb_array_length(import_chercher_catalogue('ancien produit')), 0, 'recherche catalogue : jamais de fiche archivée');
SELECT lives_ok($$SELECT import_demander_ajout((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 6)$$, 'demande d''ajout d''un produit non reconnu');
SELECT throws_ok($$SELECT import_demander_ajout((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'), 1)$$, '55000', NULL, 'demande d''ajout refusée pour un produit reconnu');
SELECT throws_ok($$SELECT import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'))$$, '55000', NULL, 'une correction impose de refinaliser avant la validation');
SELECT import_finaliser_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'));
-- Isolation : la pharmacie B ne voit ni ne valide le lot de A
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
SELECT throws_ok($$SELECT import_lire_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'))$$, 'P0002', NULL, 'B : ne lit pas le lot de A');
SELECT throws_ok($$SELECT import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'))$$, 'P0002', NULL, 'B : ne valide pas le lot de A');
SELECT throws_ok($$SELECT import_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'))$$, 'P0002', NULL, 'B : n''annule pas le lot de A');
SELECT is(import_historique(), '[]'::jsonb, 'B : historique vide');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM demandes_catalogue WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND nom_brut = 'Produit inconnu xyz'), 1, 'demande d''ajout enregistrée pour la pharmacie A');

-- ── Tâche d'onboarding avant validation ──
SELECT is((calculer_onboarding('00000000-0000-0000-0000-0000000000d1') -> 'items' -> 3 ->> 'fait')::boolean, false, 'onboarding : « Importer mes stocks » pas fait avant la validation (des stocks existent pourtant)');

-- ── Validation ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT is(import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot')) - 'annulable_jusqu_a', '{"crees": 3, "ignores": 9, "archives": 0, "publiee": false, "mis_a_jour": 2}'::jsonb, 'validation : 3 créés, 2 mis à jour, 9 ignorés');
RESET ROLE;
SELECT is((SELECT prix_fcfa FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND medicament_id = '00000000-0000-0000-0000-00000000e001'), 9500, 'Doliprane : prix de la dernière ligne');
SELECT is((SELECT statut_stock FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND medicament_id = '00000000-0000-0000-0000-00000000e004'), 'en_stock', 'Amoxicilline : la dernière ligne (13, alias) l''emporte sur la ligne 3 (rupture)');
SELECT is((SELECT prix_fcfa FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND medicament_id = '00000000-0000-0000-0000-00000000e003'), 2000, 'Ibuprofène (restreint) : mis à jour normalement');
SELECT ok((SELECT confirme_le > now() - interval '1 minute' FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND medicament_id = '00000000-0000-0000-0000-00000000e003'), 'Ibuprofène : confirmé maintenant');
SELECT is((SELECT count(*)::int FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND medicament_id = '00000000-0000-0000-0000-00000000e002'), 1, 'Efferalgan (mappé à la main) écrit');
SELECT is((SELECT count(*)::int FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d2'), 0, 'pharmacie B : aucun stock touché');
SELECT is((calculer_onboarding('00000000-0000-0000-0000-0000000000d1') -> 'items' -> 3 ->> 'fait')::boolean, true, 'onboarding : « Importer mes stocks » fait après une validation');
SELECT is((SELECT count(*)::int FROM evenements_onboarding WHERE evenement = 'import_valide' AND pharmacie_id = '00000000-0000-0000-0000-0000000000d1'), 1, 'audit : import_valide');

-- ── Annulation sous 24 h : restauration exacte ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT is((import_historique() -> 0 ->> 'annulable')::boolean, true, 'historique : import annulable');
SELECT is(jsonb_array_length(import_historique()), 1, 'historique : un import');
SELECT is(import_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), '{"supprimes": 3, "restaures": 2, "modifies_depuis": 0, "archives_restaures": 0, "depubliee": false}'::jsonb, 'annulation : 3 créés supprimés, 2 restaurés');
RESET ROLE;
SELECT is((SELECT prix_fcfa || '/' || statut_stock || '/' || en_stock::text FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND medicament_id = '00000000-0000-0000-0000-00000000e003'), '1500/rupture/false', 'Ibuprofène : prix, statut et disponibilité restaurés');
SELECT is((SELECT date_maj::text FROM stocks WHERE medicament_id = '00000000-0000-0000-0000-00000000e003' AND pharmacie_id = '00000000-0000-0000-0000-0000000000d1'), (SELECT valeur FROM ctx WHERE cle = 'ibu_date_maj'), 'Ibuprofène : date de mise à jour restaurée à l''identique');
SELECT is((SELECT confirme_le::text FROM stocks WHERE medicament_id = '00000000-0000-0000-0000-00000000e003' AND pharmacie_id = '00000000-0000-0000-0000-0000000000d1'), (SELECT valeur FROM ctx WHERE cle = 'ibu_confirme'), 'Ibuprofène : date de confirmation restaurée à l''identique');
SELECT is((SELECT prix_fcfa FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND medicament_id = '00000000-0000-0000-0000-00000000e004'), 700, 'Amoxicilline : ancien prix restauré');
SELECT is((SELECT count(*)::int FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1'), 2, 'les 3 stocks créés par l''import sont supprimés (2 stocks d''origine)');
SELECT is((SELECT statut FROM lots_import WHERE id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot')), 'rolled_back', 'lot : annulé');
SELECT is((calculer_onboarding('00000000-0000-0000-0000-0000000000d1') -> 'items' -> 3 ->> 'fait')::boolean, false, 'onboarding : un import annulé ne compte pas');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT import_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'))$$, '55000', NULL, 'double annulation refusée');
SELECT throws_ok($$SELECT import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot'))$$, '55000', NULL, 'validation d''un lot annulé refusée');

-- ── Mode « Remplacer tout mon stock » : les absents sont archivés, puis restaurés à l'annulation ──
INSERT INTO ctx VALUES ('lot_remplace', pg_temp.lot_rapide('replace', '[{"numero":1,"nom":"Doliprane 500","prix":5000}]')::text);
SELECT is(import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot_remplace')) - 'annulable_jusqu_a', '{"crees": 1, "ignores": 0, "archives": 2, "publiee": false, "mis_a_jour": 0}'::jsonb, 'remplacer : 1 créé, 2 absents archivés');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND statut_stock = 'archive'), 2, 'remplacer : Ibuprofène et Amoxicilline archivés (rien n''est supprimé)');
SELECT is((SELECT en_stock FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND medicament_id = '00000000-0000-0000-0000-00000000e004'), false, 'remplacer : un archivé n''est plus disponible');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT is((import_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot_remplace')) ->> 'archives_restaures')::int, 2, 'annulation du remplacement : 2 stocks désarchivés');
RESET ROLE;
SELECT is((SELECT statut_stock || '/' || en_stock::text FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND medicament_id = '00000000-0000-0000-0000-00000000e004'), 'en_stock/true', 'Amoxicilline : redevenue disponible');
SELECT is((SELECT statut_stock FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND medicament_id = '00000000-0000-0000-0000-00000000e003'), 'rupture', 'Ibuprofène : redevenu en rupture (statut d''origine)');
SELECT is((SELECT count(*)::int FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1'), 2, 'remplacer annulé : retour aux 2 stocks d''origine');

-- ── Modification après la validation : la ligne n'est pas écrasée à l'annulation ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
INSERT INTO ctx VALUES ('lot_conflit', pg_temp.lot_rapide('merge', '[{"numero":1,"nom":"Ibuprofène 400mg","prix":2500},{"numero":2,"nom":"Coartem 20/120mg","prix":6000}]')::text);
SELECT import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot_conflit'));
RESET ROLE;
UPDATE stocks SET prix_fcfa = 2600, date_maj = now() + interval '1 second' WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND medicament_id = '00000000-0000-0000-0000-00000000e003';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT is(import_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot_conflit')), '{"supprimes": 1, "restaures": 0, "modifies_depuis": 1, "archives_restaures": 0, "depubliee": false}'::jsonb, 'annulation : la ligne modifiée depuis est signalée, jamais écrasée');
RESET ROLE;
SELECT is((SELECT prix_fcfa FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND medicament_id = '00000000-0000-0000-0000-00000000e003'), 2600, 'la modification manuelle ultérieure est conservée');

-- ── Au-delà de 24 h : annulation impossible ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
INSERT INTO ctx VALUES ('lot_vieux', pg_temp.lot_rapide('merge', '[{"numero":1,"nom":"Coartem 20/120mg","prix":6100}]')::text);
SELECT import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot_vieux'));
RESET ROLE;
UPDATE lots_import SET valide_le = now() - interval '25 hours' WHERE id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot_vieux');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT import_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot_vieux'))$$, '55000', NULL, 'annulation refusée après 24 h');
SELECT is((import_historique() -> 0 ->> 'annulable')::boolean, false, 'historique : plus annulable après 24 h');
-- Abandon d'un import non validé
INSERT INTO ctx VALUES ('lot_abandon', pg_temp.lot_rapide('merge', '[{"numero":1,"nom":"Coartem 20/120mg","prix":6100}]')::text);
SELECT lives_ok($$SELECT import_abandonner_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot_abandon'))$$, 'abandon d''un import non validé');
SELECT throws_ok($$SELECT import_abandonner_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot_vieux'))$$, '55000', NULL, 'un import validé ne s''abandonne pas');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM lignes_import WHERE lot_id = (SELECT valeur::uuid FROM ctx WHERE cle = 'lot_abandon')), 0, 'abandon : aucune donnée de fichier conservée');

-- ── Tables fermées au navigateur ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT is((SELECT count(*)::int FROM lots_import), 0, 'pharmacien : ne lit pas les lots directement (policy admin seule)');
SELECT throws_ok($$SELECT * FROM lignes_import$$, '42501', NULL, 'pharmacien : lignes d''import illisibles directement');
SELECT throws_ok($$INSERT INTO lots_import (pharmacie_id, auteur_id, nom_fichier, mode) VALUES ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000b1', 'x', 'merge')$$, '42501', NULL, 'pharmacien : pas d''écriture directe');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT ok((SELECT count(*) FROM lots_import) >= 5, 'admin : lit les lots');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
