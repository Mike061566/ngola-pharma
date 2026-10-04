-- pgTAP — console admin des alertes : droits (admin seul), file, chronologie journalisée, actions manuelles (rattacher,
-- transmettre, refuser, relancer, clôturer, annuler, retirer, bloquer), validation et journal des réglages, indicateurs, budget.
BEGIN;
SELECT plan(93);

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien1@test.local'),
    ('00000000-0000-0000-0000-0000000000c1', 'patient@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude, statut, est_publiee) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie 1', 'pharmacie-1', '00000000-0000-0000-0000-00000000f001', 3.85, 11.50, 'verifie', true),
    ('00000000-0000-0000-0000-0000000000d2', 'Pharmacie 2 (non vérifiée)', 'pharmacie-2', '00000000-0000-0000-0000-00000000f001', 3.86, 11.51, 'non_verifie', false),
    ('00000000-0000-0000-0000-0000000000d3', 'Pharmacie 3 (sans contact)', 'pharmacie-3', '00000000-0000-0000-0000-00000000f001', 3.86, 11.52, 'verifie', true),
    ('00000000-0000-0000-0000-0000000000d4', 'Pharmacie 4 (Telegram non activé)', 'pharmacie-4', '00000000-0000-0000-0000-00000000f001', 3.87, 11.52, 'verifie', true);
INSERT INTO profils (id, role, pharmacie_id) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL),
    ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1'),
    ('00000000-0000-0000-0000-0000000000c1', 'patient', NULL);
INSERT INTO contacts_pharmacie (pharmacie_id, canal, adresse, consentement_le, verifie_le) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'sms', '+237600000001', now(), NULL),
    ('00000000-0000-0000-0000-0000000000d1', 'telegram', '1234', now(), now()),
    ('00000000-0000-0000-0000-0000000000d4', 'telegram', 'en_attente:x', now(), NULL);
INSERT INTO medicaments (id, nom, dosage, restreint, est_demo, ordonnance) VALUES
    ('00000000-0000-0000-0000-00000000e001', 'Produit libre', '100mg', false, true, true),
    ('00000000-0000-0000-0000-00000000e002', 'Exemple restreint (démo)', NULL, true, true, false),
    ('00000000-0000-0000-0000-00000000e003', 'Produit archivé', '1mg', false, true, false);
UPDATE medicaments SET statut_catalogue = 'archive' WHERE id = '00000000-0000-0000-0000-00000000e003';

INSERT INTO alertes_routage (id, id_public, medicament_id, requete_brute, quartier_id, empreinte_patient, empreinte_ip, expire_le, statut, raison_revue, cree_le, vague, premiere_reponse_positive_le, contact_patient_chiffre) VALUES
    ('00000000-0000-0000-0000-0000000a0001', 'NG-AAAAAAA1', '00000000-0000-0000-0000-00000000e002', NULL, '00000000-0000-0000-0000-00000000f001', 'h-restreint', 'ip-restreint', now() + interval '2 hours', 'needs_review', 'restreint', now() - interval '10 minutes', 0, NULL, NULL),
    ('00000000-0000-0000-0000-0000000a0002', 'NG-AAAAAAA2', NULL, 'truc inconnu', '00000000-0000-0000-0000-00000000f001', 'h-inconnu', 'ip-inconnu', now() + interval '2 hours', 'needs_review', 'non_reconnu', now() - interval '5 minutes', 0, NULL, NULL),
    ('00000000-0000-0000-0000-0000000a0003', 'NG-AAAAAAA3', '00000000-0000-0000-0000-00000000e001', NULL, '00000000-0000-0000-0000-00000000f001', 'h-routing', 'ip-routing', now() + interval '2 hours', 'routing', NULL, now() - interval '20 minutes', 1, NULL, '\xdeadbeef'),
    ('00000000-0000-0000-0000-0000000a0004', 'NG-AAAAAAA4', '00000000-0000-0000-0000-00000000e001', NULL, '00000000-0000-0000-0000-00000000f001', 'h-answered', 'ip-answered', now() + interval '2 hours', 'answered', NULL, now() - interval '30 minutes', 1, now() - interval '25 minutes', NULL),
    ('00000000-0000-0000-0000-0000000a0005', 'NG-AAAAAAA5', '00000000-0000-0000-0000-00000000e001', NULL, '00000000-0000-0000-0000-00000000f001', 'h-fini', 'ip-fini', now() - interval '1 hour', 'expired', NULL, now() - interval '5 hours', 2, NULL, NULL);
