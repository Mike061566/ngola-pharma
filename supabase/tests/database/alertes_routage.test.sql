-- pgTAP — alertes de routage : la pharmacie ne voit que la vue anonymisée de SES envois ; aucune donnée patient,
-- aucun secret (contact chiffré, adresse outbox, code de réponse, jetons) lisible depuis le navigateur ;
-- configuration et liste de blocage réservées à l'admin ; verrou de passage en production.
BEGIN;
SELECT plan(26);

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien1@test.local'),
    ('00000000-0000-0000-0000-0000000000b2', 'pharmacien2@test.local'),
    ('00000000-0000-0000-0000-0000000000c1', 'patient@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie 1', 'pharmacie-1', '00000000-0000-0000-0000-00000000f001', 3.85, 11.50),
    ('00000000-0000-0000-0000-0000000000d2', 'Pharmacie 2', 'pharmacie-2', '00000000-0000-0000-0000-00000000f001', 3.86, 11.51);
INSERT INTO profils (id, role, pharmacie_id) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1'),
    ('00000000-0000-0000-0000-0000000000b2', 'pharmacien', '00000000-0000-0000-0000-0000000000d2'),
    ('00000000-0000-0000-0000-0000000000c1', 'patient', NULL);
INSERT INTO medicaments (id, nom, dosage, forme, ordonnance) VALUES
    ('00000000-0000-0000-0000-00000000e001', 'Produit A', '100mg', 'comprimé', true);
INSERT INTO alertes_routage (id, id_public, medicament_id, quartier_id, lat, lng, empreinte_patient, contact_patient_chiffre, expire_le) VALUES
    ('00000000-0000-0000-0000-0000000a0001', 'NG-TEST-1', '00000000-0000-0000-0000-00000000e001',
     '00000000-0000-0000-0000-00000000f001', 3.87, 11.52, 'hash-patient', '\xdeadbeef', now() + interval '2 hours');
INSERT INTO envois_alerte (id, alerte_id, pharmacie_id, vague, score, detail_score, code_reponse) VALUES
    ('00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-0000000000d1', 1, 80, '{"candidats":["autres"]}', 'CODE1'),
    ('00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-0000000000d2', 1, 70, '{}', 'CODE2');
INSERT INTO notifications_outbox (cle_idempotence, type_destinataire, canal, modele, adresse_chiffree) VALUES
    ('k1', 'pharmacy', 'telegram', 'alerte_pharmacie', '\xcafe');
INSERT INTO jetons_telegram (jeton_hash, objet, ref_id, expire_le) VALUES
    ('h1', 'patient_alert', '00000000-0000-0000-0000-0000000a0001', now() + interval '1 day');
INSERT INTO patients_bloques (empreinte_patient, motif) VALUES ('hash-abus', 'test');

-- ── Contraintes ───────────────────────────────────────────────────────
SELECT throws_ok($$INSERT INTO reponses_alerte (envoi_id, reponse, prix_fcfa, canal)
    VALUES ('00000000-0000-0000-0000-0000000b0001', 'unavailable', 500, 'link')$$,
    '23514', NULL, 'un prix n''a de sens que pour une réponse « available »');
SELECT throws_ok($$INSERT INTO alertes_routage (id_public, quartier_id, empreinte_patient, expire_le)
    VALUES ('NG-TEST-2', '00000000-0000-0000-0000-00000000f001', 'h', now())$$,
    '23514', NULL, 'alerte sans médicament ni requête : refusée');
SELECT throws_ok($$INSERT INTO envois_alerte (alerte_id, pharmacie_id, vague, score, detail_score, code_reponse)
    VALUES ('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-0000000000d1', 2, 1, '{}', 'CODE3')$$,
    '23505', NULL, 'une pharmacie ne reçoit qu''un envoi par alerte');
INSERT INTO reponses_alerte (envoi_id, reponse, prix_fcfa, canal)
    VALUES ('00000000-0000-0000-0000-0000000b0001', 'available', 500, 'link');

