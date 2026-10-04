-- pgTAP — catalogue : classification par défaut « restreint », validation admin seule, remise à zéro à la
-- modification, aucune écriture via la vue de compatibilité drug_catalog.
BEGIN;
SELECT plan(14);

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien1@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie 1', 'pharmacie-1', '00000000-0000-0000-0000-00000000f001', 3.85, 11.50);
INSERT INTO profils (id, role, pharmacie_id) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1');
INSERT INTO medicaments (id, nom, dosage, forme) VALUES
    ('00000000-0000-0000-0000-00000000e001', 'Produit test A', '100mg', 'comprimé');

-- Valeurs par défaut sûres
SELECT is((SELECT restreint FROM medicaments WHERE id = '00000000-0000-0000-0000-00000000e001'), true,
    'une nouvelle fiche est restreinte par défaut');
SELECT is((SELECT classification_validee_le FROM medicaments WHERE id = '00000000-0000-0000-0000-00000000e001'), NULL,
    'une nouvelle fiche n''est pas validée');
SELECT is(public.medicament_routable('00000000-0000-0000-0000-00000000e001'), false,
    'restreint + non validé : non routable');

-- Pharmacien : ni validation, ni lecture des validations
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT public.valider_classification('Dr X', '123',
    '[{"medicament_id":"00000000-0000-0000-0000-00000000e001","restreint":false,"ordonnance":false}]'::jsonb)$$,
    '42501', NULL, 'pharmacien : valider_classification refusée');
SELECT is((SELECT count(*)::int FROM validations_classification), 0, 'pharmacien : ne voit aucune validation');

-- Admin : validation complète
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT public.valider_classification('Dr X', '123', '[]'::jsonb)$$,
    NULL, NULL, 'admin : liste vide refusée');
SELECT lives_ok($$SELECT public.valider_classification('Dr X', 'ORD-123',
    '[{"medicament_id":"00000000-0000-0000-0000-00000000e001","restreint":false,"ordonnance":true}]'::jsonb, 'doc-1')$$,
    'admin : valider_classification acceptée');
SELECT is((SELECT restreint FROM medicaments WHERE id = '00000000-0000-0000-0000-00000000e001'), false,
    'après validation : restreint = false');
SELECT isnt((SELECT classification_validee_le FROM medicaments WHERE id = '00000000-0000-0000-0000-00000000e001'), NULL,
    'après validation : date de validation renseignée');
SELECT is(public.medicament_routable('00000000-0000-0000-0000-00000000e001'), true,
    'validé et non restreint : routable');

-- Modifier un indicateur remet la validation à zéro
UPDATE medicaments SET ordonnance = false WHERE id = '00000000-0000-0000-0000-00000000e001';
SELECT is((SELECT classification_validee_le FROM medicaments WHERE id = '00000000-0000-0000-0000-00000000e001'), NULL,
    'modification de ordonnance : validation remise à zéro');
SELECT is(public.medicament_routable('00000000-0000-0000-0000-00000000e001'), false,
    'validation remise à zéro et fiche non démo : non routable');

-- Vue de compatibilité : lecture seule
SELECT throws_ok($$UPDATE drug_catalog SET restricted = false$$, '42501', NULL, 'drug_catalog : écriture refusée');
DELETE FROM validations_classification;
SELECT is((SELECT count(*)::int FROM validations_classification), 1, 'validations : aucune suppression possible (trace d''audit)');

SELECT * FROM finish();
ROLLBACK;
