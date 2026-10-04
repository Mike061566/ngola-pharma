-- ============================================================
-- Retour arrière de l'archivage des anciennes fiches de test — À EXÉCUTER À LA MAIN.
-- Restaure statut_catalogue d'après la table de sauvegarde (état exact d'avant). Simulation par défaut (ROLLBACK).
-- ============================================================
BEGIN;
UPDATE public.medicaments m
   SET statut_catalogue = s.statut_avant
  FROM public.sauvegarde_archivage_fiches_test s
 WHERE s.medicament_id = m.id;
SELECT count(*) AS fiches_restaurees FROM public.sauvegarde_archivage_fiches_test;
ROLLBACK;   -- SIMULATION. Remplacer par COMMIT pour appliquer. La table de sauvegarde est conservée (supprimez-la à la main si besoin).
