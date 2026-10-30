-- ============================================================
-- N'Gola Pharma — « Meilleurs prix » : date de mise à jour du prix affiché.
-- PRODUCTION : à exécuter à la main, après sauvegarde et après 20261016000000. Rétro-compatible, n'envoie rien.
-- Une seule colonne ajoutée EN FIN de vue (date_maj du stock retenu) : les colonnes existantes ne bougent pas,
-- les droits existants de la vue sont conservés. Même source de date que les fiches détaillées du site public (stocks.date_maj).
-- ============================================================
BEGIN;

CREATE OR REPLACE VIEW public.v_meilleurs_prix AS
SELECT DISTINCT ON (s.medicament_id)
    s.medicament_id, m.nom AS medicament_nom, m.dci, m.dosage, s.pharmacie_id, ph.nom AS pharmacie_nom, ph.quartier_id,
    q.nom AS quartier_nom, s.prix_fcfa, s.en_stock,
    ph.est_demo AS pharmacie_est_demo,
    s.date_maj
FROM public.stocks s
JOIN public.medicaments m ON m.id = s.medicament_id
JOIN public.pharmacies ph ON ph.id = s.pharmacie_id
JOIN public.quartiers q ON q.id = ph.quartier_id
WHERE s.en_stock = true
ORDER BY s.medicament_id, s.prix_fcfa ASC;

COMMIT;
