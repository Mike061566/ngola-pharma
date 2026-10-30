-- pgTAP — rappels d'onboarding : candidats (approuvées, vérifiées, non publiées), jours écoulés, étape bloquante, jalons enregistrés une seule fois,
-- accès réservé (service / admin), liste des pharmacies en retard.
BEGIN;
SELECT plan(23);

INSERT INTO auth.users (id, email) VALUES ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'), ('00000000-0000-0000-0000-0000000000b1', 'p@test.local');
INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Q', 'q');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude, statut, est_publiee, est_demo, horaires)
SELECT ('00000000-0000-0000-0000-0000000000d' || g)::uuid, 'Pharmacie ' || g, 'p' || g, '00000000-0000-0000-0000-00000000f001', 3.85, 11.5,
       CASE WHEN g = 5 THEN 'non_verifie'::statut_pharmacie ELSE 'verifie'::statut_pharmacie END, g = 4, true, '{}' FROM generate_series(1, 6) g;
INSERT INTO profils (id, role, pharmacie_id) VALUES ('00000000-0000-0000-0000-0000000000a1', 'admin', NULL), ('00000000-0000-0000-0000-0000000000b1', 'pharmacien', '00000000-0000-0000-0000-0000000000d1');
-- Demandes : d1 approuvée il y a 2 jours (compte actif), d2 il y a 8 jours (compte non activé), d3 il y a 40 jours, d4 publiée, d5 non vérifiée, d6 refusée
INSERT INTO demandes_partenaire (id, statut, nom_pharmacie, quartier_id, adresse, telephone_fixe, nom_titulaire, numero_ordre, email_titulaire, telephone_mobile, horaires,
    consentement_conditions_le, consentement_messages_le, pharmacie_id, decidee_le, compte_cree_le)
SELECT ('00000000-0000-0000-0000-000000d0000' || g)::uuid, CASE WHEN g = 6 THEN 'rejected' ELSE 'approved' END, 'Pharmacie ' || g, '00000000-0000-0000-0000-00000000f001', 'Rue 1', '+23722200000' || g,
       'Dr ' || g, 'ORD-' || g, 'titulaire' || g || '@exemple.test', '+23769900000' || g, '{}', now(), now(),
       CASE WHEN g = 6 THEN NULL ELSE ('00000000-0000-0000-0000-0000000000d' || g)::uuid END,
       now() - (CASE g WHEN 1 THEN 2 WHEN 2 THEN 8 WHEN 3 THEN 40 ELSE 10 END) * interval '1 day' - interval '1 hour',
       CASE WHEN g = 2 THEN NULL ELSE now() END
  FROM generate_series(1, 6) g;
INSERT INTO rappels_onboarding (pharmacie_id, jalon) VALUES ('00000000-0000-0000-0000-0000000000d2', 1), ('00000000-0000-0000-0000-0000000000d2', 3);

CREATE TEMP TABLE cand AS SELECT c FROM jsonb_array_elements(candidats_rappels_interne()) c;
SELECT is((SELECT count(*)::int FROM cand), 3, 'candidats : seulement les approuvées, vérifiées et non publiées (d1, d2, d3)');
SELECT is((SELECT (c ->> 'jours')::int FROM cand WHERE c ->> 'nom' = 'Pharmacie 1'), 2, 'jours écoulés depuis l''approbation : 2');
SELECT is((SELECT (c ->> 'jours')::int FROM cand WHERE c ->> 'nom' = 'Pharmacie 3'), 40, 'jours écoulés : 40');
SELECT is((SELECT c ->> 'etape' FROM cand WHERE c ->> 'nom' = 'Pharmacie 1'), 'mot_de_passe', 'étape bloquante : le mot de passe (1re tâche non faite)');
SELECT is((SELECT (c ->> 'compte_actif')::boolean FROM cand WHERE c ->> 'nom' = 'Pharmacie 2'), false, 'compte non activé repéré');
SELECT is((SELECT c -> 'deja' FROM cand WHERE c ->> 'nom' = 'Pharmacie 2'), '[1, 3]'::jsonb, 'jalons déjà envoyés listés');
SELECT is((SELECT c -> 'deja' FROM cand WHERE c ->> 'nom' = 'Pharmacie 1'), '[]'::jsonb, 'aucun jalon pour une pharmacie sans rappel');
SELECT is((SELECT c ->> 'email' FROM cand WHERE c ->> 'nom' = 'Pharmacie 1'), 'titulaire1@exemple.test', 'email du titulaire fourni');
SELECT ok(NOT EXISTS (SELECT 1 FROM cand WHERE c::text ~* 'adresse|chat_id|telephone'), 'aucune coordonnée de contact téléphonique ni adresse dans les candidats');

