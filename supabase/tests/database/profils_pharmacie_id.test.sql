-- pgTAP — profils : `role` et `pharmacie_id` non modifiables hors admin.
-- Exécution : `supabase test db` (Supabase local, Docker). Tout est annulé en fin de test.
BEGIN;
SELECT plan(9);

-- ── Jeu de données (rôle propriétaire, RLS non appliquée) ─────────────
INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien1@test.local'),
    ('00000000-0000-0000-0000-0000000000c1', 'patient@test.local');

INSERT INTO quartiers (id, nom, slug) VALUES
    ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test');
INSERT INTO pharmacies (id, nom, slug, quartier_id) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie 1', 'pharmacie-1', '00000000-0000-0000-0000-00000000f001'),
    ('00000000-0000-0000-0000-0000000000d2', 'Pharmacie 2', 'pharmacie-2', '00000000-0000-0000-0000-00000000f001');
INSERT INTO medicaments (id, nom) VALUES
    ('00000000-0000-0000-0000-0000000000e1', 'Médicament test');
INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa) VALUES
    ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000e1', 1000);

INSERT INTO profils (id, role, pharmacie_id) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1'),
    ('00000000-0000-0000-0000-0000000000c1', 'patient', NULL);

-- ── Pharmacien (pharmacie 1) ──────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);

SELECT throws_ok(
    $$UPDATE profils SET pharmacie_id = '00000000-0000-0000-0000-0000000000d2'
      WHERE id = '00000000-0000-0000-0000-0000000000b1'$$,
    '42501', NULL,
    'un pharmacien ne peut pas se rattacher à une autre pharmacie');

-- Les stocks de la pharmacie 2 restent inaccessibles en écriture (0 ligne modifiée).
WITH maj AS (
    UPDATE stocks SET prix_fcfa = 1
    WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d2' RETURNING 1
)
SELECT is((SELECT count(*) FROM maj), 0::bigint,
    'un pharmacien ne modifie pas les stocks d''une autre pharmacie');

SELECT throws_ok(
    $$UPDATE profils SET pharmacie_id = NULL
      WHERE id = '00000000-0000-0000-0000-0000000000b1'$$,
    '42501', NULL,
    'un pharmacien ne peut pas retirer son rattachement');

SELECT throws_ok(
    $$UPDATE profils SET role = 'admin'
      WHERE id = '00000000-0000-0000-0000-0000000000b1'$$,
    '42501', NULL,
    'un pharmacien ne peut pas s''auto-attribuer le rôle admin');

SELECT lives_ok(
    $$UPDATE profils SET nom_complet = 'Dr Test'
      WHERE id = '00000000-0000-0000-0000-0000000000b1'$$,
    'un pharmacien peut modifier ses autres champs');

-- ── Patient ───────────────────────────────────────────────────────────
SELECT set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}', true);

SELECT throws_ok(
    $$UPDATE profils SET pharmacie_id = '00000000-0000-0000-0000-0000000000d1'
      WHERE id = '00000000-0000-0000-0000-0000000000c1'$$,
    '42501', NULL,
    'un patient ne peut pas se rattacher à une pharmacie');

SELECT throws_ok(
    $$UPDATE profils SET role = 'pharmacien'
      WHERE id = '00000000-0000-0000-0000-0000000000c1'$$,
    '42501', NULL,
    'un patient ne peut pas devenir pharmacien');

-- ── Admin ─────────────────────────────────────────────────────────────
SELECT set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);

SELECT lives_ok(
    $$UPDATE profils SET pharmacie_id = '00000000-0000-0000-0000-0000000000d2'
      WHERE id = '00000000-0000-0000-0000-0000000000b1'$$,
    'un admin peut rattacher un pharmacien à une pharmacie');

SELECT is(
    (SELECT pharmacie_id FROM profils WHERE id = '00000000-0000-0000-0000-0000000000b1'),
    '00000000-0000-0000-0000-0000000000d2'::uuid,
    'le rattachement fait par l''admin est bien enregistré');

SELECT * FROM finish();
ROLLBACK;
