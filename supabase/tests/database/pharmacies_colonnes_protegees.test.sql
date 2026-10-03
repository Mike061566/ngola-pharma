-- pgTAP — pharmacies : seules telephone, email, site_web, logo_url et horaires sont
-- modifiables par un pharmacien ; GPS, garde, statut, nom... restent à l'admin.
-- Exécution : `supabase test db` (Supabase local, Docker). Tout est annulé en fin de test.
BEGIN;
SELECT plan(14);

-- ── Jeu de données (rôle propriétaire, RLS non appliquée) ─────────────
INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien1@test.local'),
    ('00000000-0000-0000-0000-0000000000c1', 'patient@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES
    ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie 1', 'pharmacie-1', '00000000-0000-0000-0000-00000000f001', 3.85, 11.50),
    ('00000000-0000-0000-0000-0000000000d2', 'Pharmacie 2', 'pharmacie-2', '00000000-0000-0000-0000-00000000f001', 3.86, 11.51);
INSERT INTO profils (id, role, pharmacie_id) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1'),
    ('00000000-0000-0000-0000-0000000000c1', 'patient', NULL);

-- ── Pharmacien (pharmacie 1) : colonnes protégées ─────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);

SELECT throws_ok($$UPDATE pharmacies SET statut = 'verifie' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'le pharmacien ne peut pas modifier statut');
SELECT throws_ok($$UPDATE pharmacies SET nom = 'Autre nom' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'le pharmacien ne peut pas modifier nom');
SELECT throws_ok($$UPDATE pharmacies SET adresse = 'Ailleurs' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'le pharmacien ne peut pas modifier adresse');
SELECT throws_ok($$UPDATE pharmacies SET latitude = 4.0 WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'le pharmacien ne peut pas modifier le GPS');
SELECT throws_ok($$UPDATE pharmacies SET est_de_garde = true WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'le pharmacien ne peut pas se déclarer de garde');
SELECT throws_ok($$UPDATE pharmacies SET garde_jusqu_a = now() + interval '1 day' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'le pharmacien ne peut pas modifier garde_jusqu_a');
SELECT throws_ok($$UPDATE pharmacies SET verified_at = now() WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'le pharmacien ne peut pas modifier verified_at');
SELECT throws_ok($$UPDATE pharmacies SET id = '00000000-0000-0000-0000-0000000000d9' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'le pharmacien ne peut pas modifier id');

-- ── Pharmacien : colonnes autorisées ──────────────────────────────────
SELECT lives_ok($$UPDATE pharmacies
    SET telephone = '+237600000000', email = 'contact@test.local', site_web = 'https://test.local',
        logo_url = 'https://test.local/logo.png', horaires = '{"lun":"08:00-20:00"}'
    WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    'le pharmacien peut modifier telephone, email, site_web, logo_url et horaires');

-- Une autre pharmacie reste hors d'atteinte (0 ligne modifiée, sans erreur).
WITH maj AS (
    UPDATE pharmacies SET telephone = '+237611111111'
    WHERE id = '00000000-0000-0000-0000-0000000000d2' RETURNING 1
)
SELECT is((SELECT count(*) FROM maj), 0::bigint,
    'le pharmacien ne modifie pas une autre pharmacie');

-- ── Patient ───────────────────────────────────────────────────────────
SELECT set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}', true);
WITH maj AS (
    UPDATE pharmacies SET telephone = '+237622222222'
    WHERE id = '00000000-0000-0000-0000-0000000000d1' RETURNING 1
)
SELECT is((SELECT count(*) FROM maj), 0::bigint, 'un patient ne modifie aucune pharmacie');

-- ── Admin ─────────────────────────────────────────────────────────────
SELECT set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT lives_ok($$UPDATE pharmacies SET statut = 'verifie', est_de_garde = true, latitude = 3.9
    WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    'un admin peut modifier statut, garde et GPS');

-- ── Rôle serveur (SQL Editor, Edge Functions) ─────────────────────────
RESET ROLE;
SELECT lives_ok($$UPDATE pharmacies SET statut = 'partenaire'
    WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    'un rôle serveur n''est pas bridé');

SELECT is((SELECT telephone FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d1'),
    '+237600000000', 'la modification légitime du pharmacien est conservée');

SELECT * FROM finish();
ROLLBACK;