INSERT INTO envois_alerte (id, alerte_id, pharmacie_id, vague, score, detail_score, code_reponse, envoye_le, statut) VALUES
    ('abcdef01-0000-4000-8000-000000000001', '00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-0000000000d1', 1, 80, '{"criteres":[{"cle":"meme_quartier","points":30}]}', 'CODE000001', now() - interval '19 minutes', 'sent'),
    ('abcdef02-0000-4000-8000-000000000002', '00000000-0000-0000-0000-0000000a0004', '00000000-0000-0000-0000-0000000000d1', 1, 70, '{}', 'CODE000002', now() - interval '29 minutes', 'responded'),
    ('abcdef03-0000-4000-8000-000000000003', '00000000-0000-0000-0000-0000000a0004', '00000000-0000-0000-0000-0000000000d4', 1, 60, '{}', 'CODE000003', now() - interval '29 minutes', 'sent');
INSERT INTO reponses_alerte (envoi_id, reponse, prix_fcfa, canal, repondu_le) VALUES
    ('abcdef02-0000-4000-8000-000000000002', 'available', 1500, 'telegram', now() - interval '25 minutes');
INSERT INTO notifications_outbox (cle_idempotence, type_destinataire, canal, modele, adresse_chiffree, statut, cle_base, canaux_tentes, cout_estime) VALUES
    ('k-q1', 'pharmacy', 'sms', 'alerte_demande_sms', '\x01', 'queued', 'abcdef01-0000-4000-8000-000000000001', '{telegram}', NULL),
    ('k-s1', 'pharmacy', 'telegram', 'alerte_demande', '\x01', 'sent', 'abcdef02-0000-4000-8000-000000000002', '{}', NULL),
    ('k-f1', 'pharmacy', 'telegram', 'alerte_demande', '\x01', 'failed', 'abcdef03-0000-4000-8000-000000000003', '{}', NULL),
    ('k-pat', 'patient', 'sms', 'attente_patient', '\x01', 'queued', 'alerte:00000000-0000-0000-0000-0000000a0003:attente', '{}', 0.02);

-- ── Droits : admin seul ───────────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT * FROM file_alertes_admin()$$, '42501', NULL, 'pharmacien : file refusée');
SELECT throws_ok($$SELECT chronologie_alerte('00000000-0000-0000-0000-0000000a0003')$$, '42501', NULL, 'pharmacien : chronologie refusée');
SELECT throws_ok($$SELECT indicateurs_alertes(30)$$, '42501', NULL, 'pharmacien : indicateurs refusés');
SELECT throws_ok($$SELECT etat_budget_messages()$$, '42501', NULL, 'pharmacien : budget refusé');
SELECT throws_ok($$SELECT admin_annuler_alerte('00000000-0000-0000-0000-0000000a0003')$$, '42501', NULL, 'pharmacien : annulation refusée');
SELECT throws_ok($$SELECT admin_transmettre('00000000-0000-0000-0000-0000000a0003', ARRAY['00000000-0000-0000-0000-0000000000d1']::uuid[])$$, '42501', NULL, 'pharmacien : transmission refusée');
SELECT is((SELECT count(*)::int FROM journal_admin_alertes), 0, 'pharmacien : journal invisible (RLS)');
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT * FROM file_alertes_admin()$$, '42501', NULL, 'patient : file refusée');
SELECT throws_ok($$SELECT admin_bloquer_patient('00000000-0000-0000-0000-0000000a0003')$$, '42501', NULL, 'patient : blocage refusé');
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT * FROM file_alertes_admin()$$, '42501', NULL, 'anonyme : file refusée');
SELECT throws_ok($$SELECT admin_cloturer_alerte('00000000-0000-0000-0000-0000000a0004')$$, '42501', NULL, 'anonyme : clôture refusée');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);

-- ── File et chronologie ───────────────────────────────────────────────
SELECT is((SELECT count(*)::int FROM file_alertes_admin()), 5, 'admin : file complète');
SELECT is((SELECT id_public FROM file_alertes_admin() LIMIT 1), 'NG-AAAAAAA2', 'file : les alertes en revue d''abord (la plus récente d''abord)');
SELECT is((SELECT count(*)::int FROM file_alertes_admin(ARRAY['needs_review'])), 2, 'file : filtre par statut');
SELECT is((SELECT nb_envois || '/' || nb_reponses || '/' || nb_positives FROM file_alertes_admin(ARRAY['answered'])), '2/1/1', 'file : compteurs d''envois, réponses, positives');
SELECT is((SELECT medicament FROM file_alertes_admin(ARRAY['needs_review']) WHERE id_public = 'NG-AAAAAAA2'), '(non reconnu)', 'file : médicament non reconnu');
SELECT is((SELECT count(*)::int FROM file_alertes_admin(NULL, 2)), 2, 'file : limite respectée');

