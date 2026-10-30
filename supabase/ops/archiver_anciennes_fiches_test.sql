-- ============================================================
-- Archivage des anciennes fiches de test du catalogue (20 fiches de supabase/seed/medicaments.csv) — À EXÉCUTER À LA MAIN
-- par le propriétaire, APRÈS SAUVEGARDE de la base. Réversible : voir archiver_anciennes_fiches_test_retour.sql.
-- Rien n'est supprimé : statut_catalogue passe de 'actif' à 'archive' (stocks, alertes et historique restent intacts).
-- Les fiches sont désignées par (nom_commercial, dosage) EXACTS, tirés du fichier de seed : aucune heuristique. Le `nom` n'est pas comparé :
-- en production il vaut « Paracétamol 500mg » (demo_setup.sql) et non « Paracétamol » (medicaments.csv).
--
-- Mode d'emploi (SQL Editor ou psql) :
--   1. Lancer tel quel : SIMULATION (aucune écriture : la transaction finit par ROLLBACK) -> lire le rapport.
--   2. Si le rapport est conforme, remplacer « ROLLBACK » par « COMMIT » à la dernière ligne et relancer.
-- Les fiches du nouveau catalogue de démo (236) ne sont jamais touchées : elles n'ont pas ces triplets.
-- ============================================================
BEGIN;

-- Sauvegarde de l'état avant (permet le retour arrière exact).
CREATE TABLE IF NOT EXISTS public.sauvegarde_archivage_fiches_test (
    medicament_id  uuid PRIMARY KEY,
    statut_avant   text NOT NULL,
    archive_le     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.sauvegarde_archivage_fiches_test ENABLE ROW LEVEL SECURITY;   -- aucune policy : service/admin SQL seulement

CREATE TEMP TABLE _anciennes (nom text, nom_commercial text, dosage text) ON COMMIT DROP;
INSERT INTO _anciennes VALUES
    ('Paracétamol', 'Doliprane', '500mg'),
    ('Paracétamol', 'Efferalgan', '1000mg'),
    ('Ibuprofène', 'Advil', '400mg'),
    ('Aspirine', 'Aspro', '500mg'),
    ('Amoxicilline', 'Clamoxyl', '500mg'),
    ('Métronidazole', 'Flagyl', '500mg'),
    ('Artemether-Lumefantrine', 'Coartem', '20/120mg'),
    ('Quinine', 'Quinimax', '500mg'),
    ('Oméprazole', 'Mopral', '20mg'),
    ('Métformine', 'Glucophage', '500mg'),
    ('Vitamine C', 'Vitascorbol', '500mg'),
    ('Multivitamines', 'Supradyn', ''),
    ('Chloroquine', 'Nivaquine', '100mg'),
    ('Diclofénac', 'Voltarène', '50mg'),
    ('Cotrimoxazole', 'Bactrim', '800/160mg'),
    ('Cétirizine', 'Zyrtec', '10mg'),
    ('Lopéramide', 'Imodium', '2mg'),
    ('Salbutamol', 'Ventoline', '100µg/dose'),
    ('Fer + Acide folique', 'Tardyféron', '80mg+0.35mg'),
    ('Ciprofloxacine', 'Ciflox', '500mg');

CREATE TEMP TABLE _cibles ON COMMIT DROP AS
SELECT m.id, m.statut_catalogue
FROM public.medicaments m
JOIN _anciennes a ON NULLIF(a.nom_commercial, '') IS NOT DISTINCT FROM NULLIF(m.nom_commercial, '') AND NULLIF(a.dosage, '') IS NOT DISTINCT FROM NULLIF(m.dosage, '')
WHERE m.statut_catalogue = 'actif';

INSERT INTO public.sauvegarde_archivage_fiches_test (medicament_id, statut_avant)
SELECT id, statut_catalogue FROM _cibles
ON CONFLICT (medicament_id) DO NOTHING;

UPDATE public.medicaments SET statut_catalogue = 'archive' WHERE id IN (SELECT id FROM _cibles);

-- Rapport (à relire avant COMMIT) : attendu = au plus 20 fiches ; les stocks et alertes liés restent en place.
SELECT (SELECT count(*) FROM _cibles)                                              AS fiches_archivees,
       (SELECT count(*) FROM _anciennes)                                           AS fiches_attendues,
       (SELECT count(*) FROM public.stocks s JOIN _cibles c ON c.id = s.medicament_id) AS stocks_lies,
       (SELECT count(*) FROM public.alertes_stock a JOIN _cibles c ON c.id = a.medicament_id)     AS alertes_liees,
       (SELECT count(*) FROM public.medicaments WHERE statut_catalogue = 'actif')   AS fiches_actives_restantes;

ROLLBACK;   -- SIMULATION. Remplacer par COMMIT pour appliquer.
