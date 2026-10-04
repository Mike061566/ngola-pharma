-- pgTAP — réponses des pharmacies : une seule réponse comptée, effets sur le stock, expiration, droits ;
-- activation Telegram (jeton haché, usage unique, plafond), réglage des contacts.
BEGIN;
SELECT plan(64);

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien1@test.local'),
    ('00000000-0000-0000-0000-0000000000b2', 'pharmacien2@test.local'),
    ('00000000-0000-0000-0000-0000000000c1', 'patient@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude, statut, est_publiee) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie 1', 'pharmacie-1', '00000000-0000-0000-0000-00000000f001', 3.85, 11.50, 'verifie', true),
    ('00000000-0000-0000-0000-0000000000d2', 'Pharmacie 2', 'pharmacie-2', '00000000-0000-0000-0000-00000000f001', 3.86, 11.51, 'verifie', true);
INSERT INTO profils (id, role, pharmacie_id) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1'),
    ('00000000-0000-0000-0000-0000000000b2', 'pharmacien', '00000000-0000-0000-0000-0000000000d2'),
    ('00000000-0000-0000-0000-0000000000c1', 'patient', NULL);
INSERT INTO medicaments (id, nom, dosage, ordonnance) VALUES ('00000000-0000-0000-0000-00000000e001', 'Produit A', '100mg', true);
INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock, statut_stock, confirme_le, date_maj) VALUES
    ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000e001', 1000, false, 'rupture', now() - interval '10 days', now() - interval '10 days');

INSERT INTO alertes_routage (id, id_public, medicament_id, quartier_id, empreinte_patient, expire_le, statut, cree_le) VALUES
    ('00000000-0000-0000-0000-0000000a0001', 'NG-AAAAAAA1', '00000000-0000-0000-0000-00000000e001', '00000000-0000-0000-0000-00000000f001', 'h1', now() + interval '2 hours', 'routing', now()),
    ('00000000-0000-0000-0000-0000000a0002', 'NG-AAAAAAA2', '00000000-0000-0000-0000-00000000e001', '00000000-0000-0000-0000-00000000f001', 'h2', now() - interval '1 minute', 'routing', now() - interval '3 hours');
INSERT INTO envois_alerte (id, alerte_id, pharmacie_id, vague, score, detail_score, code_reponse) VALUES
    ('abcdef01-0000-4000-8000-000000000001', '00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-0000000000d1', 1, 50, '{}', 'CODE000001'),
    ('abcdef02-0000-4000-8000-000000000002', '00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-0000000000d2', 1, 50, '{}', 'CODE000002'),
    ('abcdef03-0000-4000-8000-000000000003', '00000000-0000-0000-0000-0000000a0002', '00000000-0000-0000-0000-0000000000d1', 1, 50, '{}', 'CODE000003');

