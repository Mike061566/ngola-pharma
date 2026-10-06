-- pgTAP — configuration du routage et verrou de passage en production (SPEC 2 §4.0 / §4.0bis).
BEGIN;
SELECT plan(16);

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien1@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie 1', 'pharmacie-1', '00000000-0000-0000-0000-00000000f001', 3.85, 11.50);
INSERT INTO profils (id, role, pharmacie_id) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1');
INSERT INTO medicaments (id, nom, dosage) VALUES ('00000000-0000-0000-0000-00000000e001', 'Produit A', '100mg');

-- Valeurs initiales
SELECT is((SELECT valeur #>> '{}' FROM config_routage WHERE cle = 'mode_application'), 'demo', 'mode initial : demo');
SELECT is((SELECT valeur #>> '{}' FROM config_routage WHERE cle = 'vague1_taille'), '3', 'valeur initiale vague1_taille = 3');
SELECT is((SELECT count(*)::int FROM config_routage WHERE cle IN
    ('vague2_taille','vague2_delai_min','escalade_min','expiration_min','fenetre_agregation_s','max_envois_par_heure',
     'rupture_recente_jours','score_poids','budget_messages_jour','facteur_delai_urgent','relance_sms_apres_min',
     'max_contacts_telegram_par_pharmacie','facteur_temps_demo')), 13, 'toutes les clés initiales présentes');

-- Routage en mode démo : une fiche de démo non restreinte est routable sans validation ; une restreinte jamais
UPDATE medicaments SET restreint = false, est_demo = true WHERE id = '00000000-0000-0000-0000-00000000e001';
SELECT is(public.medicament_routable('00000000-0000-0000-0000-00000000e001'), true, 'démo + non restreint : routable');
UPDATE medicaments SET restreint = true WHERE id = '00000000-0000-0000-0000-00000000e001';
SELECT is(public.medicament_routable('00000000-0000-0000-0000-00000000e001'), false, 'démo + restreint : jamais routable');
UPDATE medicaments SET restreint = false, statut_catalogue = 'archive' WHERE id = '00000000-0000-0000-0000-00000000e001';
SELECT is(public.medicament_routable('00000000-0000-0000-0000-00000000e001'), false, 'fiche archivée : non routable');
UPDATE medicaments SET statut_catalogue = 'actif' WHERE id = '00000000-0000-0000-0000-00000000e001';

-- Verrou
SELECT throws_ok($$UPDATE config_routage SET valeur = '"autre"' WHERE cle = 'mode_application'$$,
    '22023', NULL, 'mode_application : valeur invalide refusée');
SELECT throws_ok($$UPDATE config_routage SET valeur = '"production"' WHERE cle = 'mode_application'$$,
    '23514', NULL, 'production refusée : conditions non remplies');
SELECT throws_ok($$DELETE FROM config_routage WHERE cle = 'mode_application'$$, '23514', NULL, 'mode_application non supprimable');
SELECT is((SELECT count(*)::int FROM public.conditions_passage_production() WHERE NOT ok), 4, 'quatre conditions non remplies au départ');

-- Conditions remplies une à une (avec les rôles propriétaires pour préparer les données)
INSERT INTO validations_classification (valide_par_nom, numero_ordre, portee) VALUES ('Dr X', 'ORD-1', '[]');
UPDATE medicaments SET est_demo = false;
UPDATE pharmacies SET statut = 'verifie', est_demo = false;
UPDATE config_routage SET valeur = 'true' WHERE cle = 'fournisseur_telegram_reel';
SELECT is((SELECT count(*)::int FROM public.conditions_passage_production() WHERE NOT ok), 0, 'toutes les conditions remplies');
SELECT lives_ok($$UPDATE config_routage SET valeur = '"production"' WHERE cle = 'mode_application'$$,
    'passage en production accepté quand tout est réuni');
SELECT is(public.mode_application(), 'production', 'mode lu : production');
SELECT is(public.medicament_routable('00000000-0000-0000-0000-00000000e001'), false,
    'production : fiche restreinte (non validée) non routable');

-- Droits
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT * FROM public.conditions_passage_production()$$, '42501', NULL, 'pharmacien : checklist refusée');
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT is((SELECT count(*)::int FROM public.conditions_passage_production()), 5, 'admin : checklist de 5 conditions');

SELECT * FROM finish();
ROLLBACK;