-- Une pharmacie dont le mot de passe est défini passe à l'étape suivante
INSERT INTO etat_onboarding_pharmacie (pharmacie_id, etat) VALUES ('00000000-0000-0000-0000-0000000000d1', jsonb_build_object('mot_de_passe_defini_le', now()));
SELECT is((SELECT c ->> 'etape' FROM jsonb_array_elements(candidats_rappels_interne()) c WHERE c ->> 'nom' = 'Pharmacie 1'), 'ma_pharmacie', 'étape suivante après le mot de passe');
-- Publiée : plus de rappel
UPDATE pharmacies SET est_publiee = true WHERE id = '00000000-0000-0000-0000-0000000000d1';
SELECT is((SELECT count(*)::int FROM jsonb_array_elements(candidats_rappels_interne()) c WHERE c ->> 'nom' = 'Pharmacie 1'), 0, 'une pharmacie publiée n''est plus relancée');
UPDATE pharmacies SET est_publiee = false WHERE id = '00000000-0000-0000-0000-0000000000d1';

-- Enregistrement des jalons
SELECT is(enregistrer_rappel_interne('00000000-0000-0000-0000-0000000000d1', 1, '["email","telegram"]'), true, 'jalon 1 enregistré');
SELECT is(enregistrer_rappel_interne('00000000-0000-0000-0000-0000000000d1', 1, '["email"]'), false, 'jalon 1 : second enregistrement ignoré (idempotent)');
SELECT is((SELECT canaux FROM rappels_onboarding WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND jalon = 1), '["email", "telegram"]'::jsonb, 'canaux du premier enregistrement conservés');
SELECT is((SELECT count(*)::int FROM evenements_onboarding WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND evenement = 'rappel_envoye'), 1, 'audit : rappel_envoye une seule fois');
SELECT is(enregistrer_rappel_interne('00000000-0000-0000-0000-0000000000d3', 30, '["email"]'), true, 'alerte dormante (jalon 30) enregistrée');
SELECT is((SELECT count(*)::int FROM evenements_onboarding WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d3' AND evenement = 'alerte_dormante'), 1, 'audit : alerte_dormante');
SELECT throws_ok($$SELECT enregistrer_rappel_interne('00000000-0000-0000-0000-0000000000d1', 2, '[]')$$, '23514', NULL, 'jalon inconnu refusé');

-- Accès
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT candidats_rappels_interne()$$, '42501', NULL, 'anon : candidats refusés');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT candidats_rappels_interne()$$, '42501', NULL, 'pharmacien : candidats refusés');
SELECT throws_ok($$SELECT admin_pharmacies_en_retard()$$, '42501', NULL, 'pharmacien : liste admin refusée');
SELECT is((SELECT count(*)::int FROM rappels_onboarding), 0, 'pharmacien : ne lit pas les rappels');
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
SELECT is((SELECT jsonb_array_length(admin_pharmacies_en_retard())), 4, 'admin : 4 pharmacies non publiées (d1, d2, d3 et d5, anomalie « approuvée mais non vérifiée » visible)');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