-- ── Réponse « Disponible » avec prix : stock mis à jour, alerte répondue ──
SELECT is((SELECT resultat FROM enregistrer_reponse_alerte('abcdef01-0000-4000-8000-000000000001', 'available', 1500, 'telegram')), 'enregistree', 'Disponible : enregistrée');
SELECT is((SELECT statut_stock || '/' || prix_fcfa || '/' || en_stock FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1'), 'en_stock/1500/true',
    'stock : en_stock, prix mis à jour, en_stock synchronisé');
SELECT ok((SELECT confirme_le > now() - interval '1 minute' FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1'), 'stock : date de confirmation = maintenant');
SELECT is((SELECT source::text FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1'), 'pharmacien', 'stock : source pharmacien');
SELECT is((SELECT statut FROM envois_alerte WHERE id = 'abcdef01-0000-4000-8000-000000000001'), 'responded', 'envoi : responded');
SELECT is((SELECT statut FROM alertes_routage WHERE id = '00000000-0000-0000-0000-0000000a0001'), 'answered', 'alerte : answered à la 1re réponse positive');
SELECT isnt((SELECT premiere_reponse_positive_le FROM alertes_routage WHERE id = '00000000-0000-0000-0000-0000000a0001'), NULL, 'alerte : première réponse positive datée');

-- ── Idempotence : une réponse rejouée ne duplique ni ne modifie ──
SELECT is((SELECT resultat || '/' || reponse || '/' || prix_fcfa FROM enregistrer_reponse_alerte('abcdef01-0000-4000-8000-000000000001', 'unavailable', NULL, 'link')),
    'deja_traitee/available/1500', 'rejouée (même envoi, autre canal) : deja_traitee, réponse d''origine renvoyée');
SELECT is((SELECT count(*)::int FROM reponses_alerte WHERE envoi_id = 'abcdef01-0000-4000-8000-000000000001'), 1, 'une seule réponse comptée');
SELECT is((SELECT statut_stock FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1'), 'en_stock', 'le stock n''est pas modifié par la réponse rejouée');

-- ── Réponse de la 2e pharmacie : sans prix, pas de ligne de stock créée ──
SELECT is((SELECT resultat || '/' || stock_mis_a_jour::text FROM enregistrer_reponse_alerte('abcdef02-0000-4000-8000-000000000002', 'available', NULL, 'link')),
    'enregistree/false', 'Disponible sans prix et sans ligne de stock : réponse comptée, stock non créé');
SELECT is((SELECT count(*)::int FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d2'), 0, 'aucune ligne de stock inventée');
SELECT is((SELECT premiere_reponse_positive_le IS NOT NULL FROM alertes_routage WHERE id = '00000000-0000-0000-0000-0000000a0001'), true, 'première réponse conservée');

-- ── Indisponible : rupture, ligne créée (prix 0 = inconnu) ; prix ignoré ──
UPDATE envois_alerte SET statut = 'sent' WHERE id = 'abcdef02-0000-4000-8000-000000000002';
DELETE FROM reponses_alerte WHERE envoi_id = 'abcdef02-0000-4000-8000-000000000002';
SELECT is((SELECT resultat || '/' || COALESCE(prix_fcfa::text, 'null') FROM enregistrer_reponse_alerte('abcdef02-0000-4000-8000-000000000002', 'unavailable', 999, 'telegram')),
    'enregistree/null', 'Indisponible : prix ignoré');
SELECT is((SELECT statut_stock || '/' || en_stock::text || '/' || prix_fcfa FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d2'), 'rupture/false/0', 'Indisponible : ligne de rupture créée');

-- ── Disponible avec prix et sans ligne : ligne créée ──
INSERT INTO envois_alerte (id, alerte_id, pharmacie_id, vague, score, detail_score, code_reponse) VALUES
    ('abcdef04-0000-4000-8000-000000000004', '00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-0000000000d2', 2, 40, '{}', 'CODE000004')
    ON CONFLICT DO NOTHING;
SELECT is((SELECT count(*)::int FROM envois_alerte WHERE alerte_id = '00000000-0000-0000-0000-0000000a0001' AND pharmacie_id = '00000000-0000-0000-0000-0000000000d2'), 1, 'un envoi par pharmacie et par alerte (contrainte)');

-- ── Expiration, prix invalide, introuvable, valeurs invalides ──
SELECT is((SELECT resultat FROM enregistrer_reponse_alerte('abcdef03-0000-4000-8000-000000000003', 'available', 1000, 'link')), 'expiree', 'alerte expirée : réponse refusée');
SELECT is((SELECT count(*)::int FROM reponses_alerte WHERE envoi_id = 'abcdef03-0000-4000-8000-000000000003'), 0, 'alerte expirée : rien d''enregistré');
UPDATE alertes_routage SET expire_le = now() + interval '1 hour' WHERE id = '00000000-0000-0000-0000-0000000a0002';
SELECT is((SELECT resultat FROM enregistrer_reponse_alerte('abcdef03-0000-4000-8000-000000000003', 'available', 0, 'link')), 'prix_invalide', 'prix 0 refusé');
SELECT is((SELECT resultat FROM enregistrer_reponse_alerte('abcdef03-0000-4000-8000-000000000003', 'available', -5, 'link')), 'prix_invalide', 'prix négatif refusé');
SELECT is((SELECT resultat FROM enregistrer_reponse_alerte('abcdef03-0000-4000-8000-000000000003', 'available', 99999999, 'link')), 'prix_invalide', 'prix démesuré refusé');
SELECT is((SELECT resultat FROM enregistrer_reponse_alerte('00000000-0000-0000-0000-000000000999', 'available', 1000, 'link')), 'introuvable', 'envoi inconnu');
SELECT throws_ok($$SELECT * FROM enregistrer_reponse_alerte('abcdef03-0000-4000-8000-000000000003', 'peut-etre', NULL, 'link')$$, '22023', NULL, 'réponse invalide refusée');
SELECT throws_ok($$SELECT * FROM enregistrer_reponse_alerte('abcdef03-0000-4000-8000-000000000003', 'available', NULL, 'sms')$$, '22023', NULL, 'canal invalide refusé');
UPDATE envois_alerte SET statut = 'cancelled' WHERE id = 'abcdef03-0000-4000-8000-000000000003';
SELECT is((SELECT resultat FROM enregistrer_reponse_alerte('abcdef03-0000-4000-8000-000000000003', 'available', 1000, 'link')), 'expiree', 'envoi annulé : refusé');
UPDATE envois_alerte SET statut = 'sent' WHERE id = 'abcdef03-0000-4000-8000-000000000003';

-- ── Résolution du bouton Telegram ─────────────────────────────────────
SELECT is(trouver_envoi_court('00000000-0000-0000-0000-0000000000d1', 'abcdef01'), 'abcdef01-0000-4000-8000-000000000001'::uuid, 'bouton : envoi retrouvé dans la pharmacie');
SELECT is(trouver_envoi_court('00000000-0000-0000-0000-0000000000d2', 'abcdef01'), NULL, 'bouton : jamais l''envoi d''une autre pharmacie');
SELECT is(trouver_envoi_court('00000000-0000-0000-0000-0000000000d1', 'abc'), NULL, 'bouton : format invalide');
SELECT is(trouver_envoi_court('00000000-0000-0000-0000-0000000000d1', 'abcdef%%'), NULL, 'bouton : pas de joker');

-- ── Jeton à usage unique ──────────────────────────────────────────────
INSERT INTO contacts_pharmacie (id, pharmacie_id, canal, adresse, consentement_le) VALUES
    ('00000000-0000-0000-0000-0000000c0001', '00000000-0000-0000-0000-0000000000d1', 'telegram', 'en_attente:x', now());
INSERT INTO jetons_telegram (jeton_hash, objet, ref_id, expire_le) VALUES
    ('hash-ok', 'pharmacy_contact', '00000000-0000-0000-0000-0000000c0001', now() + interval '1 hour'),
    ('hash-expire', 'pharmacy_contact', '00000000-0000-0000-0000-0000000c0001', now() - interval '1 second');
SELECT is((SELECT ref_id FROM consommer_jeton_telegram('hash-ok')), '00000000-0000-0000-0000-0000000c0001'::uuid, 'jeton valide consommé');
SELECT is((SELECT count(*)::int FROM consommer_jeton_telegram('hash-ok')), 0, 'jeton rejoué : refusé');
SELECT is((SELECT count(*)::int FROM consommer_jeton_telegram('hash-expire')), 0, 'jeton expiré : refusé');
SELECT is((SELECT count(*)::int FROM consommer_jeton_telegram('inconnu')), 0, 'jeton inconnu : refusé');

-- ── Liaison du compte Telegram ────────────────────────────────────────
SELECT is((SELECT resultat FROM lier_contact_telegram('00000000-0000-0000-0000-0000000c0001', '123456')), 'active', 'liaison : contact activé');
SELECT is((SELECT adresse || '/' || (verifie_le IS NOT NULL)::text FROM contacts_pharmacie WHERE id = '00000000-0000-0000-0000-0000000c0001'), '123456/true', 'contact : chat_id enregistré, vérifié');
SELECT is((SELECT resultat FROM lier_contact_telegram('00000000-0000-0000-0000-0000000c0001', 'pas-un-nombre')), 'introuvable', 'chat_id invalide refusé');
INSERT INTO contacts_pharmacie (id, pharmacie_id, canal, adresse, consentement_le, verifie_le) VALUES
    ('00000000-0000-0000-0000-0000000c0002', '00000000-0000-0000-0000-0000000000d1', 'telegram', '222', now(), now()),
    ('00000000-0000-0000-0000-0000000c0003', '00000000-0000-0000-0000-0000000000d1', 'telegram', '333', now(), now()),
    ('00000000-0000-0000-0000-0000000c0004', '00000000-0000-0000-0000-0000000000d1', 'telegram', 'en_attente:y', now(), NULL);
SELECT is((SELECT resultat FROM lier_contact_telegram('00000000-0000-0000-0000-0000000c0004', '444')), 'limite_contacts', 'plafond de 3 contacts Telegram vérifiés');
INSERT INTO contacts_pharmacie (id, pharmacie_id, canal, adresse, consentement_le) VALUES
    ('00000000-0000-0000-0000-0000000c0005', '00000000-0000-0000-0000-0000000000d1', 'telegram', 'en_attente:z', now());
UPDATE contacts_pharmacie SET desabonne_le = now() WHERE id = '00000000-0000-0000-0000-0000000c0002';
SELECT is((SELECT resultat FROM lier_contact_telegram('00000000-0000-0000-0000-0000000c0005', '222')), 'active', 'même compte déjà lié : réactivé');
SELECT is((SELECT desabonne_le IS NULL FROM contacts_pharmacie WHERE id = '00000000-0000-0000-0000-0000000c0002'), true, 'réactivation : désabonnement levé');
SELECT is((SELECT count(*)::int FROM contacts_pharmacie WHERE id = '00000000-0000-0000-0000-0000000c0005'), 0, 'contact en attente doublon supprimé');

-- ── /stop ─────────────────────────────────────────────────────────────
SELECT is(desabonner_telegram('333'), 1, '/stop : un contact désabonné');
SELECT is(desabonner_telegram('333'), 0, '/stop rejoué : rien de plus');
SELECT is((SELECT desabonne_le IS NOT NULL FROM contacts_pharmacie WHERE id = '00000000-0000-0000-0000-0000000c0003'), true, '/stop : contact désabonné');

-- ── Espace Pro : répondre, voir, régler les canaux ────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
SELECT throws_ok($$SELECT * FROM repondre_alerte('abcdef03-0000-4000-8000-000000000003', 'available', 1200)$$, '42501', NULL, 'pharmacien d''une AUTRE pharmacie : refusé');
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT is((SELECT resultat FROM repondre_alerte('abcdef03-0000-4000-8000-000000000003', 'available', 1200)), 'enregistree', 'pharmacien : répond depuis l''Espace Pro');
SELECT is((SELECT canal FROM reponses_alerte WHERE envoi_id = 'abcdef03-0000-4000-8000-000000000003'), 'dashboard', 'canal dashboard');
SELECT is((SELECT mis_a_jour_par FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1'), '00000000-0000-0000-0000-0000000000b1'::uuid, 'stock : mis à jour par le pharmacien');
SELECT is((SELECT reponse || '/' || prix_repondu FROM vue_alertes_pharmacie WHERE envoi_id = 'abcdef03-0000-4000-8000-000000000003'), 'available/1200', 'vue : réponse et prix');
SELECT is((SELECT prix_stock FROM vue_alertes_pharmacie WHERE envoi_id = 'abcdef01-0000-4000-8000-000000000001'), 1200, 'vue : prix du stock pour pré-remplir');
SELECT throws_ok($$SELECT * FROM enregistrer_reponse_alerte('abcdef01-0000-4000-8000-000000000001', 'available', 1, 'dashboard')$$, '42501', NULL, 'fonction serveur : refusée au navigateur');

SELECT lives_ok($$SELECT * FROM activer_telegram_pharmacie(true)$$, 'activation Telegram : jeton créé (2 contacts vérifiés, 1 de plus)');
SELECT throws_ok($$SELECT * FROM activer_telegram_pharmacie(true)$$, '23514', NULL, 'plafond atteint : refusé');
SELECT throws_ok($$SELECT * FROM activer_telegram_pharmacie(false)$$, '22023', NULL, 'consentement obligatoire');
SELECT throws_ok($$SELECT * FROM jetons_telegram$$, '42501', NULL, 'jetons : illisibles depuis le navigateur');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM jetons_telegram WHERE jeton_hash ~ '^[0-9a-f]{64}$' AND objet = 'pharmacy_contact'), 1, 'jeton stocké sous forme d''empreinte SHA-256 (64 hex)');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);

SELECT is(ajouter_contact_sms('+237600000099', true) IS NOT NULL, true, 'SMS : numéro ajouté');
SELECT throws_ok($$SELECT ajouter_contact_sms('0600000099', true)$$, '22023', NULL, 'SMS : numéro non international refusé');
SELECT throws_ok($$SELECT ajouter_contact_sms('+237600000098', false)$$, '22023', NULL, 'SMS : consentement obligatoire');
SELECT lives_ok($$SELECT changer_abonnement_contact((SELECT id FROM contacts_pharmacie WHERE adresse = '+237600000099'), false)$$, 'désabonnement d''un contact');
SELECT is((SELECT desabonne_le IS NOT NULL FROM contacts_pharmacie WHERE adresse = '+237600000099'), true, 'contact désabonné');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT * FROM repondre_alerte('abcdef01-0000-4000-8000-000000000001', 'available', 1)$$, '42501', NULL, 'patient : refusé');
SELECT throws_ok($$SELECT * FROM activer_telegram_pharmacie(true)$$, '42501', NULL, 'patient : activation Telegram refusée');
SELECT is((SELECT count(*)::int FROM vue_alertes_pharmacie), 0, 'patient : vue vide');
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT * FROM repondre_alerte('abcdef01-0000-4000-8000-000000000001', 'available', 1)$$, '42501', NULL, 'anonyme : refusé');

SELECT * FROM finish();
ROLLBACK;
