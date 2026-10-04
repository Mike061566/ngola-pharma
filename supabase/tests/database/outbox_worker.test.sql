-- pgTAP — outbox : prélèvement par lots avec bail, budget quotidien, contacts bloqués, droits serveur uniquement.
BEGIN;
SELECT plan(16);

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien1@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude, statut, est_publiee) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie 1', 'pharmacie-1', '00000000-0000-0000-0000-00000000f001', 3.85, 11.50, 'verifie', true);
INSERT INTO profils (id, role, pharmacie_id) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1');
INSERT INTO contacts_pharmacie (id, pharmacie_id, canal, adresse, consentement_le) VALUES
    ('00000000-0000-0000-0000-0000000c0001', '00000000-0000-0000-0000-0000000000d1', 'sms', '+237600000001', now());

-- ── Éligibilité : un contact bloqué ou désabonné ne compte pas ─────────
SELECT is(public.pharmacie_eligible_routage('00000000-0000-0000-0000-0000000000d1'), true, 'contact actif : éligible');
UPDATE contacts_pharmacie SET bloque_le = now();
SELECT is(public.pharmacie_eligible_routage('00000000-0000-0000-0000-0000000000d1'), false, 'contact bloqué : non éligible');
UPDATE contacts_pharmacie SET bloque_le = NULL, desabonne_le = now();
SELECT is(public.pharmacie_eligible_routage('00000000-0000-0000-0000-0000000000d1'), false, 'contact désabonné : non éligible');

-- ── Prélèvement par lots ──────────────────────────────────────────────
INSERT INTO notifications_outbox (id, cle_idempotence, type_destinataire, canal, modele, adresse_chiffree, prochaine_tentative_le) VALUES
    ('00000000-0000-0000-0000-0000000e0001', 'k1', 'pharmacy', 'telegram', 'alerte_demande', '\x01', now() - interval '3 minutes'),
    ('00000000-0000-0000-0000-0000000e0002', 'k2', 'pharmacy', 'telegram', 'alerte_demande', '\x01', now() - interval '2 minutes'),
    ('00000000-0000-0000-0000-0000000e0003', 'k3', 'pharmacy', 'telegram', 'alerte_demande', '\x01', now() - interval '1 minute'),
    ('00000000-0000-0000-0000-0000000e0004', 'k4', 'pharmacy', 'telegram', 'alerte_demande', '\x01', now() + interval '1 hour');
INSERT INTO notifications_outbox (cle_idempotence, type_destinataire, canal, modele, adresse_chiffree, statut, prochaine_tentative_le) VALUES
    ('k5', 'pharmacy', 'telegram', 'alerte_demande', '\x01', 'sent', now() - interval '1 hour');

SELECT is((SELECT count(*)::int FROM reclamer_notifications(2, 120)), 2, 'prélèvement limité à 2 lignes');
SELECT is((SELECT tentatives FROM notifications_outbox WHERE id = '00000000-0000-0000-0000-0000000e0001'), 1, 'tentatives incrémenté au prélèvement');
SELECT is((SELECT array_agg(id::text ORDER BY id::text) FROM reclamer_notifications(10, 120))::text,
    '{00000000-0000-0000-0000-0000000e0003}', 'bail : les lignes déjà prélevées ne sont pas reprises ; ni futures, ni envoyées');
SELECT is((SELECT count(*)::int FROM reclamer_notifications(10, 120)), 0, 'plus rien à prélever');
UPDATE notifications_outbox SET prochaine_tentative_le = now() - interval '1 second'
    WHERE id = '00000000-0000-0000-0000-0000000e0001';
SELECT is((SELECT tentatives FROM reclamer_notifications(10, 120)), 2, 'bail expiré : ligne reprise, tentatives = 2');
SELECT is((SELECT count(*)::int FROM reclamer_notifications(0, 120)), 0, 'limite 0 : rien');

-- ── Budget quotidien : seuls SMS et email acceptés aujourd'hui comptent ──
INSERT INTO notifications_outbox (cle_idempotence, type_destinataire, canal, modele, adresse_chiffree, statut) VALUES
    ('s1', 'pharmacy', 'sms', 'alerte_demande_sms', '\x01', 'sent'),
    ('s2', 'pharmacy', 'email', 'alerte_demande_email', '\x01', 'delivered'),
    ('s3', 'pharmacy', 'sms', 'alerte_demande_sms', '\x01', 'failed'),
    ('s4', 'pharmacy', 'sms', 'alerte_demande_sms', '\x01', 'suppressed_demo'),
    ('s5', 'pharmacy', 'telegram', 'alerte_demande', '\x01', 'sent');
INSERT INTO notifications_outbox (cle_idempotence, type_destinataire, canal, modele, adresse_chiffree, statut, mis_a_jour_le) VALUES
    ('s6', 'pharmacy', 'sms', 'alerte_demande_sms', '\x01', 'sent', now() - interval '2 days');
SELECT is(public.compter_messages_payants_du_jour(), 2, 'budget : 2 messages payants acceptés aujourd''hui (ni échec, ni démo, ni Telegram, ni la veille)');

-- ── Configuration du worker ───────────────────────────────────────────
SELECT is((SELECT valeur FROM config_routage WHERE cle = 'retry_delais_s'), '[30, 120, 300]'::jsonb, 'retry : 30 s / 2 min / 5 min');
SELECT is((SELECT count(*)::int FROM config_routage WHERE cle IN ('worker_lot_taille','worker_bail_s','debit_global_par_s','debit_par_discussion_ms')), 4, 'réglages du worker présents');

-- ── Droits : serveur uniquement ───────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT * FROM reclamer_notifications(1, 10)$$, '42501', NULL, 'admin navigateur : reclamer_notifications refusée');
SELECT throws_ok($$SELECT compter_messages_payants_du_jour()$$, '42501', NULL, 'admin navigateur : compteur de budget refusé');
SELECT throws_ok($$SELECT adresse_chiffree FROM notifications_outbox$$, '42501', NULL, 'admin navigateur : adresse chiffrée toujours masquée');
SELECT lives_ok($$SELECT est_destinataire_demo, exempte_budget, canaux_tentes, contact_id FROM notifications_outbox$$, 'admin : nouvelles colonnes non secrètes lisibles');

SELECT * FROM finish();
ROLLBACK;
