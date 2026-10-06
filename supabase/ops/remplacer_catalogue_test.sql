-- ============================================================
-- Remplacement du catalogue de test (40 lignes = 20 médicaments × 2 exécutions du seed) — À EXÉCUTER À LA MAIN
-- par le propriétaire, APRÈS SAUVEGARDE, AVANT les migrations (état actuel de la production : baseline + fusion non appliquées).
-- Objectif : repartir d'un catalogue unique (les 236 fiches du catalogue de démo), sans fusion de doublons.
--
-- Ce que fait le script (tout dans UNE transaction) :
--   - copie les fiches et les stocks concernés dans le schéma `sauvegarde_remplacement` (retour arrière possible, voir plus bas) ;
--   - supprime les stocks liés à ces fiches (données de test) ;
--   - détache les demandes patient `alertes_stock` (medicament_id = NULL ; le nom saisi `medicament_nom` est conservé : rien n'est supprimé) ;
--   - supprime les fiches du seed, désignées par (nom_commercial, dosage) EXACTS : aucune heuristique, aucune autre fiche touchée.
-- Mode d'emploi : lancer tel quel = SIMULATION (ROLLBACK final) ; lire le rapport ; remplacer ROLLBACK par COMMIT pour appliquer.
-- Retour arrière : voir la fin du fichier.
-- ============================================================
BEGIN;

DO $$
BEGIN
    IF to_regclass('sauvegarde_remplacement.medicaments') IS NOT NULL THEN
        RAISE EXCEPTION 'Script déjà exécuté : le schéma sauvegarde_remplacement existe. Faire le retour arrière (fin du fichier) puis supprimer ce schéma avant de relancer.';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS sauvegarde_remplacement;
REVOKE ALL ON SCHEMA sauvegarde_remplacement FROM PUBLIC, anon, authenticated;

CREATE TEMP TABLE _anciennes (nom_commercial text, dosage text) ON COMMIT DROP;
INSERT INTO _anciennes VALUES
    ('Doliprane', '500mg'), ('Efferalgan', '1000mg'), ('Advil', '400mg'), ('Aspro', '500mg'), ('Clamoxyl', '500mg'),
    ('Flagyl', '500mg'), ('Coartem', '20/120mg'), ('Quinimax', '500mg'), ('Mopral', '20mg'), ('Glucophage', '500mg'),
    ('Vitascorbol', '500mg'), ('Supradyn', ''), ('Nivaquine', '100mg'), ('Voltarène', '50mg'), ('Bactrim', '800/160mg'),
    ('Zyrtec', '10mg'), ('Imodium', '2mg'), ('Ventoline', '100µg/dose'), ('Tardyféron', '80mg+0.35mg'), ('Ciflox', '500mg');

CREATE TEMP TABLE _cibles ON COMMIT DROP AS
SELECT m.id
FROM public.medicaments m
JOIN _anciennes a ON NULLIF(a.nom_commercial, '') IS NOT DISTINCT FROM NULLIF(m.nom_commercial, '')
                 AND NULLIF(a.dosage, '') IS NOT DISTINCT FROM NULLIF(m.dosage, '');

-- Garde-fou : jamais plus de 40 lignes (20 × 2). Au-delà, quelque chose d'inattendu est présent : on s'arrête sans rien modifier.
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM _cibles;
    IF n > 40 THEN RAISE EXCEPTION 'Arrêt : % fiches correspondent (maximum attendu : 40). Rien n''a été modifié.', n; END IF;
END $$;

-- Sauvegardes (copie complète des lignes, même structure que les tables d'origine).
CREATE TABLE sauvegarde_remplacement.medicaments AS SELECT m.* FROM public.medicaments m JOIN _cibles c ON c.id = m.id;
CREATE TABLE sauvegarde_remplacement.stocks AS SELECT s.* FROM public.stocks s JOIN _cibles c ON c.id = s.medicament_id;
CREATE TABLE sauvegarde_remplacement.alertes_stock_liens AS SELECT a.id, a.medicament_id FROM public.alertes_stock a JOIN _cibles c ON c.id = a.medicament_id;
REVOKE ALL ON ALL TABLES IN SCHEMA sauvegarde_remplacement FROM PUBLIC, anon, authenticated;

UPDATE public.alertes_stock SET medicament_id = NULL WHERE medicament_id IN (SELECT id FROM _cibles);
DELETE FROM public.stocks WHERE medicament_id IN (SELECT id FROM _cibles);
DELETE FROM public.medicaments WHERE id IN (SELECT id FROM _cibles);

-- Rapport (à relire avant COMMIT) : attendu = 40 fiches, 0 fiche restante issue du seed.
SELECT (SELECT count(*) FROM sauvegarde_remplacement.medicaments)       AS fiches_supprimees,
       (SELECT count(*) FROM sauvegarde_remplacement.stocks)            AS stocks_supprimes,
       (SELECT count(*) FROM sauvegarde_remplacement.alertes_stock_liens) AS demandes_patient_detachees,
       (SELECT count(*) FROM public.medicaments)                        AS fiches_restantes;

ROLLBACK;   -- SIMULATION. Remplacer par COMMIT pour appliquer.

-- ── RETOUR ARRIÈRE (après un COMMIT, tant que les migrations suivantes ne sont pas appliquées) ──
-- BEGIN;
-- INSERT INTO public.medicaments SELECT * FROM sauvegarde_remplacement.medicaments;
-- INSERT INTO public.stocks SELECT * FROM sauvegarde_remplacement.stocks;
-- UPDATE public.alertes_stock a SET medicament_id = l.medicament_id FROM sauvegarde_remplacement.alertes_stock_liens l WHERE l.id = a.id;
-- COMMIT;
