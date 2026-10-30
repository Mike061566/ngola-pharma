-- pgTAP — mode démo : mode public, étiquette de démonstration, liste blanche des comptes de test (admin seul, adresses masquées),
-- messages « aurait été envoyé », remise à zéro rejouable (identique à chaque exécution, refusée hors démo, ne décide rien).
BEGIN;
SELECT plan(62);

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien1@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude, statut, est_publiee, est_demo, horaires) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Démo A', 'demo-a', '00000000-0000-0000-0000-00000000f001', 3.85, 11.50, 'non_verifie', false, true, '{}'),
    ('00000000-0000-0000-0000-0000000000d2', 'Démo B', 'demo-b', '00000000-0000-0000-0000-00000000f001', 3.86, 11.51, 'partenaire', false, true, '{}'),
    ('00000000-0000-0000-0000-0000000000d3', 'Démo C', 'demo-c', '00000000-0000-0000-0000-00000000f001', 3.86, 11.52, 'verifie', true, true, '{}'),
    ('00000000-0000-0000-0000-0000000000d4', 'Vraie pharmacie', 'vraie', '00000000-0000-0000-0000-00000000f001', 3.87, 11.52, 'verifie', true, false, '{"lun":{"ouv":"08:00","fer":"20:00"}}');
INSERT INTO profils (id, role, pharmacie_id) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d4');
INSERT INTO medicaments (id, nom, dosage, forme, restreint, est_demo) VALUES
    ('00000000-0000-0000-0000-00000000e001', 'Produit A', '100mg', 'comprimé', false, true),
    ('00000000-0000-0000-0000-00000000e002', 'Produit B', '200mg', 'sirop', true, true),
    ('00000000-0000-0000-0000-00000000e003', 'Produit réel', '300mg', 'gélule', false, false);
INSERT INTO contacts_pharmacie (id, pharmacie_id, canal, adresse, consentement_le, verifie_le, est_contact_demo, desabonne_le) VALUES
    ('00000000-0000-0000-0000-0000000c0001', '00000000-0000-0000-0000-0000000000d1', 'telegram', '555123456', now(), now(), true, now()),
    ('00000000-0000-0000-0000-0000000c0002', '00000000-0000-0000-0000-0000000000d4', 'telegram', '777999111', now(), now(), false, NULL),
    ('00000000-0000-0000-0000-0000000c0003', '00000000-0000-0000-0000-0000000000d4', 'telegram', 'en_attente:x', now(), NULL, false, NULL);
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f002', 'Q2', 'q2');
INSERT INTO alertes_routage (id, id_public, medicament_id, quartier_id, empreinte_patient, expire_le, statut) VALUES
    ('00000000-0000-0000-0000-0000000a0001', 'NG-DDDDDDD1', '00000000-0000-0000-0000-00000000e001', '00000000-0000-0000-0000-00000000f001', 'h1', now() + interval '1 hour', 'routing');
INSERT INTO envois_alerte (alerte_id, pharmacie_id, vague, score, detail_score, code_reponse) VALUES
    ('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-0000000000d3', 1, 50, '{}', 'CODEDEMO01');
INSERT INTO notifications_outbox (cle_idempotence, type_destinataire, canal, modele, adresse_chiffree, statut, cle_base) VALUES
    ('d1', 'pharmacy', 'telegram', 'alerte_demande', '\x01', 'suppressed_demo', (SELECT id::text FROM envois_alerte LIMIT 1)),
    ('d2', 'patient', 'sms', 'attente_patient', '\x01', 'queued', 'alerte:00000000-0000-0000-0000-0000000a0001:attente'),
    ('d3', 'pharmacy', 'telegram', 'alerte_demande', '\x01', 'sent', 'autre');
INSERT INTO patients_bloques (empreinte_patient, motif) VALUES ('bloque1', 'test');
INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock) VALUES ('00000000-0000-0000-0000-0000000000d4', '00000000-0000-0000-0000-00000000e003', 1234, true);