SELECT is(jsonb_typeof(chronologie_alerte('00000000-0000-0000-0000-0000000a0004') -> 'evenements'), 'array', 'chronologie : liste d''événements');
SELECT is((SELECT array_agg(e ->> 'type' ORDER BY e ->> 't', array_position(ARRAY['creation','envoi','reponse','premiere_reponse_positive'], e ->> 'type')) FROM jsonb_array_elements(chronologie_alerte('00000000-0000-0000-0000-0000000a0004') -> 'evenements') e WHERE e ->> 'type' IN ('creation','envoi','reponse','premiere_reponse_positive')),
    ARRAY['creation','envoi','envoi','reponse','premiere_reponse_positive'], 'chronologie : création, envois, réponse puis repère « première réponse positive » (ordre chronologique)');
SELECT is((SELECT (e -> 'detail_score' -> 'criteres' -> 0 ->> 'cle') FROM jsonb_array_elements(chronologie_alerte('00000000-0000-0000-0000-0000000a0003') -> 'evenements') e WHERE e ->> 'type' = 'envoi'), 'meme_quartier', 'chronologie : détail du score visible pour l''admin');
SELECT is((SELECT count(*)::int FROM jsonb_array_elements(chronologie_alerte('00000000-0000-0000-0000-0000000a0003') -> 'evenements') e WHERE e ->> 'type' = 'message'), 2, 'chronologie : messages de l''envoi et du patient');
SELECT is((chronologie_alerte('00000000-0000-0000-0000-0000000a0003') ->> 'cout_estime_total')::numeric, 0.02, 'chronologie : coût estimé');
SELECT is(chronologie_alerte('00000000-0000-0000-0000-0000000a0003')::text ~ 'deadbeef|contact_patient|adresse_chiffree|empreinte', false, 'chronologie : aucun contact ni empreinte renvoyés');
SELECT is(chronologie_alerte('00000000-0000-0000-0000-000000009999'), NULL, 'chronologie : alerte inconnue -> NULL');
SELECT cmp_ok((SELECT count(*)::int FROM journal_admin_alertes WHERE action = 'consultation' AND alerte_id = '00000000-0000-0000-0000-0000000a0003'), '>=', 1, 'consultation journalisée (accès admin)');
SELECT is((SELECT admin_id FROM journal_admin_alertes WHERE action = 'consultation' LIMIT 1), '00000000-0000-0000-0000-0000000000a1'::uuid, 'journal : identité de l''admin');

-- ── Rattacher ─────────────────────────────────────────────────────────
SELECT throws_ok($$SELECT admin_rattacher_medicament('00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-00000000e001')$$, '55000', NULL, 'rattacher : seulement une alerte en revue');
SELECT throws_ok($$SELECT admin_rattacher_medicament('00000000-0000-0000-0000-0000000a0002', '00000000-0000-0000-0000-00000000e003')$$, 'P0002', NULL, 'rattacher : médicament archivé refusé');
SELECT is(admin_rattacher_medicament('00000000-0000-0000-0000-0000000a0002', '00000000-0000-0000-0000-00000000e002'), 'needs_review', 'rattacher à un médicament restreint : reste en revue');
SELECT is((SELECT raison_revue FROM alertes_routage WHERE id = '00000000-0000-0000-0000-0000000a0002'), 'restreint', 'raison mise à jour : restreint');
SELECT is(admin_rattacher_medicament('00000000-0000-0000-0000-0000000a0002', '00000000-0000-0000-0000-00000000e001'), 'new', 'rattacher à un médicament routable : repart en routage automatique');
SELECT is((SELECT medicament_id || '/' || COALESCE(raison_revue, 'null') FROM alertes_routage WHERE id = '00000000-0000-0000-0000-0000000a0002'), '00000000-0000-0000-0000-00000000e001/null', 'alerte rattachée, raison levée');

