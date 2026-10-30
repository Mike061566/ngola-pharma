-- ============================================================
-- N'Gola Pharma — PR 3 : paramètres du moteur de routage (SPEC 2 §0.5 : aucune règle chiffrée en dur)
-- PRODUCTION : à exécuter à la main, après relecture, après 20261005000000. Ne remplace jamais une valeur modifiée.
-- Les seuils de la spec qui n'avaient pas de clé (3 j / 7 j de fraîcheur du stock, rayon de 3 km, seuil d'équité à 3
-- demandes/h, taux de réponse par défaut 0,5) et le décalage horaire du Cameroun (UTC+1, sans heure d'été).
-- ============================================================
BEGIN;
INSERT INTO public.config_routage (cle, valeur) VALUES
    ('stock_frais_jours',      '3'),
    ('stock_tolere_jours',     '7'),
    ('rayon_adjacent_km',      '3'),
    ('equite_seuil_par_heure', '3'),
    ('taux_reponse_defaut',    '0.5'),
    ('decalage_horaire_min',   '60')
ON CONFLICT (cle) DO NOTHING;
COMMIT;
