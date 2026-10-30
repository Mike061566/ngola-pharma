-- pgTAP — pharmacies : un pharmacien ne modifie que telephone, email, site_web, logo_url
-- et horaires de SA pharmacie ; tout le reste (identité, GPS, garde, statut/vérification,
-- champs techniques, colonnes futures) est réservé à l'admin et aux rôles serveur.
-- Exécution : `supabase test db` (Supabase local, Docker). Tout est annulé en fin de test.
BEGIN;
SELECT plan(25);

-- ── Jeu de données (rôle propriétaire, RLS non appliquée) ─────────────
INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien1@test.local'),
    ('00000000-0000-0000-0000-0000000000b2', 'pharmacien2@test.local'),
    ('00000000-0000-0000-0000-0000000000c1', 'patient@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES
    ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test'),
    ('00000000-0000-0000-0000-00000000f002', 'Autre quartier', 'autre-quartier');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie 1', 'pharmacie-1', '00000000-0000-0000-0000-00000000f001', 3.85, 11.50),
    ('00000000-0000-0000-0000-0000000000d2', 'Pharmacie 2', 'pharmacie-2', '00000000-0000-0000-0000-00000000f001', 3.86, 11.51);
INSERT INTO profils (id, role, pharmacie_id) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1'),
    ('00000000-0000-0000-0000-0000000000b2', 'pharmacien', '00000000-0000-0000-0000-0000000000d2'),
    ('00000000-0000-0000-0000-0000000000c1', 'patient', NULL);

-- Colonne ajoutée « plus tard » (ex. numero_ordre, is_published, is_demo, onboarding_state) :
-- elle doit être protégée par défaut, sans toucher au trigger.
ALTER TABLE pharmacies ADD COLUMN colonne_future TEXT;

-- ── Pharmacien 1 (pharmacie 1) : colonnes réservées ───────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);

SELECT throws_ok($$UPDATE pharmacies SET statut = 'verifie' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'pharmacien : statut refusé');
SELECT throws_ok($$UPDATE pharmacies SET nom = 'Autre nom' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'pharmacien : nom refusé');
SELECT throws_ok($$UPDATE pharmacies SET adresse = 'Ailleurs' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'pharmacien : adresse refusée');
SELECT throws_ok($$UPDATE pharmacies SET latitude = 4.0 WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'pharmacien : latitude (GPS) refusée');
SELECT throws_ok($$UPDATE pharmacies SET longitude = 12.0 WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'pharmacien : longitude (GPS) refusée');
SELECT throws_ok($$UPDATE pharmacies SET est_de_garde = true WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'pharmacien : est_de_garde refusé');
SELECT throws_ok($$UPDATE pharmacies SET garde_jusqu_a = now() + interval '1 day' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'pharmacien : garde_jusqu_a refusé');
SELECT throws_ok($$UPDATE pharmacies SET verified_at = now() WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'pharmacien : verified_at refusé');
SELECT throws_ok($$UPDATE pharmacies SET source = 'pharmacien' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'pharmacien : source refusée');
SELECT throws_ok($$UPDATE pharmacies SET quartier_id = '00000000-0000-0000-0000-00000000f002' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'pharmacien : quartier_id refusé');
SELECT throws_ok($$UPDATE pharmacies SET slug = 'autre-slug' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'pharmacien : slug refusé');
SELECT throws_ok($$UPDATE pharmacies SET id = '00000000-0000-0000-0000-0000000000d9' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'pharmacien : id refusé');
SELECT throws_ok($$UPDATE pharmacies SET colonne_future = 'x' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'pharmacien : une colonne ajoutée plus tard est protégée par défaut');

-- ── Pharmacien 1 : colonnes autorisées ────────────────────────────────
SELECT lives_ok($$UPDATE pharmacies SET horaires = '{"lun-sam":"08:00-20:00"}'
    WHERE id = '00000000-0000-0000-0000-0000000000d1'$$, 'pharmacien : horaires autorisés');
SELECT lives_ok($$UPDATE pharmacies SET telephone = '+237600000000'
    WHERE id = '00000000-0000-0000-0000-0000000000d1'$$, 'pharmacien : telephone autorisé');
SELECT lives_ok($$UPDATE pharmacies
    SET email = 'contact@test.local', site_web = 'https://test.local', logo_url = 'https://test.local/logo.png'
    WHERE id = '00000000-0000-0000-0000-0000000000d1'$$, 'pharmacien : email, site_web et logo_url autorisés');

-- Une vue jointe n'est pas modifiable : aucun contournement par v_pharmacies.
SELECT throws_ok($$UPDATE v_pharmacies SET statut = 'verifie' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '55000', NULL, 'pharmacien : la vue v_pharmacies n''est pas modifiable');

-- ── Autre officine : 0 ligne modifiée, sans erreur ────────────────────
WITH maj AS (UPDATE pharmacies SET horaires = '{"x":"y"}' WHERE id = '00000000-0000-0000-0000-0000000000d2' RETURNING 1)
SELECT is((SELECT count(*) FROM maj), 0::bigint, 'pharmacien 1 : horaires de la pharmacie 2 inaccessibles');

SELECT set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
WITH maj AS (UPDATE pharmacies SET horaires = '{"x":"y"}', telephone = '+237611111111'
             WHERE id = '00000000-0000-0000-0000-0000000000d1' RETURNING 1)
SELECT is((SELECT count(*) FROM maj), 0::bigint, 'pharmacien 2 : horaires de la pharmacie 1 inaccessibles');

-- ── Patient ───────────────────────────────────────────────────────────
SELECT set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}', true);
WITH maj AS (UPDATE pharmacies SET telephone = '+237622222222' WHERE id = '00000000-0000-0000-0000-0000000000d1' RETURNING 1)
SELECT is((SELECT count(*) FROM maj), 0::bigint, 'patient : aucune pharmacie modifiable');

-- ── Admin ─────────────────────────────────────────────────────────────
SELECT set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT lives_ok($$UPDATE pharmacies SET statut = 'verifie' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    'admin : statut autorisé');
SELECT lives_ok($$UPDATE pharmacies SET est_de_garde = true, latitude = 3.9, nom = 'Pharmacie 1 bis', colonne_future = 'ok'
    WHERE id = '00000000-0000-0000-0000-0000000000d1'$$, 'admin : garde, GPS, nom et colonne future autorisés');

-- ── Rôles serveur ─────────────────────────────────────────────────────
SET LOCAL ROLE service_role;
SELECT lives_ok($$UPDATE pharmacies SET statut = 'partenaire' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    'service_role : non bridé');
RESET ROLE;
SELECT lives_ok($$UPDATE pharmacies SET statut = 'non_verifie', verified_at = NULL WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    'rôle propriétaire (SQL Editor) : non bridé');

-- ── Etat final ────────────────────────────────────────────────────────
SELECT is(
    (SELECT horaires::text || '|' || telephone FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d1') || ' / ' ||
    (SELECT statut::text || '|' || coalesce(telephone, '-') || '|' || coalesce(horaires::text, '{}') FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d2'),
    '{"lun-sam": "08:00-20:00"}|+237600000000 / non_verifie|-|{}',
    'les modifications légitimes sont conservées ; la pharmacie 2 est intacte');

SELECT * FROM finish();
ROLLBACK;