-- ── Transmettre (action manuelle tracée) ──────────────────────────────
SELECT throws_ok($$SELECT admin_transmettre('00000000-0000-0000-0000-0000000a0005', ARRAY['00000000-0000-0000-0000-0000000000d1']::uuid[])$$, '55000', NULL, 'transmettre : alerte terminée refusée');
RESET ROLE;
UPDATE alertes_routage SET medicament_id = NULL, statut = 'needs_review' WHERE id = '00000000-0000-0000-0000-0000000a0002';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT admin_transmettre('00000000-0000-0000-0000-0000000a0002', ARRAY['00000000-0000-0000-0000-0000000000d1']::uuid[])$$, '55000', NULL, 'transmettre : médicament à rattacher d''abord');
SELECT throws_ok($$SELECT admin_transmettre('00000000-0000-0000-0000-0000000a0001', '{}'::uuid[])$$, '22023', NULL, 'transmettre : au moins une pharmacie');
SELECT is((SELECT (admin_transmettre('00000000-0000-0000-0000-0000000a0001', ARRAY['00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000d2','00000000-0000-0000-0000-0000000000d3','00000000-0000-0000-0000-0000000000d4','00000000-0000-0000-0000-000000009999']::uuid[])) ->> 'acceptees')::int, 1,
    'transmettre : seule la pharmacie vérifiée avec contact actif est acceptée');
SELECT is((SELECT statut || '/' || routage_manuel::text || '/' || vague FROM alertes_routage WHERE id = '00000000-0000-0000-0000-0000000a0001'), 'routing/true/1', 'transmettre : routing manuel, plus de vague automatique');
SELECT is((SELECT count(*)::int FROM ordres_admin_alertes WHERE alerte_id = '00000000-0000-0000-0000-0000000a0001' AND type = 'transmettre' AND traite_le IS NULL), 1, 'transmettre : un ordre en attente pour le planificateur');
SELECT is((SELECT params -> 'pharmacie_ids' ->> 0 FROM ordres_admin_alertes WHERE alerte_id = '00000000-0000-0000-0000-0000000a0001'), '00000000-0000-0000-0000-0000000000d1', 'ordre : la pharmacie acceptée');
SELECT is((SELECT details -> 'refusees' FROM journal_admin_alertes WHERE action = 'transmettre' LIMIT 1) @> '[{"raison":"non_verifiee"},{"raison":"aucun_contact_actif"},{"raison":"introuvable"}]'::jsonb, true, 'journal : refus motivés (non vérifiée, sans contact, introuvable)');
SELECT is((SELECT (admin_transmettre('00000000-0000-0000-0000-0000000a0003', ARRAY['00000000-0000-0000-0000-0000000000d1']::uuid[])) -> 'refusees' -> 0 ->> 'raison'), 'deja_sollicitee', 'transmettre : pharmacie déjà sollicitée refusée');

-- ── Refuser ───────────────────────────────────────────────────────────
RESET ROLE;
UPDATE alertes_routage SET statut = 'needs_review', routage_manuel = false WHERE id = '00000000-0000-0000-0000-0000000a0002';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT admin_refuser_alerte('00000000-0000-0000-0000-0000000a0003')$$, '55000', NULL, 'refuser : seulement une alerte en revue');
SELECT lives_ok($$SELECT admin_refuser_alerte('00000000-0000-0000-0000-0000000a0002')$$, 'refuser une alerte en revue');
SELECT is((SELECT statut FROM alertes_routage WHERE id = '00000000-0000-0000-0000-0000000a0002'), 'cancelled', 'refus : alerte annulée');
SELECT is((SELECT count(*)::int FROM ordres_admin_alertes WHERE alerte_id = '00000000-0000-0000-0000-0000000a0002' AND type = 'refuser'), 1, 'refus : message au patient à envoyer (ordre)');

-- ── Relancer, clôturer ────────────────────────────────────────────────
SELECT is(admin_relancer_vague('00000000-0000-0000-0000-0000000a0003'), 0, 'relancer : on recule d''une vague');
SELECT ok((SELECT debut_routage_le > now() - interval '1 minute' FROM alertes_routage WHERE id = '00000000-0000-0000-0000-0000000a0003'), 'relancer : les délais repartent de maintenant');
SELECT throws_ok($$SELECT admin_relancer_vague('00000000-0000-0000-0000-0000000a0004')$$, '55000', NULL, 'relancer : pas après une réponse positive');
SELECT throws_ok($$SELECT admin_relancer_vague('00000000-0000-0000-0000-0000000a0001')$$, '55000', NULL, 'relancer : pas en routage manuel');
SELECT throws_ok($$SELECT admin_cloturer_alerte('00000000-0000-0000-0000-0000000a0005')$$, '55000', NULL, 'clôturer : pas une alerte terminée');
SELECT lives_ok($$SELECT admin_cloturer_alerte('00000000-0000-0000-0000-0000000a0004')$$, 'clôturer une alerte répondue');
SELECT is((SELECT statut FROM alertes_routage WHERE id = '00000000-0000-0000-0000-0000000a0004'), 'fulfilled', 'clôture : fulfilled');
SELECT is((SELECT statut FROM envois_alerte WHERE id = 'abcdef03-0000-4000-8000-000000000003'), 'expired', 'clôture : envois sans réponse expirés');
SELECT is((SELECT statut FROM envois_alerte WHERE id = 'abcdef02-0000-4000-8000-000000000002'), 'responded', 'clôture : réponses conservées');