-- ── Mode public et étiquette ──────────────────────────────────────────
SET LOCAL ROLE anon;
SELECT is(mode_public(), 'demo', 'mode public lisible sans connexion : demo');
SELECT is((SELECT est_demo FROM v_pharmacies WHERE slug = 'demo-a'), true, 'v_pharmacies : étiquette de démonstration');
SELECT is((SELECT est_demo FROM v_pharmacies WHERE slug = 'vraie'), false, 'v_pharmacies : pharmacie réelle non étiquetée');
SELECT lives_ok($$SELECT pharmacie_est_demo FROM v_meilleurs_prix$$, 'v_meilleurs_prix : colonne pharmacie_est_demo');
SELECT throws_ok($$SELECT * FROM config_routage$$, '42501', NULL, 'anonyme : la configuration reste illisible (seul le mode est public)');
SELECT throws_ok($$SELECT * FROM admin_liste_contacts()$$, '42501', NULL, 'anonyme : liste des contacts refusée');
SELECT throws_ok($$SELECT * FROM reinitialiser_demo()$$, '42501', NULL, 'anonyme : remise à zéro refusée');

-- ── Droits : admin seul ───────────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT * FROM admin_liste_contacts()$$, '42501', NULL, 'pharmacien : liste des contacts refusée');
SELECT throws_ok($$SELECT admin_marquer_contact_demo('00000000-0000-0000-0000-0000000c0002', true)$$, '42501', NULL, 'pharmacien : ne s''ajoute pas à la liste blanche');
SELECT throws_ok($$SELECT * FROM admin_activer_telegram_demo('00000000-0000-0000-0000-0000000000d1')$$, '42501', NULL, 'pharmacien : compte de test refusé');
SELECT throws_ok($$SELECT * FROM file_messages_demo()$$, '42501', NULL, 'pharmacien : messages démo refusés');
SELECT throws_ok($$SELECT * FROM reinitialiser_demo()$$, '42501', NULL, 'pharmacien : remise à zéro refusée');
SELECT is((SELECT est_contact_demo FROM contacts_pharmacie WHERE id = '00000000-0000-0000-0000-0000000c0002'), false, 'le pharmacien ne peut pas se mettre en liste blanche');
UPDATE contacts_pharmacie SET est_contact_demo = true WHERE id = '00000000-0000-0000-0000-0000000c0002';
SELECT is((SELECT est_contact_demo FROM contacts_pharmacie WHERE id = '00000000-0000-0000-0000-0000000c0002'), false, 'écriture directe sur les contacts sans effet (aucune politique de mise à jour)');

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);

-- ── Liste blanche ─────────────────────────────────────────────────────
SELECT is((SELECT count(*)::int FROM admin_liste_contacts()), 3, 'admin : liste des contacts');
SELECT is((SELECT adresse_masquee FROM admin_liste_contacts() WHERE contact_id = '00000000-0000-0000-0000-0000000c0001'), '••••456', 'adresse masquée (3 derniers caractères seulement)');
SELECT is((SELECT adresse_masquee FROM admin_liste_contacts() WHERE contact_id = '00000000-0000-0000-0000-0000000c0003'), 'activation en cours', 'activation en cours indiquée');
SELECT is((SELECT array_agg(adresse_masquee)::text FROM admin_liste_contacts()) ~ '555123|777999', false, 'aucune adresse complète renvoyée');
SELECT is((SELECT contact_id FROM admin_liste_contacts() LIMIT 1), '00000000-0000-0000-0000-0000000c0001'::uuid, 'les comptes de test d''abord');
SELECT lives_ok($$SELECT admin_marquer_contact_demo('00000000-0000-0000-0000-0000000c0002', true)$$, 'admin : ajoute un compte (pharmacien participant)');
SELECT is((SELECT est_contact_demo FROM contacts_pharmacie WHERE id = '00000000-0000-0000-0000-0000000c0002'), true, 'compte ajouté à la liste blanche');
SELECT throws_ok($$SELECT admin_marquer_contact_demo('00000000-0000-0000-0000-0000000c0003', true)$$, '55000', NULL, 'un compte Telegram non activé ne peut pas être ajouté');
SELECT throws_ok($$SELECT admin_marquer_contact_demo('00000000-0000-0000-0000-000000009999', true)$$, 'P0002', NULL, 'contact inconnu');
SELECT lives_ok($$SELECT admin_marquer_contact_demo('00000000-0000-0000-0000-0000000c0002', false)$$, 'admin : retire un compte');
SELECT is((SELECT count(*)::int FROM journal_admin_alertes WHERE action IN ('contact_demo_ajoute', 'contact_demo_retire')), 2, 'ajouts et retraits journalisés');

