-- pgTAP — paramètres du moteur de routage présents (et cohérents avec les défauts du code).
BEGIN;
SELECT plan(3);
SELECT is((SELECT count(*)::int FROM config_routage WHERE cle IN
    ('stock_frais_jours','stock_tolere_jours','rayon_adjacent_km','equite_seuil_par_heure','taux_reponse_defaut','decalage_horaire_min')),
    6, 'les 6 paramètres du moteur sont présents');
SELECT is((SELECT valeur FROM config_routage WHERE cle = 'stock_frais_jours'), '3'::jsonb, 'stock frais : 3 jours');
SELECT is((SELECT valeur FROM config_routage WHERE cle = 'decalage_horaire_min'), '60'::jsonb, 'Cameroun : UTC+1');
SELECT * FROM finish();
ROLLBACK;