-- ── Retirer un destinataire, annuler ──────────────────────────────────
SELECT lives_ok($$SELECT admin_retirer_destinataire('abcdef01-0000-4000-8000-000000000001')$$, 'retirer un destinataire');
SELECT is((SELECT statut FROM envois_alerte WHERE id = 'abcdef01-0000-4000-8000-000000000001'), 'cancelled', 'envoi annulé');
SELECT is((SELECT statut FROM notifications_outbox WHERE cle_idempotence = 'k-q1'), 'cancelled', 'message en file annulé (ne partira pas)');
SELECT throws_ok($$SELECT admin_retirer_destinataire('abcdef02-0000-4000-8000-000000000002')$$, '55000', NULL, 'retirer : pas un destinataire déjà répondu');
SELECT lives_ok($$SELECT admin_annuler_alerte('00000000-0000-0000-0000-0000000a0003')$$, 'annuler une alerte');
SELECT is((SELECT statut FROM notifications_outbox WHERE cle_idempotence = 'k-pat'), 'cancelled', 'annulation : messages au patient en file annulés');
SELECT throws_ok($$SELECT admin_annuler_alerte('00000000-0000-0000-0000-0000000a0003')$$, '55000', NULL, 'annuler : pas deux fois');

-- ── Bloquer un patient ────────────────────────────────────────────────
RESET ROLE;
UPDATE alertes_routage SET statut = 'routing' WHERE id = '00000000-0000-0000-0000-0000000a0001';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT lives_ok($$SELECT admin_bloquer_patient('00000000-0000-0000-0000-0000000a0001', 'abus répété')$$, 'bloquer un patient');
SELECT is((SELECT count(*)::int FROM patients_bloques WHERE empreinte_patient IN ('h-restreint', 'ip-restreint')), 2, 'blocage : numéro et IP (empreintes) bloqués');
SELECT is((SELECT statut FROM alertes_routage WHERE id = '00000000-0000-0000-0000-0000000a0001'), 'cancelled', 'blocage : alerte annulée');
RESET ROLE;
SELECT is((SELECT refus FROM creer_alerte_routage('NG-ZZZZZZZ1', '00000000-0000-0000-0000-00000000e001', NULL, '00000000-0000-0000-0000-00000000f001', NULL, NULL, 'normal', 'none', NULL, 'h-restreint', 'ip-x', false, now() + interval '1 hour')),
    'bloque', 'une nouvelle demande du même numéro est refusée');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);

