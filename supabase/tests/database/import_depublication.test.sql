-- pgTAP — fin d'annulation d'un import : réévaluation de la règle de publication, dépublication automatique (avec audit) si le seuil n'est
-- plus atteint ; jamais de dépublication d'une pharmacie publiée à la main ; jamais si la règle reste satisfaite.
BEGIN;
SELECT plan(27);

INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Q', 'q');
INSERT INTO auth.users (id, email) SELECT ('00000000-0000-0000-0000-0000000000b' || g)::uuid, 'p' || g || '@test.local' FROM generate_series(1, 4) g;
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude, statut, est_publiee, est_demo, horaires)
SELECT ('00000000-0000-0000-0000-0000000000d' || g)::uuid, 'Pharmacie ' || g, 'p' || g, '00000000-0000-0000-0000-00000000f001', 3.85, 11.5, 'verifie', g = 3, true,
       '{"lun":{"ouv":"08:00","fer":"20:00"}}' FROM generate_series(1, 4) g;      -- la pharmacie 3 est publiée À LA MAIN (aucun événement de publication)
INSERT INTO profils (id, role, pharmacie_id) SELECT ('00000000-0000-0000-0000-0000000000b' || g)::uuid, 'pharmacien', ('00000000-0000-0000-0000-0000000000d' || g)::uuid FROM generate_series(1, 4) g;
INSERT INTO medicaments (id, nom, dosage, forme, restreint, est_demo)
SELECT ('00000000-0000-0000-0000-0000000e' || lpad(g::text, 4, '0'))::uuid, n, '10mg', 'comprimé', false, true
  FROM unnest(ARRAY['Amlodipine', 'Bisoprolol', 'Captopril', 'Digoxine', 'Enalapril', 'Furosémide', 'Glibenclamide', 'Hydrochlorothiazide', 'Indapamide', 'Lisinopril', 'Metformine', 'Nifédipine']) WITH ORDINALITY t(n, g);
INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock, date_maj)
SELECT ('00000000-0000-0000-0000-0000000000d' || p)::uuid, ('00000000-0000-0000-0000-0000000e' || lpad(g::text, 4, '0'))::uuid, 1000 + g, true, now() - interval '30 days'
  FROM generate_series(1, 4) p, generate_series(1, 12) g;
INSERT INTO contacts_pharmacie (pharmacie_id, canal, adresse, consentement_le, verifie_le)
SELECT ('00000000-0000-0000-0000-0000000000d' || g)::uuid, 'telegram', '5551' || g, now(), now() FROM generate_series(1, 4) g;
CREATE TEMP TABLE ctx (cle text PRIMARY KEY, valeur text);
GRANT ALL ON ctx TO PUBLIC;
CREATE FUNCTION pg_temp.lignes() RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_agg(jsonb_build_object('numero', g, 'nom', n, 'dosage', '10mg', 'prix', 2000 + g) ORDER BY g)
      FROM unnest(ARRAY['Amlodipine', 'Bisoprolol', 'Captopril', 'Digoxine', 'Enalapril', 'Furosémide', 'Glibenclamide', 'Hydrochlorothiazide', 'Indapamide', 'Lisinopril', 'Metformine', 'Nifédipine']) WITH ORDINALITY t(n, g) $f$;
CREATE FUNCTION pg_temp.importer(p_nom text) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v uuid := import_creer_lot(p_nom, 'merge');
BEGIN PERFORM import_ajouter_lignes(v, pg_temp.lignes()); PERFORM import_finaliser_lot(v); RETURN v; END $f$;
CREATE FUNCTION pg_temp.preparer() RETURNS void LANGUAGE plpgsql AS $f$
BEGIN PERFORM onboarding_marquer('mot_de_passe_defini'); PERFORM onboarding_marquer('gps_confirme'); PERFORM confirmer_mes_stocks(); END $f$;

