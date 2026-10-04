-- pgTAP — onboarding étape 2 : checklist de l'Espace Pro, « Je confirme mes stocks », règle de publication.
BEGIN;
SELECT plan(33);

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien1@test.local'),
    ('00000000-0000-0000-0000-0000000000b2', 'pharmacien2@test.local'),
    ('00000000-0000-0000-0000-0000000000b3', 'pharmacien3@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude, statut, est_publiee, est_demo, horaires) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie A', 'a', '00000000-0000-0000-0000-00000000f001', 3.85, 11.50, 'verifie', false, true, '{"lun":{"ouv":"08:00","fer":"20:00"}}'),
    ('00000000-0000-0000-0000-0000000000d2', 'Pharmacie B (non vérifiée)', 'b', '00000000-0000-0000-0000-00000000f001', 3.86, 11.51, 'non_verifie', false, true, '{"lun":{"ouv":"08:00","fer":"20:00"}}'),
    ('00000000-0000-0000-0000-0000000000d3', 'Pharmacie C (sans GPS)', 'c', '00000000-0000-0000-0000-00000000f001', NULL, NULL, 'verifie', false, true, '{}');
INSERT INTO profils (id, role, pharmacie_id) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1'),
    ('00000000-0000-0000-0000-0000000000b2', 'pharmacien', '00000000-0000-0000-0000-0000000000d2'),
    ('00000000-0000-0000-0000-0000000000b3', 'pharmacien', '00000000-0000-0000-0000-0000000000d3');
INSERT INTO medicaments (id, nom, dosage, forme, restreint, est_demo)
SELECT ('00000000-0000-0000-0000-0000000e' || lpad(g::text, 4, '0'))::uuid, 'Produit ' || g, '100mg', 'comprimé', false, true FROM generate_series(1, 12) g;
-- A : 9 stocks frais + 3 anciens (périmés pour la règle) ; B : 12 frais.
INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock, confirme_le)
SELECT '00000000-0000-0000-0000-0000000000d1', ('00000000-0000-0000-0000-0000000e' || lpad(g::text, 4, '0'))::uuid, 1000 + g, true,
       CASE WHEN g <= 9 THEN now() - interval '1 day' ELSE now() - interval '30 days' END FROM generate_series(1, 12) g;
INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock)
SELECT '00000000-0000-0000-0000-0000000000d2', ('00000000-0000-0000-0000-0000000e' || lpad(g::text, 4, '0'))::uuid, 1000 + g, true FROM generate_series(1, 12) g;
-- « Importer mes stocks » = au moins un import validé : un lot validé pour A et B
INSERT INTO lots_import (pharmacie_id, auteur_id, nom_fichier, mode, statut, valide_le) VALUES
    ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000b1', 'a.csv', 'merge', 'committed', now()),
    ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000b2', 'b.csv', 'merge', 'committed', now());
INSERT INTO contacts_pharmacie (id, pharmacie_id, canal, adresse, consentement_le, verifie_le) VALUES
    ('00000000-0000-0000-0000-0000000c0001', '00000000-0000-0000-0000-0000000000d1', 'telegram', '555123456', now(), now()),
    ('00000000-0000-0000-0000-0000000c0002', '00000000-0000-0000-0000-0000000000d2', 'telegram', '555123457', now(), now());

SELECT is(erreur_valeur_config('publication_min_items_frais', '0'), 'publication_min_items_frais : doit être compris entre 1 et 1000', 'réglage : seuil 0 refusé');
SELECT is(erreur_valeur_config('publication_min_items_frais', '5'), NULL, 'réglage : seuil 5 accepté');
SELECT is(erreur_valeur_config('publication_fraicheur_jours', '"sept"'), 'publication_fraicheur_jours : un nombre est attendu', 'réglage : fraîcheur non numérique refusée');
SELECT is((SELECT valeur FROM config_routage WHERE cle = 'publication_min_items_frais'), '10'::jsonb, 'défaut : 10 médicaments frais');
SELECT is((SELECT valeur FROM config_routage WHERE cle = 'publication_fraicheur_jours'), '7'::jsonb, 'défaut : 7 jours');

-- ── Accès ──
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT etat_onboarding_mien()$$, '42501', NULL, 'anon : état refusé');
SELECT throws_ok($$SELECT confirmer_mes_stocks()$$, '42501', NULL, 'anon : confirmation refusée');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT etat_onboarding_mien()$$, '42501', NULL, 'admin : pas de pharmacie, état « mien » refusé');
SELECT throws_ok($$SELECT confirmer_mes_stocks()$$, '42501', NULL, 'admin : ne confirme pas de stocks');
SELECT is(admin_etat_onboarding('00000000-0000-0000-0000-0000000000d1') ->> 'total', '6', 'admin : voit l''état de n''importe quelle pharmacie');
RESET ROLE;

