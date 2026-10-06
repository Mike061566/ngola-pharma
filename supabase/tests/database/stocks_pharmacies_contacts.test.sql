-- pgTAP — stocks (synchronisation statut_stock / en_stock), publication des pharmacies (verifie seulement,
-- réservée à l'admin), contacts de messagerie (lecture seule pour la pharmacie, formats).
BEGIN;
SELECT plan(19);

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien1@test.local'),
    ('00000000-0000-0000-0000-0000000000b2', 'pharmacien2@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie 1', 'pharmacie-1', '00000000-0000-0000-0000-00000000f001', 3.85, 11.50),
    ('00000000-0000-0000-0000-0000000000d2', 'Pharmacie 2', 'pharmacie-2', '00000000-0000-0000-0000-00000000f001', 3.86, 11.51);
INSERT INTO profils (id, role, pharmacie_id) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1'),
    ('00000000-0000-0000-0000-0000000000b2', 'pharmacien', '00000000-0000-0000-0000-0000000000d2');
INSERT INTO medicaments (id, nom, dosage) VALUES
    ('00000000-0000-0000-0000-00000000e001', 'Produit A', '100mg'),
    ('00000000-0000-0000-0000-00000000e002', 'Produit B', '200mg'),
    ('00000000-0000-0000-0000-00000000e003', 'Produit C', '300mg');

-- ── Stocks : cohérence statut_stock / en_stock ────────────────────────
INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock) VALUES
    ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000e001', 1000, false);
SELECT is((SELECT statut_stock FROM stocks WHERE medicament_id = '00000000-0000-0000-0000-00000000e001'), 'rupture',
    'insertion en_stock=false : statut rupture');
INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, statut_stock) VALUES
    ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000e002', 1000, 'faible');
SELECT is((SELECT en_stock FROM stocks WHERE medicament_id = '00000000-0000-0000-0000-00000000e002'), true,
    'statut faible : en_stock = true');
INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, statut_stock) VALUES
    ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000e003', 1000, 'archive');
SELECT is((SELECT en_stock FROM stocks WHERE medicament_id = '00000000-0000-0000-0000-00000000e003'), false,
    'statut archive : en_stock = false');
UPDATE stocks SET en_stock = true WHERE medicament_id = '00000000-0000-0000-0000-00000000e001';
SELECT is((SELECT statut_stock FROM stocks WHERE medicament_id = '00000000-0000-0000-0000-00000000e001'), 'en_stock',
    'mise à jour en_stock=true : statut en_stock');
UPDATE stocks SET statut_stock = 'rupture' WHERE medicament_id = '00000000-0000-0000-0000-00000000e002';
SELECT is((SELECT en_stock FROM stocks WHERE medicament_id = '00000000-0000-0000-0000-00000000e002'), false,
    'mise à jour statut rupture : en_stock = false');
SELECT is((SELECT status FROM stock_items WHERE catalog_id = '00000000-0000-0000-0000-00000000e002'), 'out',
    'vue stock_items : rupture -> out');
SELECT is((SELECT status FROM stock_items WHERE catalog_id = '00000000-0000-0000-0000-00000000e003'), 'archived',
    'vue stock_items : archive -> archived');

-- ── Publication : seulement pour une pharmacie vérifiée, réservée à l'admin ──
SELECT throws_ok($$UPDATE pharmacies SET est_publiee = true WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '23514', NULL, 'publier une pharmacie non vérifiée : refusé (contrainte)');
UPDATE pharmacies SET statut = 'verifie' WHERE id = '00000000-0000-0000-0000-0000000000d1';
SELECT lives_ok($$UPDATE pharmacies SET est_publiee = true WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    'publier une pharmacie vérifiée : accepté');
SELECT throws_ok($$UPDATE pharmacies SET statut = 'partenaire' WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '23514', NULL, 'quitter « verifie » en restant publiée : refusé');

-- ── Contacts ──────────────────────────────────────────────────────────
INSERT INTO contacts_pharmacie (pharmacie_id, canal, adresse, consentement_le) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'sms', '+237600000001', now()),
    ('00000000-0000-0000-0000-0000000000d2', 'telegram', '123456', now());
SELECT throws_ok($$INSERT INTO contacts_pharmacie (pharmacie_id, canal, adresse, consentement_le)
    VALUES ('00000000-0000-0000-0000-0000000000d1', 'sms', '0600000001', now())$$,
    '23514', NULL, 'contact SMS : format E.164 obligatoire');
SELECT throws_ok($$INSERT INTO contacts_pharmacie (pharmacie_id, canal, adresse, consentement_le)
    VALUES ('00000000-0000-0000-0000-0000000000d1', 'email', 'pas-un-email', now())$$,
    '23514', NULL, 'contact email : format vérifié');
SELECT throws_ok($$INSERT INTO contacts_pharmacie (pharmacie_id, canal, adresse, consentement_le)
    VALUES ('00000000-0000-0000-0000-0000000000d1', 'sms', '+237600000001', now())$$,
    '23505', NULL, 'contact en double refusé');
SELECT is(public.pharmacie_eligible_routage('00000000-0000-0000-0000-0000000000d1'), true,
    'vérifiée + publiée + contact actif : éligible');
SELECT is(public.pharmacie_eligible_routage('00000000-0000-0000-0000-0000000000d2'), false,
    'non vérifiée : non éligible');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT is((SELECT count(*)::int FROM contacts_pharmacie), 1, 'pharmacien : ne voit que ses contacts');
SELECT throws_ok($$INSERT INTO contacts_pharmacie (pharmacie_id, canal, adresse, consentement_le)
    VALUES ('00000000-0000-0000-0000-0000000000d1', 'sms', '+237600000002', now())$$,
    '42501', NULL, 'pharmacien : ne crée pas de contact directement');
SELECT throws_ok($$UPDATE pharmacies SET est_publiee = false WHERE id = '00000000-0000-0000-0000-0000000000d1'$$,
    '42501', NULL, 'pharmacien : ne modifie pas la publication');
SELECT throws_ok($$UPDATE stock_items SET price_fcfa = 1$$, '42501', NULL, 'stock_items : écriture refusée');

SELECT * FROM finish();
ROLLBACK;