-- ── Réglages : validation et journal ──────────────────────────────────
SELECT throws_ok($$UPDATE config_routage SET valeur = '0' WHERE cle = 'vague1_taille'$$, '22023', NULL, 'réglage : vague1_taille 0 refusé');
SELECT throws_ok($$UPDATE config_routage SET valeur = '2.5' WHERE cle = 'vague1_taille'$$, '22023', NULL, 'réglage : entier exigé');
SELECT throws_ok($$UPDATE config_routage SET valeur = '"trois"' WHERE cle = 'vague1_taille'$$, '22023', NULL, 'réglage : nombre exigé');
SELECT throws_ok($$UPDATE config_routage SET valeur = '1.5' WHERE cle = 'facteur_delai_urgent'$$, '22023', NULL, 'réglage : facteur urgent ≤ 1');
SELECT throws_ok($$UPDATE config_routage SET valeur = '[]' WHERE cle = 'retry_delais_s'$$, '22023', NULL, 'réglage : au moins un délai de relance');
SELECT throws_ok($$UPDATE config_routage SET valeur = '{"critere_inconnu": 5}' WHERE cle = 'score_poids'$$, '22023', NULL, 'réglage : critère de score inconnu refusé');
SELECT throws_ok($$UPDATE config_routage SET valeur = '{"meme_quartier": 500}' WHERE cle = 'score_poids'$$, '22023', NULL, 'réglage : poids hors bornes refusé');
SELECT throws_ok($$INSERT INTO config_routage (cle, valeur) VALUES ('cle_inventee', '1')$$, '22023', NULL, 'réglage : clé inconnue refusée (faute de frappe)');
SELECT throws_ok($$UPDATE config_routage SET valeur = '999' WHERE cle = 'debit_global_par_s'$$, '22023', NULL, 'réglage : débit global plafonné à 30/s');
SELECT lives_ok($$UPDATE config_routage SET valeur = '4' WHERE cle = 'vague1_taille'$$, 'réglage valide accepté');
SELECT is((SELECT details ->> 'avant' || '->' || (details ->> 'apres') FROM journal_admin_alertes WHERE action = 'config' AND details ->> 'cle' = 'vague1_taille'), '3->4', 'réglage : ancienne et nouvelle valeur journalisées');
SELECT throws_ok($$UPDATE config_routage SET valeur = '"production"' WHERE cle = 'mode_application'$$, '23514', NULL, 'verrou de production toujours actif');

-- ── Budget ────────────────────────────────────────────────────────────
UPDATE config_routage SET valeur = '10' WHERE cle = 'budget_messages_jour';
SELECT is((etat_budget_messages() ->> 'alerte_80')::boolean, false, 'budget : sous 80 %');
RESET ROLE;
INSERT INTO notifications_outbox (cle_idempotence, type_destinataire, canal, modele, adresse_chiffree, statut)
    SELECT 'sms-' || g, 'pharmacy', 'sms', 'alerte_demande_sms', '\x01', 'sent' FROM generate_series(1, 8) g;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT is((etat_budget_messages() ->> 'alerte_80')::boolean, true, 'budget : alerte à 80 %');
SELECT is((etat_budget_messages() ->> 'depasse')::boolean, false, 'budget : pas encore dépassé');

-- ── Indicateurs ───────────────────────────────────────────────────────
SELECT is((indicateurs_alertes(30) ->> 'nb_alertes')::int, 5, 'indicateurs : nombre d''alertes');
SELECT is((indicateurs_alertes(30) -> 'par_statut' ->> 'cancelled')::int, 3, 'indicateurs : répartition par statut');
SELECT is((indicateurs_alertes(30) ->> 'delai_median_premiere_reponse_s')::int, 300, 'indicateurs : délai médian jusqu''à la première réponse positive (5 min)');
SELECT is((indicateurs_alertes(30) ->> 'part_reponse_positive_15min')::numeric, 0.5, 'indicateurs : part de réponses positives sous 15 min (1 alerte routée sur 2 sans annulation)');
SELECT is((SELECT (x ->> 'taux')::numeric FROM jsonb_array_elements(indicateurs_alertes(30) -> 'taux_reponse_pharmacies') x WHERE x ->> 'nom' = 'Pharmacie 1'), 1.0, 'indicateurs : taux de réponse par pharmacie (les envois annulés ne comptent pas)');
SELECT is((indicateurs_alertes(30) -> 'activation_telegram' ->> 'pharmacies_publiees')::int, 3, 'indicateurs : pharmacies publiées');
SELECT is((indicateurs_alertes(30) -> 'activation_telegram' ->> 'avec_telegram')::int, 1, 'indicateurs : une seule avec Telegram vérifié');
SELECT is((indicateurs_alertes(30) -> 'repli_sms' ->> 'sms_de_repli')::int, 1, 'indicateurs : SMS de repli');
SELECT is((indicateurs_alertes(30) -> 'messages' -> 'telegram' ->> 'echecs')::int, 1, 'indicateurs : échecs Telegram');
SELECT is((indicateurs_alertes(30) -> 'mises_a_jour_stock' ->> 'disponible')::int, 1, 'indicateurs : mises à jour de stock issues des alertes');
SELECT is((indicateurs_alertes(30) -> 'cout' ->> 'total_estime')::numeric, 0.02, 'indicateurs : coût estimé total');
SELECT is((indicateurs_alertes(30) ->> 'needs_review_en_attente')::int, 0, 'indicateurs : plus d''alerte en revue');
SELECT is((indicateurs_alertes(0) ->> 'jours')::int, 1, 'indicateurs : période bornée à 1 jour minimum');

SELECT * FROM finish();
ROLLBACK;