-- ── Pharmacie A : checklist pas à pas ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT admin_etat_onboarding('00000000-0000-0000-0000-0000000000d1')$$, '42501', NULL, 'pharmacien : état admin refusé');
SELECT is((etat_onboarding_mien() ->> 'faits')::int, 2, 'départ : 2 tâches faites (Telegram vérifié, import validé)');
SELECT is((etat_onboarding_mien() -> 'items' -> 1 ->> 'fait')::boolean, false, '« Ma Pharmacie » : GPS non confirmé -> pas fait');
SELECT throws_ok($$SELECT onboarding_marquer('est_publiee')$$, '22023', NULL, 'marqueur inconnu refusé');
SELECT throws_ok($$SELECT onboarding_marquer('mot_de_passe_defini', false)$$, '22023', NULL, 'le mot de passe ne s''annule pas');
SELECT is((onboarding_marquer('mot_de_passe_defini') -> 'items' -> 0 ->> 'fait')::boolean, true, 'mot de passe défini');
SELECT is((onboarding_marquer('gps_confirme') -> 'items' -> 1 ->> 'fait')::boolean, true, 'GPS confirmé + horaires -> « Ma Pharmacie » fait');
SELECT is((etat_onboarding_mien() -> 'items' -> 4 ->> 'fait')::boolean, false, 'confirmation : pas encore faite');
SELECT is((etat_onboarding_mien() -> 'items' -> 5 ->> 'items_frais')::int, 9, 'seuil : 9 stocks frais seulement (les 3 de 30 jours ne comptent pas)');
-- Telegram : « je n'utilise pas Telegram » compte aussi, et s'annule
SELECT is((onboarding_marquer('sans_telegram') -> 'items' -> 2 ->> 'sans_telegram')::boolean, true, 'sans Telegram : marqué');
SELECT is((onboarding_marquer('sans_telegram', false) -> 'items' -> 2 ->> 'sans_telegram')::boolean, false, 'sans Telegram : annulable');

-- Confirmation : les 12 lignes sont confirmées -> 12 frais >= 10 -> publiée automatiquement
SELECT is((confirmer_mes_stocks() ->> 'confirmes')::int, 12, 'je confirme mes stocks : 12 lignes');
SELECT is((SELECT est_publiee FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d1'), true, 'publiée automatiquement (vérifiée, 6/6, 12 stocks frais)');
SELECT is((etat_onboarding_mien() ->> 'faits')::int, 6, 'checklist complète 6/6');
RESET ROLE;
SELECT ok((SELECT publiee_le IS NOT NULL FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d1'), 'date de publication posée');
SELECT is((SELECT count(*)::int FROM evenements_onboarding WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND evenement = 'pharmacie_publiee'), 1, 'audit : pharmacie_publiee');
SELECT is((SELECT count(*)::int FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d2' AND confirme_le < now() - interval '1 minute'), 0, 'la confirmation de A ne touche pas les stocks de B');

-- ── Pharmacie B non vérifiée : tout fait, mais jamais publiée ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
SELECT onboarding_marquer('mot_de_passe_defini');
SELECT onboarding_marquer('gps_confirme');
SELECT confirmer_mes_stocks();
SELECT is((etat_onboarding_mien() ->> 'faits')::int, 6, 'B : 6/6 mais non vérifiée');
SELECT is((etat_onboarding_mien() ->> 'publiable')::boolean, false, 'B : non publiable tant que non vérifiée');
RESET ROLE;
SELECT is((SELECT est_publiee FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d2'), false, 'B : jamais publiée (règle : seul « verifie » compte)');

-- ── Pharmacie C sans GPS : confirmation de position impossible ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b3","role":"authenticated"}', true);
SELECT throws_ok($$SELECT onboarding_marquer('gps_confirme')$$, '55000', NULL, 'C : pas de position à confirmer');
SELECT is((confirmer_mes_stocks() ->> 'confirmes')::int, 0, 'C : aucun stock à confirmer (aucune confirmation factice)');
-- Un pharmacien ne se publie pas lui-même
SELECT throws_ok($$UPDATE pharmacies SET est_publiee = true WHERE id = '00000000-0000-0000-0000-0000000000d3'$$, '42501', NULL, 'C : ne peut pas se publier directement (colonne protégée)');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