-- ── Pharmacie 1 : publiée automatiquement par l'import, puis dépubliée à l'annulation ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT pg_temp.preparer();
SELECT is((SELECT est_publiee FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d1'), false, 'P1 : pas encore publiée (aucun import validé)') ;
INSERT INTO ctx VALUES ('lot1', pg_temp.importer('p1.csv')::text);
SELECT is((import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot1')) ->> 'publiee')::boolean, true, 'P1 : l''import validé déclenche la publication automatique');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM evenements_onboarding WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND evenement = 'pharmacie_publiee'), 1, 'P1 : événement de publication enregistré');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT is((import_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot1')) ->> 'depubliee')::boolean, true, 'P1 : annulation du seul import -> dépubliée automatiquement');
RESET ROLE;
SELECT is((SELECT est_publiee FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d1'), false, 'P1 : est_publiee = false');
SELECT is((SELECT publiee_le FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d1'), NULL, 'P1 : date de publication effacée');
SELECT is((SELECT count(*)::int FROM evenements_onboarding WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND evenement = 'pharmacie_depubliee'), 1, 'P1 : événement d''audit pharmacie_depubliee');
SELECT is((SELECT details ->> 'raison' FROM evenements_onboarding WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND evenement = 'pharmacie_depubliee'), 'import_annule', 'P1 : raison de l''audit');
SELECT is((SELECT details -> 'taches_manquantes' FROM evenements_onboarding WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND evenement = 'pharmacie_depubliee'), '["import"]'::jsonb, 'P1 : l''audit nomme la tâche manquante (import)');
SELECT is((SELECT acteur_type FROM evenements_onboarding WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND evenement = 'pharmacie_depubliee'), 'system', 'P1 : acteur = système');

-- Republication à la main par l'admin : une seconde annulation ne dépublie PLUS (dernier événement = dépublication)
UPDATE pharmacies SET est_publiee = true, publiee_le = now() WHERE id = '00000000-0000-0000-0000-0000000000d1';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
INSERT INTO ctx VALUES ('lot1b', pg_temp.importer('p1b.csv')::text);
SELECT import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot1b'));
SELECT is((import_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot1b')) ->> 'depubliee')::boolean, false, 'P1 republiée à la main : l''annulation ne la dépublie pas');
RESET ROLE;
SELECT is((SELECT est_publiee FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d1'), true, 'P1 : reste publiée (décision de l''admin respectée)');
SELECT is((SELECT count(*)::int FROM evenements_onboarding WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d1' AND evenement = 'pharmacie_depubliee'), 1, 'P1 : pas de second événement de dépublication');

-- ── Pharmacie 2 : deux imports ; annuler le second ne change rien (la règle reste satisfaite) ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
SELECT pg_temp.preparer();
INSERT INTO ctx VALUES ('lot2a', pg_temp.importer('p2a.csv')::text);
SELECT import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot2a'));
INSERT INTO ctx VALUES ('lot2b', pg_temp.importer('p2b.csv')::text);
SELECT import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot2b'));
RESET ROLE;
SELECT is((SELECT est_publiee FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d2'), true, 'P2 : publiée automatiquement');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
SELECT is((import_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot2b')) ->> 'depubliee')::boolean, false, 'P2 : un autre import reste validé et les stocks sont frais -> pas de dépublication');
RESET ROLE;
SELECT is((SELECT est_publiee FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d2'), true, 'P2 : reste publiée');
SELECT is((SELECT count(*)::int FROM evenements_onboarding WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d2' AND evenement = 'pharmacie_depubliee'), 0, 'P2 : aucun événement de dépublication');

-- Le temps passe : les stocks de P2 vieillissent (plus de 7 jours) ; un nouvel import puis son annulation restaurent des valeurs périmées
UPDATE stocks SET confirme_le = now() - interval '20 days', date_maj = now() - interval '20 days' WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d2';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
INSERT INTO ctx VALUES ('lot2c', pg_temp.importer('p2c.csv')::text);
SELECT import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot2c'));
SELECT is((import_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot2c')) ->> 'depubliee')::boolean, true, 'P2 : après vieillissement, l''annulation restaure des stocks périmés -> seuil de fraîcheur perdu -> dépubliée');
RESET ROLE;
SELECT is((SELECT details -> 'taches_manquantes' FROM evenements_onboarding WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d2' AND evenement = 'pharmacie_depubliee'), '["seuil"]'::jsonb, 'P2 : l''audit nomme le seuil (stocks frais) comme manquant');
SELECT is((SELECT (details ->> 'items_frais')::int FROM evenements_onboarding WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d2' AND evenement = 'pharmacie_depubliee'), 0, 'P2 : l''audit indique 0 stock frais');

-- ── Pharmacie 3 : publiée à la main, jamais touchée par une annulation d'import ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b3","role":"authenticated"}', true);
INSERT INTO ctx VALUES ('lot3', pg_temp.importer('p3.csv')::text);
SELECT import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot3'));
SELECT is((import_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot3')) ->> 'depubliee')::boolean, false, 'P3 (publiée à la main, checklist incomplète) : jamais dépubliée par une annulation');
RESET ROLE;
SELECT is((SELECT est_publiee FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d3'), true, 'P3 : reste publiée');

-- ── Pharmacie 4 : jamais publiée -> rien à dépublier ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b4","role":"authenticated"}', true);
INSERT INTO ctx VALUES ('lot4', pg_temp.importer('p4.csv')::text);
SELECT import_valider_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot4'));
SELECT is((import_annuler_lot((SELECT valeur::uuid FROM ctx WHERE cle = 'lot4')) ->> 'depubliee')::boolean, false, 'P4 (jamais publiée) : rien à dépublier');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM evenements_onboarding WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d4' AND evenement = 'pharmacie_depubliee'), 0, 'P4 : aucun événement');

-- ── Accès : la fonction interne n'est pas exécutable par le navigateur ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SELECT throws_ok($$SELECT evaluer_depublication_interne('00000000-0000-0000-0000-0000000000d1', 'test')$$, '42501', NULL, 'evaluer_depublication_interne : non exécutable par un pharmacien');
RESET ROLE;
SELECT is((SELECT est_publiee FROM pharmacies WHERE id = '00000000-0000-0000-0000-0000000000d1'), true, 'aucune dépublication possible hors fin d''annulation (P1 toujours publiée)');
SELECT is((SELECT count(*)::int FROM evenements_onboarding WHERE evenement = 'pharmacie_depubliee'), 2, 'au total : 2 dépublications automatiques (P1 puis P2), toutes auditées');

SELECT * FROM finish();
ROLLBACK;
