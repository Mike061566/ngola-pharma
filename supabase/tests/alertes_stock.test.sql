-- pgTAP — alertes_stock : validation, anti-spam, alertes héritées, insertion anonyme.
-- Exécution : `supabase test db` (Supabase local, Docker). Tout est annulé en fin de test.
BEGIN;
SELECT plan(14);

SET LOCAL ROLE anon;

-- ── Insertions valides ────────────────────────────────────────────────
SELECT lives_ok($$INSERT INTO alertes_stock (medicament_nom, canal, user_email)
    VALUES ('Coartem', 'email', 'Patient@Test.local')$$, 'insertion email valide');

SELECT lives_ok($$INSERT INTO alertes_stock (medicament_nom, canal, user_phone)
    VALUES ('Coartem', 'sms', '+237 6 12 34 56 78')$$, 'insertion sms valide (espaces tolérés)');

-- ── Validation ────────────────────────────────────────────────────────
SELECT throws_ok($$INSERT INTO alertes_stock (medicament_nom, canal, user_email)
    VALUES ('Coartem', 'email', 'pas-un-email')$$, '23514', NULL, 'email invalide refusé');

SELECT throws_ok($$INSERT INTO alertes_stock (medicament_nom, canal, user_phone)
    VALUES ('Coartem', 'sms', '0612345678')$$, '23514', NULL, 'téléphone hors E.164 refusé');

SELECT throws_ok($$INSERT INTO alertes_stock (medicament_nom, canal, user_email)
    VALUES ('Coartem', 'telegram', 'a@test.local')$$, '23514', NULL, 'canal telegram refusé (pas de contact exploitable ici)');

SELECT throws_ok($$INSERT INTO alertes_stock (medicament_nom, canal, user_email)
    VALUES ('   ', 'email', 'vide@test.local')$$, '23514', NULL, 'nom de médicament vide refusé');

SELECT throws_ok($$INSERT INTO alertes_stock (medicament_nom, canal, user_phone)
    VALUES ('Coartem', 'sms', NULL)$$, '23514', NULL, 'canal sms sans téléphone refusé');

-- ── Champs décidés par le serveur ─────────────────────────────────────
SELECT lives_ok($$INSERT INTO alertes_stock (medicament_nom, canal, user_email, notified_at)
    VALUES ('Coartem', 'email', 'triche@test.local', now())$$,
    'notified_at envoyé par un client est ignoré (remis à NULL par le serveur)');

-- ── Fusion et limite ──────────────────────────────────────────────────
SELECT lives_ok($$INSERT INTO alertes_stock (medicament_nom, canal, user_email)
    VALUES ('Coartem', 'email', 'patient@test.local')$$, 'doublon sous 30 min : accepté sans erreur (fusionné)');

SELECT lives_ok($$INSERT INTO alertes_stock (medicament_nom, canal, user_email) VALUES
    ('M2', 'email', 'patient@test.local'), ('M3', 'email', 'patient@test.local'),
    ('M4', 'email', 'patient@test.local'), ('M5', 'email', 'patient@test.local')$$,
    'jusqu''à 5 alertes par contact et par jour');

SELECT throws_ok($$INSERT INTO alertes_stock (medicament_nom, canal, user_email)
    VALUES ('M6', 'email', 'patient@test.local')$$, '54000', NULL, 'la 6e alerte du jour est refusée');

-- ── Alertes héritées (ancien formulaire) ──────────────────────────────
SELECT lives_ok($$INSERT INTO alertes_stock (medicament_nom, canal, user_phone, heritee)
    VALUES ('Coartem', 'whatsapp', '+237699999999', false)$$,
    'canal whatsapp encore accepté, même si le client prétend heritee = false');

-- ── Lecture : anon ne voit rien ───────────────────────────────────────
SELECT is((SELECT count(*) FROM alertes_stock), 0::bigint, 'anon ne peut pas lire alertes_stock');

-- ── Vérifications côté serveur ────────────────────────────────────────
RESET ROLE;
SELECT is(
    (SELECT count(*) FROM alertes_stock WHERE lower(user_email) = 'patient@test.local'
        AND medicament_nom = 'Coartem') ||' / '||
    (SELECT count(*) FROM alertes_stock WHERE user_phone = '+237612345678') ||' / '||
    (SELECT count(*) FROM alertes_stock WHERE canal = 'whatsapp' AND heritee) ||' / '||
    (SELECT count(*) FROM alertes_stock WHERE user_email = 'triche@test.local' AND notified_at IS NULL),
    '1 / 1 / 1 / 1',
    'email normalisé et fusionné, téléphone normalisé, alerte whatsapp marquée héritée, notified_at nul');

SELECT * FROM finish();
ROLLBACK;