SELECT is((SELECT count(*)::int FROM admin_activer_telegram_demo('00000000-0000-0000-0000-0000000000d2')), 1, 'admin : compte de test Telegram créé');
SELECT is((SELECT est_contact_demo || '/' || (verifie_le IS NULL)::text FROM contacts_pharmacie WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d2' AND canal = 'telegram'), 'true/true', 'compte de test : en liste blanche, en attente de /start');
SELECT throws_ok($$SELECT * FROM admin_activer_telegram_demo('00000000-0000-0000-0000-000000009999')$$, 'P0002', NULL, 'pharmacie inconnue');
SELECT lives_ok($$SELECT * FROM admin_activer_telegram_demo('00000000-0000-0000-0000-0000000000d2')$$, '2e compte de test');
SELECT lives_ok($$SELECT * FROM admin_activer_telegram_demo('00000000-0000-0000-0000-0000000000d2')$$, '3e compte de test');
SELECT throws_ok($$SELECT * FROM admin_activer_telegram_demo('00000000-0000-0000-0000-0000000000d2')$$, '23514', NULL, 'plafond de 3 comptes Telegram');

SELECT is((SELECT count(*)::int FROM file_messages_demo()), 1, 'messages « aurait été envoyé » : seuls les suppressed_demo');
SELECT is((SELECT canal || '/' || modele FROM file_messages_demo()), 'telegram/alerte_demande', 'message démo : canal et modèle, jamais d''adresse');
SELECT is((SELECT alerte_id FROM file_messages_demo()), '00000000-0000-0000-0000-0000000a0001'::uuid, 'message démo rattaché à son alerte');

-- ── Remise à zéro ─────────────────────────────────────────────────────
SELECT is((reinitialiser_demo(2) -> 'pharmacies_scenario')::text, '["demo-a", "demo-b"]', 'échantillon déterministe : les 2 premières pharmacies de démo par slug');
SELECT is((SELECT count(*)::int FROM alertes_routage), 0, 'alertes supprimées');
SELECT is((SELECT count(*)::int FROM envois_alerte), 0, 'envois supprimés (cascade)');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM notifications_outbox), 0, 'file de messages vidée');
SELECT is((SELECT count(*)::int FROM patients_bloques), 0, 'liste de blocage vidée');
SELECT is((SELECT count(*)::int FROM journal_admin_alertes WHERE action NOT IN ('config', 'reinitialiser_demo')), 0, 'journal des actions vidé');
SELECT is((SELECT desabonne_le IS NULL AND est_contact_demo FROM contacts_pharmacie WHERE id = '00000000-0000-0000-0000-0000000c0001'), true, 'compte de test conservé et réactivé');
SELECT is((SELECT adresse FROM contacts_pharmacie WHERE id = '00000000-0000-0000-0000-0000000c0001'), '555123456', 'contacts non supprimés');
SELECT is((SELECT statut::text || '/' || est_publiee::text FROM pharmacies WHERE slug = 'demo-a'), 'verifie/true', 'pharmacie de démo de l''échantillon : vérifiée et publiée');
SELECT is((SELECT statut::text || '/' || est_publiee::text FROM pharmacies WHERE slug = 'demo-b'), 'verifie/true', 'partenaire de l''échantillon : ramenée à vérifiée (publiable)');
SELECT is((SELECT est_publiee FROM pharmacies WHERE slug = 'demo-c'), false, 'autre pharmacie de démo : dépubliée');
SELECT is((SELECT statut::text || '/' || est_publiee::text FROM pharmacies WHERE slug = 'vraie'), 'verifie/true', 'pharmacie réelle : INTACTE');
SELECT is((SELECT prix_fcfa FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d4'), 1234, 'stock d''une pharmacie réelle : INTACT');
SELECT is((SELECT horaires -> 'dim' ->> 'fer' FROM pharmacies WHERE slug = 'demo-a'), '23:59', 'échantillon ouvert 24 h/24');
SELECT is((SELECT count(*)::int FROM stocks WHERE pharmacie_id IN ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2')), 4, 'stocks : 2 pharmacies × 2 médicaments de démo actifs (hors fiche fictive)');
SELECT is((SELECT count(*)::int FROM stocks WHERE medicament_id = '00000000-0000-0000-0000-00000000e003' AND pharmacie_id <> '00000000-0000-0000-0000-0000000000d4'), 0, 'un médicament non démo n''est pas stocké en démo');

-- Fiche fictive et classification : jamais décidée
SELECT is((SELECT restreint || '/' || est_demo || '/' || (classification_validee_le IS NULL)::text FROM medicaments WHERE nom = 'Exemple restreint (démo)'), 'true/true/true', 'fiche fictive « Exemple restreint (démo) » : restreinte, de démo, non validée');
SELECT is((SELECT restreint FROM medicaments WHERE id = '00000000-0000-0000-0000-00000000e002'), true, 'classification de Produit B inchangée (restreint)');
SELECT is((SELECT restreint FROM medicaments WHERE id = '00000000-0000-0000-0000-00000000e001'), false, 'classification de Produit A inchangée (décision du propriétaire)');

-- Rejouable : même état
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
CREATE TEMP TABLE _r1 AS SELECT reinitialiser_demo(2) AS r;
UPDATE stocks SET prix_fcfa = 99999, statut_stock = 'rupture' WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1';
CREATE TEMP TABLE _r2 AS SELECT reinitialiser_demo(2) AS r;
SELECT is((SELECT r ->> 'empreinte' FROM _r2), (SELECT r ->> 'empreinte' FROM _r1), 'rejouable : empreinte de l''état identique après modification manuelle');
SELECT is((SELECT count(*)::int FROM medicaments WHERE nom = 'Exemple restreint (démo)'), 1, 'fiche fictive : jamais dupliquée');
UPDATE medicaments SET restreint = false WHERE nom = 'Exemple restreint (démo)';
SELECT reinitialiser_demo(2);
SELECT is((SELECT restreint FROM medicaments WHERE nom = 'Exemple restreint (démo)'), true, 'fiche fictive : la remise à zéro la rétablit restreinte');
SELECT is((SELECT jsonb_array_length(r -> 'avertissements') FROM _r2), 0, 'aucun avertissement quand le scénario est jouable');
UPDATE medicaments SET restreint = true WHERE id = '00000000-0000-0000-0000-00000000e001';
SELECT is((SELECT reinitialiser_demo(2) -> 'avertissements' ->> 0) ~ 'aucun_medicament_demo_non_restreint', true, 'avertissement : aucun médicament de démo non restreint (jamais « corrigé »)');
SELECT is((SELECT restreint FROM medicaments WHERE id = '00000000-0000-0000-0000-00000000e001'), true, 'la remise à zéro n''a pas rendu le médicament non restreint');

-- Refus hors mode démo (le verrou de production est contourné ici pour préparer le test, comme un propriétaire de base)
RESET ROLE;
ALTER TABLE config_routage DISABLE TRIGGER config_routage_verrou;
UPDATE config_routage SET valeur = '"production"' WHERE cle = 'mode_application';
ALTER TABLE config_routage ENABLE TRIGGER config_routage_verrou;
SELECT throws_ok($$SELECT reinitialiser_demo(2)$$, '55000', NULL, 'remise à zéro REFUSÉE hors mode démo');
SELECT is((SELECT mode_public()), 'production', 'mode public : production');
SELECT is((SELECT count(*)::int FROM stocks WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1'), 2, 'rien n''a été touché');

SELECT * FROM finish();
ROLLBACK;