-- ── Pharmacien 1 ──────────────────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT * FROM alertes_routage$$, '42501', NULL, 'pharmacien : alertes_routage illisible');
SELECT throws_ok($$SELECT contact_patient_chiffre FROM envois_alerte, alertes_routage$$, '42501', NULL, 'pharmacien : pas de contact patient');
SELECT throws_ok($$SELECT code_reponse FROM envois_alerte$$, '42501', NULL, 'pharmacien : code de réponse masqué');
SELECT throws_ok($$SELECT detail_score FROM envois_alerte$$, '42501', NULL, 'pharmacien : détail du score masqué');
SELECT throws_ok($$SELECT * FROM notifications_outbox$$, '42501', NULL, 'pharmacien : outbox illisible');
SELECT throws_ok($$SELECT * FROM jetons_telegram$$, '42501', NULL, 'pharmacien : jetons illisibles');
SELECT is((SELECT count(*)::int FROM envois_alerte), 1, 'pharmacien : ne voit que ses envois');
SELECT is((SELECT count(*)::int FROM reponses_alerte), 1, 'pharmacien : voit les réponses de sa pharmacie');
SELECT is((SELECT count(*)::int FROM vue_alertes_pharmacie), 1, 'vue anonymisée : une seule ligne (la sienne)');
SELECT is((SELECT medicament_nom || '/' || quartier || '/' || sur_ordonnance::text FROM vue_alertes_pharmacie),
    'Produit A/Quartier test/true', 'vue anonymisée : médicament, quartier, mention d''ordonnance');
SELECT is((SELECT count(*)::int FROM information_schema.columns
           WHERE table_name = 'vue_alertes_pharmacie'
             AND column_name ~ 'patient|contact|empreinte|lat|lng|requete|code|score'), 0,
    'vue anonymisée : aucune colonne patient ni technique');
SELECT throws_ok($$INSERT INTO envois_alerte (alerte_id, pharmacie_id, vague, score, detail_score, code_reponse)
    VALUES ('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-0000000000d1', 3, 1, '{}', 'X')$$,
    '42501', NULL, 'pharmacien : n''écrit pas dans envois_alerte');
SELECT is((SELECT count(*)::int FROM config_routage), 0, 'pharmacien : configuration invisible (RLS)');
SELECT is((SELECT count(*)::int FROM patients_bloques), 0, 'pharmacien : liste de blocage invisible (RLS)');

-- ── Patient ───────────────────────────────────────────────────────────
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}', true);
SELECT is((SELECT count(*)::int FROM vue_alertes_pharmacie), 0, 'patient : vue anonymisée vide');
SELECT is((SELECT count(*)::int FROM envois_alerte), 0, 'patient : aucun envoi visible');

-- ── Anonyme ───────────────────────────────────────────────────────────
RESET ROLE;
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT * FROM vue_alertes_pharmacie$$, '42501', NULL, 'anonyme : vue refusée');
SELECT throws_ok($$SELECT * FROM envois_alerte$$, '42501', NULL, 'anonyme : envois refusés');

-- ── Admin ─────────────────────────────────────────────────────────────
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT is((SELECT count(*)::int FROM alertes_routage), 1, 'admin : lit les alertes');
SELECT is((SELECT count(*)::int FROM notifications_outbox), 1, 'admin : lit l''outbox');
SELECT throws_ok($$SELECT adresse_chiffree FROM notifications_outbox$$, '42501', NULL, 'admin navigateur : adresse chiffrée masquée');
SELECT throws_ok($$SELECT contact_patient_chiffre FROM alertes_routage$$, '42501', NULL, 'admin navigateur : contact patient masqué');
SELECT is((SELECT count(*)::int FROM patients_bloques), 1, 'admin : gère la liste de blocage');

SELECT * FROM finish();
ROLLBACK;
