-- ============================================================
-- Chargement du catalogue de démonstration (phase I2 de docs/MISE-EN-PRODUCTION.md) — À EXÉCUTER À LA MAIN dans le SQL Editor.
-- FICHIER GÉNÉRÉ par `node scripts/catalogue-demo-sql.js` depuis supabase/seed/demo_catalog.csv : ne pas le modifier à la main.
--
-- Équivalent SQL de `node scripts/demo-reset.js --catalogue supabase/seed/demo_catalog.csv` (partie catalogue), sans Node.js
-- ni clé service_role. Même lecture du fichier, mêmes règles :
--   - refusé si l'application n'est pas en mode démo ;
--   - une fiche déjà présente (même nom, dosage et conditionnement, comme l'index unique) n'est jamais dupliquée : seules
--     « ordonnance » et « restreint » sont alignées sur le fichier ;
--   - classification : AUCUNE décision ici. « restricted » vide dans le fichier → fiche restreinte (défaut sûr) ;
--     la classification réelle est faite par votre pharmacien validateur (phase I3).
-- Fichier : 237 fiches, dont 1 restreinte(s) et 236 non restreinte(s).
--
-- Mode d'emploi : lancer tel quel = SIMULATION (ROLLBACK final) ; lire le rapport ; remplacer ROLLBACK par COMMIT pour appliquer.
-- Rejouable : un second passage n'insère rien (fiches « inchangées »).
-- Ensuite : console admin → « ↺ Remettre la démo à zéro » (pharmacies de démonstration et leurs stocks).
-- ============================================================
BEGIN;

DO $$
BEGIN
    IF public.mode_application() <> 'demo' THEN
        RAISE EXCEPTION 'Chargement refusé : l''application n''est pas en mode démo. Rien n''a été modifié.';
    END IF;
END $$;

-- Clé d'identité d'une fiche : mêmes expressions que l'index unique uq_medicaments_nom_dosage.
CREATE OR REPLACE FUNCTION pg_temp.cle_fiche(p_nom text, p_dosage text, p_conditionnement text) RETURNS text
LANGUAGE sql IMMUTABLE AS $f$
    SELECT lower(btrim(p_nom)) || '|' || lower(regexp_replace(coalesce(p_dosage, ''), '\s', '', 'g'))
           || '|' || lower(regexp_replace(coalesce(p_conditionnement, ''), '\s', '', 'g'))
$f$;

CREATE TEMP TABLE _catalogue (
    ligne int PRIMARY KEY, nom text NOT NULL, nom_commercial text, dci text, forme text, dosage text, conditionnement text,
    categorie text NOT NULL, ordonnance boolean NOT NULL, restreint boolean NOT NULL
) ON COMMIT DROP;
INSERT INTO _catalogue (ligne, nom, nom_commercial, dci, forme, dosage, conditionnement, categorie, ordonnance, restreint) VALUES
    (1, 'Artéméther + Luméfantrine Brand1 capsule', 'Artéméther + Luméfantrine Brand1 capsule', 'Artéméther + Luméfantrine', 'capsule', '250 mg', NULL, 'Antipaludéens', true, false),
    (2, 'Artéméther + Luméfantrine Brand2 comprimé', 'Artéméther + Luméfantrine Brand2 comprimé', 'Artéméther + Luméfantrine', 'comprimé', '500 mg', NULL, 'Antipaludéens', true, false),
    (3, 'Artéméther + Luméfantrine Brand3 capsule', 'Artéméther + Luméfantrine Brand3 capsule', 'Artéméther + Luméfantrine', 'capsule', '750 mg', NULL, 'Antipaludéens', true, false),
    (4, 'Artéméther + Luméfantrine Brand1 comprimé', 'Artéméther + Luméfantrine Brand1 comprimé', 'Artéméther + Luméfantrine', 'comprimé', '250 mg', NULL, 'Antipaludéens', true, false),
    (5, 'Artéméther + Luméfantrine Brand2 suspension', 'Artéméther + Luméfantrine Brand2 suspension', 'Artéméther + Luméfantrine', 'suspension', '500 mg', NULL, 'Antipaludéens', true, false),
    (6, 'Artéméther + Luméfantrine Brand3 comprimé', 'Artéméther + Luméfantrine Brand3 comprimé', 'Artéméther + Luméfantrine', 'comprimé', '750 mg', NULL, 'Antipaludéens', true, false),
    (7, 'Artéméther + Luméfantrine Brand1 suspension', 'Artéméther + Luméfantrine Brand1 suspension', 'Artéméther + Luméfantrine', 'suspension', '250 mg', NULL, 'Antipaludéens', true, false),
    (8, 'Artéméther + Luméfantrine Brand2 capsule', 'Artéméther + Luméfantrine Brand2 capsule', 'Artéméther + Luméfantrine', 'capsule', '500 mg', NULL, 'Antipaludéens', true, false),
    (9, 'Artéméther + Luméfantrine Brand3 sirop', 'Artéméther + Luméfantrine Brand3 sirop', 'Artéméther + Luméfantrine', 'sirop', '750 mg', NULL, 'Antipaludéens', true, false),
    (10, 'Artéméther + Luméfantrine Brand2 sirop', 'Artéméther + Luméfantrine Brand2 sirop', 'Artéméther + Luméfantrine', 'sirop', '500 mg', NULL, 'Antipaludéens', true, false),
    (11, 'Artéméther + Luméfantrine Brand1 sirop', 'Artéméther + Luméfantrine Brand1 sirop', 'Artéméther + Luméfantrine', 'sirop', '250 mg', NULL, 'Antipaludéens', true, false),
    (12, 'Artéméther + Luméfantrine Brand3 suspension', 'Artéméther + Luméfantrine Brand3 suspension', 'Artéméther + Luméfantrine', 'suspension', '750 mg', NULL, 'Antipaludéens', true, false),
    (13, 'Paracétamol Brand1 capsule', 'Paracétamol Brand1 capsule', 'Paracétamol', 'capsule', '250 mg', NULL, 'Analgésiques', false, false),
    (14, 'Paracétamol Brand2 comprimé', 'Paracétamol Brand2 comprimé', 'Paracétamol', 'comprimé', '500 mg', NULL, 'Analgésiques', false, false),
    (15, 'Paracétamol Brand3 sirop', 'Paracétamol Brand3 sirop', 'Paracétamol', 'sirop', '750 mg', NULL, 'Analgésiques', false, false),
    (16, 'Paracétamol Brand1 sirop', 'Paracétamol Brand1 sirop', 'Paracétamol', 'sirop', '250 mg', NULL, 'Analgésiques', false, false),
    (17, 'Paracétamol Brand2 sirop', 'Paracétamol Brand2 sirop', 'Paracétamol', 'sirop', '500 mg', NULL, 'Analgésiques', false, false),
    (18, 'Paracétamol Brand3 capsule', 'Paracétamol Brand3 capsule', 'Paracétamol', 'capsule', '750 mg', NULL, 'Analgésiques', false, false),
    (19, 'Paracétamol Brand2 suspension', 'Paracétamol Brand2 suspension', 'Paracétamol', 'suspension', '500 mg', NULL, 'Analgésiques', false, false),
    (20, 'Paracétamol Brand1 comprimé', 'Paracétamol Brand1 comprimé', 'Paracétamol', 'comprimé', '250 mg', NULL, 'Analgésiques', false, false),
    (21, 'Paracétamol Brand1 suspension', 'Paracétamol Brand1 suspension', 'Paracétamol', 'suspension', '250 mg', NULL, 'Analgésiques', false, false),
    (22, 'Paracétamol Brand2 capsule', 'Paracétamol Brand2 capsule', 'Paracétamol', 'capsule', '500 mg', NULL, 'Analgésiques', false, false),
    (23, 'Paracétamol Brand3 comprimé', 'Paracétamol Brand3 comprimé', 'Paracétamol', 'comprimé', '750 mg', NULL, 'Analgésiques', false, false),
    (24, 'Paracétamol Brand3 suspension', 'Paracétamol Brand3 suspension', 'Paracétamol', 'suspension', '750 mg', NULL, 'Analgésiques', false, false),
    (25, 'Ibuprofène Brand1 sirop', 'Ibuprofène Brand1 sirop', 'Ibuprofène', 'sirop', '250 mg', NULL, 'Analgésiques', false, false),
    (26, 'Ibuprofène Brand2 sirop', 'Ibuprofène Brand2 sirop', 'Ibuprofène', 'sirop', '500 mg', NULL, 'Analgésiques', false, false),
    (27, 'Ibuprofène Brand3 sirop', 'Ibuprofène Brand3 sirop', 'Ibuprofène', 'sirop', '750 mg', NULL, 'Analgésiques', false, false),
    (28, 'Ibuprofène Brand1 comprimé', 'Ibuprofène Brand1 comprimé', 'Ibuprofène', 'comprimé', '250 mg', NULL, 'Analgésiques', false, false),
    (29, 'Ibuprofène Brand2 comprimé', 'Ibuprofène Brand2 comprimé', 'Ibuprofène', 'comprimé', '500 mg', NULL, 'Analgésiques', false, false),
    (30, 'Ibuprofène Brand3 comprimé', 'Ibuprofène Brand3 comprimé', 'Ibuprofène', 'comprimé', '750 mg', NULL, 'Analgésiques', false, false),
    (31, 'Ibuprofène Brand1 suspension', 'Ibuprofène Brand1 suspension', 'Ibuprofène', 'suspension', '250 mg', NULL, 'Analgésiques', false, false),
    (32, 'Ibuprofène Brand2 suspension', 'Ibuprofène Brand2 suspension', 'Ibuprofène', 'suspension', '500 mg', NULL, 'Analgésiques', false, false),
    (33, 'Ibuprofène Brand3 suspension', 'Ibuprofène Brand3 suspension', 'Ibuprofène', 'suspension', '750 mg', NULL, 'Analgésiques', false, false),
    (34, 'Ibuprofène Brand3 capsule', 'Ibuprofène Brand3 capsule', 'Ibuprofène', 'capsule', '750 mg', NULL, 'Analgésiques', false, false),
    (35, 'Ibuprofène Brand1 capsule', 'Ibuprofène Brand1 capsule', 'Ibuprofène', 'capsule', '250 mg', NULL, 'Analgésiques', false, false),
    (36, 'Ibuprofène Brand2 capsule', 'Ibuprofène Brand2 capsule', 'Ibuprofène', 'capsule', '500 mg', NULL, 'Analgésiques', false, false),
    (37, 'Amoxicilline Brand1 suspension', 'Amoxicilline Brand1 suspension', 'Amoxicilline', 'suspension', '250 mg', NULL, 'Antibiotiques', true, false),
    (38, 'Amoxicilline Brand2 comprimé', 'Amoxicilline Brand2 comprimé', 'Amoxicilline', 'comprimé', '500 mg', NULL, 'Antibiotiques', true, false),
    (39, 'Amoxicilline Brand3 suspension', 'Amoxicilline Brand3 suspension', 'Amoxicilline', 'suspension', '750 mg', NULL, 'Antibiotiques', true, false),
    (40, 'Amoxicilline Brand1 sirop', 'Amoxicilline Brand1 sirop', 'Amoxicilline', 'sirop', '250 mg', NULL, 'Antibiotiques', true, false),
    (41, 'Amoxicilline Brand2 sirop', 'Amoxicilline Brand2 sirop', 'Amoxicilline', 'sirop', '500 mg', NULL, 'Antibiotiques', true, false),
    (42, 'Amoxicilline Brand3 capsule', 'Amoxicilline Brand3 capsule', 'Amoxicilline', 'capsule', '750 mg', NULL, 'Antibiotiques', true, false),
    (43, 'Amoxicilline Brand2 suspension', 'Amoxicilline Brand2 suspension', 'Amoxicilline', 'suspension', '500 mg', NULL, 'Antibiotiques', true, false),
    (44, 'Amoxicilline Brand3 sirop', 'Amoxicilline Brand3 sirop', 'Amoxicilline', 'sirop', '750 mg', NULL, 'Antibiotiques', true, false),
    (45, 'Amoxicilline Brand1 comprimé', 'Amoxicilline Brand1 comprimé', 'Amoxicilline', 'comprimé', '250 mg', NULL, 'Antibiotiques', true, false),
    (46, 'Amoxicilline Brand1 capsule', 'Amoxicilline Brand1 capsule', 'Amoxicilline', 'capsule', '250 mg', NULL, 'Antibiotiques', true, false),
    (47, 'Amoxicilline Brand2 capsule', 'Amoxicilline Brand2 capsule', 'Amoxicilline', 'capsule', '500 mg', NULL, 'Antibiotiques', true, false),
    (48, 'Amoxicilline Brand3 comprimé', 'Amoxicilline Brand3 comprimé', 'Amoxicilline', 'comprimé', '750 mg', NULL, 'Antibiotiques', true, false),
    (49, 'Fer + Acide Folique Brand1 capsule', 'Fer + Acide Folique Brand1 capsule', 'Fer + Acide Folique', 'capsule', '250 mg', NULL, 'Anti-anémiques', false, false),
    (50, 'Fer + Acide Folique Brand2 comprimé', 'Fer + Acide Folique Brand2 comprimé', 'Fer + Acide Folique', 'comprimé', '500 mg', NULL, 'Anti-anémiques', false, false),
    (51, 'Fer + Acide Folique Brand3 suspension', 'Fer + Acide Folique Brand3 suspension', 'Fer + Acide Folique', 'suspension', '750 mg', NULL, 'Anti-anémiques', false, false),
    (52, 'Fer + Acide Folique Brand1 comprimé', 'Fer + Acide Folique Brand1 comprimé', 'Fer + Acide Folique', 'comprimé', '250 mg', NULL, 'Anti-anémiques', false, false),
    (53, 'Fer + Acide Folique Brand2 suspension', 'Fer + Acide Folique Brand2 suspension', 'Fer + Acide Folique', 'suspension', '500 mg', NULL, 'Anti-anémiques', false, false),
    (54, 'Fer + Acide Folique Brand3 sirop', 'Fer + Acide Folique Brand3 sirop', 'Fer + Acide Folique', 'sirop', '750 mg', NULL, 'Anti-anémiques', false, false),
    (55, 'Fer + Acide Folique Brand1 suspension', 'Fer + Acide Folique Brand1 suspension', 'Fer + Acide Folique', 'suspension', '250 mg', NULL, 'Anti-anémiques', false, false),
    (56, 'Fer + Acide Folique Brand3 capsule', 'Fer + Acide Folique Brand3 capsule', 'Fer + Acide Folique', 'capsule', '750 mg', NULL, 'Anti-anémiques', false, false),
    (57, 'Fer + Acide Folique Brand3 comprimé', 'Fer + Acide Folique Brand3 comprimé', 'Fer + Acide Folique', 'comprimé', '750 mg', NULL, 'Anti-anémiques', false, false),
    (58, 'Fer + Acide Folique Brand1 sirop', 'Fer + Acide Folique Brand1 sirop', 'Fer + Acide Folique', 'sirop', '250 mg', NULL, 'Anti-anémiques', false, false),
    (59, 'Fer + Acide Folique Brand2 capsule', 'Fer + Acide Folique Brand2 capsule', 'Fer + Acide Folique', 'capsule', '500 mg', NULL, 'Anti-anémiques', false, false),
    (60, 'Fer + Acide Folique Brand2 sirop', 'Fer + Acide Folique Brand2 sirop', 'Fer + Acide Folique', 'sirop', '500 mg', NULL, 'Anti-anémiques', false, false),
    (61, 'Artésunate + Amodiaquine Brand1 sirop', 'Artésunate + Amodiaquine Brand1 sirop', 'Artésunate + Amodiaquine', 'sirop', '250 mg', NULL, 'Antipaludéens', true, false),
    (62, 'Artésunate + Amodiaquine Brand2 comprimé', 'Artésunate + Amodiaquine Brand2 comprimé', 'Artésunate + Amodiaquine', 'comprimé', '500 mg', NULL, 'Antipaludéens', true, false),
    (63, 'Artésunate + Amodiaquine Brand3 suspension', 'Artésunate + Amodiaquine Brand3 suspension', 'Artésunate + Amodiaquine', 'suspension', '750 mg', NULL, 'Antipaludéens', true, false),
    (64, 'Artésunate + Amodiaquine Brand1 suspension', 'Artésunate + Amodiaquine Brand1 suspension', 'Artésunate + Amodiaquine', 'suspension', '250 mg', NULL, 'Antipaludéens', true, false),
    (65, 'Artésunate + Amodiaquine Brand3 sirop', 'Artésunate + Amodiaquine Brand3 sirop', 'Artésunate + Amodiaquine', 'sirop', '750 mg', NULL, 'Antipaludéens', true, false),
    (66, 'Artésunate + Amodiaquine Brand2 capsule', 'Artésunate + Amodiaquine Brand2 capsule', 'Artésunate + Amodiaquine', 'capsule', '500 mg', NULL, 'Antipaludéens', true, false),
    (67, 'Artésunate + Amodiaquine Brand3 capsule', 'Artésunate + Amodiaquine Brand3 capsule', 'Artésunate + Amodiaquine', 'capsule', '750 mg', NULL, 'Antipaludéens', true, false),
    (68, 'Artésunate + Amodiaquine Brand1 capsule', 'Artésunate + Amodiaquine Brand1 capsule', 'Artésunate + Amodiaquine', 'capsule', '250 mg', NULL, 'Antipaludéens', true, false),
    (69, 'Artésunate + Amodiaquine Brand1 comprimé', 'Artésunate + Amodiaquine Brand1 comprimé', 'Artésunate + Amodiaquine', 'comprimé', '250 mg', NULL, 'Antipaludéens', true, false),
    (70, 'Artésunate + Amodiaquine Brand3 comprimé', 'Artésunate + Amodiaquine Brand3 comprimé', 'Artésunate + Amodiaquine', 'comprimé', '750 mg', NULL, 'Antipaludéens', true, false),
    (71, 'Artésunate + Amodiaquine Brand2 sirop', 'Artésunate + Amodiaquine Brand2 sirop', 'Artésunate + Amodiaquine', 'sirop', '500 mg', NULL, 'Antipaludéens', true, false),
    (72, 'Artésunate + Amodiaquine Brand2 suspension', 'Artésunate + Amodiaquine Brand2 suspension', 'Artésunate + Amodiaquine', 'suspension', '500 mg', NULL, 'Antipaludéens', true, false),
    (73, 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand1 suspension', 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand1 suspension', 'Augmentin (Amoxicilline + Ac. Clavulanique)', 'suspension', '250 mg', NULL, 'Antibiotiques', true, false),
    (74, 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand2 suspension', 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand2 suspension', 'Augmentin (Amoxicilline + Ac. Clavulanique)', 'suspension', '500 mg', NULL, 'Antibiotiques', true, false),
    (75, 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand3 sirop', 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand3 sirop', 'Augmentin (Amoxicilline + Ac. Clavulanique)', 'sirop', '750 mg', NULL, 'Antibiotiques', true, false),
    (76, 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand2 capsule', 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand2 capsule', 'Augmentin (Amoxicilline + Ac. Clavulanique)', 'capsule', '500 mg', NULL, 'Antibiotiques', true, false),
    (77, 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand1 capsule', 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand1 capsule', 'Augmentin (Amoxicilline + Ac. Clavulanique)', 'capsule', '250 mg', NULL, 'Antibiotiques', true, false),
    (78, 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand3 comprimé', 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand3 comprimé', 'Augmentin (Amoxicilline + Ac. Clavulanique)', 'comprimé', '750 mg', NULL, 'Antibiotiques', true, false),
    (79, 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand1 sirop', 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand1 sirop', 'Augmentin (Amoxicilline + Ac. Clavulanique)', 'sirop', '250 mg', NULL, 'Antibiotiques', true, false),
    (80, 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand2 sirop', 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand2 sirop', 'Augmentin (Amoxicilline + Ac. Clavulanique)', 'sirop', '500 mg', NULL, 'Antibiotiques', true, false),
    (81, 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand3 suspension', 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand3 suspension', 'Augmentin (Amoxicilline + Ac. Clavulanique)', 'suspension', '750 mg', NULL, 'Antibiotiques', true, false),
    (82, 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand1 comprimé', 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand1 comprimé', 'Augmentin (Amoxicilline + Ac. Clavulanique)', 'comprimé', '250 mg', NULL, 'Antibiotiques', true, false),
    (83, 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand3 capsule', 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand3 capsule', 'Augmentin (Amoxicilline + Ac. Clavulanique)', 'capsule', '750 mg', NULL, 'Antibiotiques', true, false),
    (84, 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand2 comprimé', 'Augmentin (Amoxicilline + Ac. Clavulanique) Brand2 comprimé', 'Augmentin (Amoxicilline + Ac. Clavulanique)', 'comprimé', '500 mg', NULL, 'Antibiotiques', true, false),
    (85, 'Azithromycine Brand1 suspension', 'Azithromycine Brand1 suspension', 'Azithromycine', 'suspension', '250 mg', NULL, 'Antibiotiques', true, false),
    (86, 'Azithromycine Brand2 comprimé', 'Azithromycine Brand2 comprimé', 'Azithromycine', 'comprimé', '500 mg', NULL, 'Antibiotiques', true, false),
    (87, 'Azithromycine Brand3 sirop', 'Azithromycine Brand3 sirop', 'Azithromycine', 'sirop', '750 mg', NULL, 'Antibiotiques', true, false),
    (88, 'Azithromycine Brand1 comprimé', 'Azithromycine Brand1 comprimé', 'Azithromycine', 'comprimé', '250 mg', NULL, 'Antibiotiques', true, false),
    (89, 'Azithromycine Brand2 suspension', 'Azithromycine Brand2 suspension', 'Azithromycine', 'suspension', '500 mg', NULL, 'Antibiotiques', true, false),
    (90, 'Azithromycine Brand3 suspension', 'Azithromycine Brand3 suspension', 'Azithromycine', 'suspension', '750 mg', NULL, 'Antibiotiques', true, false),
    (91, 'Azithromycine Brand2 capsule', 'Azithromycine Brand2 capsule', 'Azithromycine', 'capsule', '500 mg', NULL, 'Antibiotiques', true, false),
    (92, 'Azithromycine Brand3 comprimé', 'Azithromycine Brand3 comprimé', 'Azithromycine', 'comprimé', '750 mg', NULL, 'Antibiotiques', true, false),
    (93, 'Azithromycine Brand1 capsule', 'Azithromycine Brand1 capsule', 'Azithromycine', 'capsule', '250 mg', NULL, 'Antibiotiques', true, false),
    (94, 'Azithromycine Brand2 sirop', 'Azithromycine Brand2 sirop', 'Azithromycine', 'sirop', '500 mg', NULL, 'Antibiotiques', true, false),
    (95, 'Azithromycine Brand3 capsule', 'Azithromycine Brand3 capsule', 'Azithromycine', 'capsule', '750 mg', NULL, 'Antibiotiques', true, false),
    (96, 'Azithromycine Brand1 sirop', 'Azithromycine Brand1 sirop', 'Azithromycine', 'sirop', '250 mg', NULL, 'Antibiotiques', true, false),
    (97, 'Captopril Brand1 comprimé', 'Captopril Brand1 comprimé', 'Captopril', 'comprimé', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (98, 'Captopril Brand2 suspension', 'Captopril Brand2 suspension', 'Captopril', 'suspension', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (99, 'Captopril Brand3 suspension', 'Captopril Brand3 suspension', 'Captopril', 'suspension', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (100, 'Captopril Brand1 capsule', 'Captopril Brand1 capsule', 'Captopril', 'capsule', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (101, 'Captopril Brand2 capsule', 'Captopril Brand2 capsule', 'Captopril', 'capsule', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (102, 'Captopril Brand3 capsule', 'Captopril Brand3 capsule', 'Captopril', 'capsule', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (103, 'Captopril Brand1 suspension', 'Captopril Brand1 suspension', 'Captopril', 'suspension', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (104, 'Captopril Brand2 sirop', 'Captopril Brand2 sirop', 'Captopril', 'sirop', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (105, 'Captopril Brand3 comprimé', 'Captopril Brand3 comprimé', 'Captopril', 'comprimé', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (106, 'Captopril Brand2 comprimé', 'Captopril Brand2 comprimé', 'Captopril', 'comprimé', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (107, 'Captopril Brand3 sirop', 'Captopril Brand3 sirop', 'Captopril', 'sirop', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (108, 'Captopril Brand1 sirop', 'Captopril Brand1 sirop', 'Captopril', 'sirop', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (109, 'Nifédipine Brand1 capsule', 'Nifédipine Brand1 capsule', 'Nifédipine', 'capsule', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (110, 'Nifédipine Brand2 sirop', 'Nifédipine Brand2 sirop', 'Nifédipine', 'sirop', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (111, 'Nifédipine Brand3 sirop', 'Nifédipine Brand3 sirop', 'Nifédipine', 'sirop', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (112, 'Nifédipine Brand1 sirop', 'Nifédipine Brand1 sirop', 'Nifédipine', 'sirop', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (113, 'Nifédipine Brand1 suspension', 'Nifédipine Brand1 suspension', 'Nifédipine', 'suspension', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (114, 'Nifédipine Brand2 suspension', 'Nifédipine Brand2 suspension', 'Nifédipine', 'suspension', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (115, 'Nifédipine Brand3 suspension', 'Nifédipine Brand3 suspension', 'Nifédipine', 'suspension', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (116, 'Nifédipine Brand3 comprimé', 'Nifédipine Brand3 comprimé', 'Nifédipine', 'comprimé', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (117, 'Nifédipine Brand3 capsule', 'Nifédipine Brand3 capsule', 'Nifédipine', 'capsule', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (118, 'Nifédipine Brand1 comprimé', 'Nifédipine Brand1 comprimé', 'Nifédipine', 'comprimé', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (119, 'Nifédipine Brand2 comprimé', 'Nifédipine Brand2 comprimé', 'Nifédipine', 'comprimé', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (120, 'Amlodipine Brand1 sirop', 'Amlodipine Brand1 sirop', 'Amlodipine', 'sirop', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (121, 'Amlodipine Brand2 capsule', 'Amlodipine Brand2 capsule', 'Amlodipine', 'capsule', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (122, 'Amlodipine Brand3 comprimé', 'Amlodipine Brand3 comprimé', 'Amlodipine', 'comprimé', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (123, 'Amlodipine Brand1 comprimé', 'Amlodipine Brand1 comprimé', 'Amlodipine', 'comprimé', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (124, 'Amlodipine Brand2 suspension', 'Amlodipine Brand2 suspension', 'Amlodipine', 'suspension', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (125, 'Amlodipine Brand1 capsule', 'Amlodipine Brand1 capsule', 'Amlodipine', 'capsule', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (126, 'Amlodipine Brand1 suspension', 'Amlodipine Brand1 suspension', 'Amlodipine', 'suspension', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (127, 'Amlodipine Brand2 sirop', 'Amlodipine Brand2 sirop', 'Amlodipine', 'sirop', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (128, 'Amlodipine Brand3 suspension', 'Amlodipine Brand3 suspension', 'Amlodipine', 'suspension', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (129, 'Amlodipine Brand3 capsule', 'Amlodipine Brand3 capsule', 'Amlodipine', 'capsule', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (130, 'Amlodipine Brand3 sirop', 'Amlodipine Brand3 sirop', 'Amlodipine', 'sirop', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (131, 'Amlodipine Brand2 comprimé', 'Amlodipine Brand2 comprimé', 'Amlodipine', 'comprimé', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (132, 'Hydrochlorothiazide Brand1 capsule', 'Hydrochlorothiazide Brand1 capsule', 'Hydrochlorothiazide', 'capsule', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (133, 'Hydrochlorothiazide Brand2 sirop', 'Hydrochlorothiazide Brand2 sirop', 'Hydrochlorothiazide', 'sirop', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (134, 'Hydrochlorothiazide Brand3 suspension', 'Hydrochlorothiazide Brand3 suspension', 'Hydrochlorothiazide', 'suspension', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (135, 'Hydrochlorothiazide Brand1 suspension', 'Hydrochlorothiazide Brand1 suspension', 'Hydrochlorothiazide', 'suspension', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (136, 'Hydrochlorothiazide Brand2 suspension', 'Hydrochlorothiazide Brand2 suspension', 'Hydrochlorothiazide', 'suspension', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (137, 'Hydrochlorothiazide Brand3 capsule', 'Hydrochlorothiazide Brand3 capsule', 'Hydrochlorothiazide', 'capsule', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (138, 'Hydrochlorothiazide Brand2 capsule', 'Hydrochlorothiazide Brand2 capsule', 'Hydrochlorothiazide', 'capsule', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (139, 'Hydrochlorothiazide Brand1 sirop', 'Hydrochlorothiazide Brand1 sirop', 'Hydrochlorothiazide', 'sirop', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (140, 'Hydrochlorothiazide Brand3 sirop', 'Hydrochlorothiazide Brand3 sirop', 'Hydrochlorothiazide', 'sirop', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (141, 'Hydrochlorothiazide Brand3 comprimé', 'Hydrochlorothiazide Brand3 comprimé', 'Hydrochlorothiazide', 'comprimé', '750 mg', NULL, 'Cardiovasculaire', true, false),
    (142, 'Hydrochlorothiazide Brand1 comprimé', 'Hydrochlorothiazide Brand1 comprimé', 'Hydrochlorothiazide', 'comprimé', '250 mg', NULL, 'Cardiovasculaire', true, false),
    (143, 'Hydrochlorothiazide Brand2 comprimé', 'Hydrochlorothiazide Brand2 comprimé', 'Hydrochlorothiazide', 'comprimé', '500 mg', NULL, 'Cardiovasculaire', true, false),
    (144, 'Metformine Brand1 comprimé', 'Metformine Brand1 comprimé', 'Metformine', 'comprimé', '250 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (145, 'Metformine Brand2 suspension', 'Metformine Brand2 suspension', 'Metformine', 'suspension', '500 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (146, 'Metformine Brand3 comprimé', 'Metformine Brand3 comprimé', 'Metformine', 'comprimé', '750 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (147, 'Metformine Brand1 sirop', 'Metformine Brand1 sirop', 'Metformine', 'sirop', '250 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (148, 'Metformine Brand2 sirop', 'Metformine Brand2 sirop', 'Metformine', 'sirop', '500 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (149, 'Metformine Brand3 suspension', 'Metformine Brand3 suspension', 'Metformine', 'suspension', '750 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (150, 'Metformine Brand1 capsule', 'Metformine Brand1 capsule', 'Metformine', 'capsule', '250 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (151, 'Metformine Brand1 suspension', 'Metformine Brand1 suspension', 'Metformine', 'suspension', '250 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (152, 'Metformine Brand2 comprimé', 'Metformine Brand2 comprimé', 'Metformine', 'comprimé', '500 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (153, 'Metformine Brand3 capsule', 'Metformine Brand3 capsule', 'Metformine', 'capsule', '750 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (154, 'Metformine Brand2 capsule', 'Metformine Brand2 capsule', 'Metformine', 'capsule', '500 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (155, 'Metformine Brand3 sirop', 'Metformine Brand3 sirop', 'Metformine', 'sirop', '750 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (156, 'Glibenclamide Brand1 suspension', 'Glibenclamide Brand1 suspension', 'Glibenclamide', 'suspension', '250 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (157, 'Glibenclamide Brand2 sirop', 'Glibenclamide Brand2 sirop', 'Glibenclamide', 'sirop', '500 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (158, 'Glibenclamide Brand3 capsule', 'Glibenclamide Brand3 capsule', 'Glibenclamide', 'capsule', '750 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (159, 'Glibenclamide Brand1 comprimé', 'Glibenclamide Brand1 comprimé', 'Glibenclamide', 'comprimé', '250 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (160, 'Glibenclamide Brand2 comprimé', 'Glibenclamide Brand2 comprimé', 'Glibenclamide', 'comprimé', '500 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (161, 'Glibenclamide Brand3 comprimé', 'Glibenclamide Brand3 comprimé', 'Glibenclamide', 'comprimé', '750 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (162, 'Glibenclamide Brand1 sirop', 'Glibenclamide Brand1 sirop', 'Glibenclamide', 'sirop', '250 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (163, 'Glibenclamide Brand2 suspension', 'Glibenclamide Brand2 suspension', 'Glibenclamide', 'suspension', '500 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (164, 'Glibenclamide Brand1 capsule', 'Glibenclamide Brand1 capsule', 'Glibenclamide', 'capsule', '250 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (165, 'Glibenclamide Brand2 capsule', 'Glibenclamide Brand2 capsule', 'Glibenclamide', 'capsule', '500 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (166, 'Glibenclamide Brand3 sirop', 'Glibenclamide Brand3 sirop', 'Glibenclamide', 'sirop', '750 mg', NULL, 'Métabolisme (Diabète)', true, false),
    (167, 'Oméprazole Brand1 suspension', 'Oméprazole Brand1 suspension', 'Oméprazole', 'suspension', '250 mg', NULL, 'Gastro-entérologie', true, false),
    (168, 'Oméprazole Brand2 capsule', 'Oméprazole Brand2 capsule', 'Oméprazole', 'capsule', '500 mg', NULL, 'Gastro-entérologie', true, false),
    (169, 'Oméprazole Brand3 sirop', 'Oméprazole Brand3 sirop', 'Oméprazole', 'sirop', '750 mg', NULL, 'Gastro-entérologie', true, false),
    (170, 'Oméprazole Brand2 comprimé', 'Oméprazole Brand2 comprimé', 'Oméprazole', 'comprimé', '500 mg', NULL, 'Gastro-entérologie', true, false),
    (171, 'Oméprazole Brand1 comprimé', 'Oméprazole Brand1 comprimé', 'Oméprazole', 'comprimé', '250 mg', NULL, 'Gastro-entérologie', true, false),
    (172, 'Oméprazole Brand2 sirop', 'Oméprazole Brand2 sirop', 'Oméprazole', 'sirop', '500 mg', NULL, 'Gastro-entérologie', true, false),
    (173, 'Oméprazole Brand3 comprimé', 'Oméprazole Brand3 comprimé', 'Oméprazole', 'comprimé', '750 mg', NULL, 'Gastro-entérologie', true, false),
    (174, 'Oméprazole Brand1 capsule', 'Oméprazole Brand1 capsule', 'Oméprazole', 'capsule', '250 mg', NULL, 'Gastro-entérologie', true, false),
    (175, 'Oméprazole Brand3 suspension', 'Oméprazole Brand3 suspension', 'Oméprazole', 'suspension', '750 mg', NULL, 'Gastro-entérologie', true, false),
    (176, 'Oméprazole Brand2 suspension', 'Oméprazole Brand2 suspension', 'Oméprazole', 'suspension', '500 mg', NULL, 'Gastro-entérologie', true, false),
    (177, 'Oméprazole Brand3 capsule', 'Oméprazole Brand3 capsule', 'Oméprazole', 'capsule', '750 mg', NULL, 'Gastro-entérologie', true, false),
    (178, 'Oméprazole Brand1 sirop', 'Oméprazole Brand1 sirop', 'Oméprazole', 'sirop', '250 mg', NULL, 'Gastro-entérologie', true, false),
    (179, 'SRO (Sels de Réhydratation Orale) Brand1 sirop', 'SRO (Sels de Réhydratation Orale) Brand1 sirop', 'SRO (Sels de Réhydratation Orale)', 'sirop', '250 mg', NULL, 'Réhydratation', false, false),
    (180, 'SRO (Sels de Réhydratation Orale) Brand2 suspension', 'SRO (Sels de Réhydratation Orale) Brand2 suspension', 'SRO (Sels de Réhydratation Orale)', 'suspension', '500 mg', NULL, 'Réhydratation', false, false),
    (181, 'SRO (Sels de Réhydratation Orale) Brand3 capsule', 'SRO (Sels de Réhydratation Orale) Brand3 capsule', 'SRO (Sels de Réhydratation Orale)', 'capsule', '750 mg', NULL, 'Réhydratation', false, false),
    (182, 'SRO (Sels de Réhydratation Orale) Brand1 comprimé', 'SRO (Sels de Réhydratation Orale) Brand1 comprimé', 'SRO (Sels de Réhydratation Orale)', 'comprimé', '250 mg', NULL, 'Réhydratation', false, false),
    (183, 'SRO (Sels de Réhydratation Orale) Brand3 comprimé', 'SRO (Sels de Réhydratation Orale) Brand3 comprimé', 'SRO (Sels de Réhydratation Orale)', 'comprimé', '750 mg', NULL, 'Réhydratation', false, false),
    (184, 'SRO (Sels de Réhydratation Orale) Brand2 sirop', 'SRO (Sels de Réhydratation Orale) Brand2 sirop', 'SRO (Sels de Réhydratation Orale)', 'sirop', '500 mg', NULL, 'Réhydratation', false, false),
    (185, 'SRO (Sels de Réhydratation Orale) Brand3 sirop', 'SRO (Sels de Réhydratation Orale) Brand3 sirop', 'SRO (Sels de Réhydratation Orale)', 'sirop', '750 mg', NULL, 'Réhydratation', false, false),
    (186, 'SRO (Sels de Réhydratation Orale) Brand1 capsule', 'SRO (Sels de Réhydratation Orale) Brand1 capsule', 'SRO (Sels de Réhydratation Orale)', 'capsule', '250 mg', NULL, 'Réhydratation', false, false),
    (187, 'SRO (Sels de Réhydratation Orale) Brand2 capsule', 'SRO (Sels de Réhydratation Orale) Brand2 capsule', 'SRO (Sels de Réhydratation Orale)', 'capsule', '500 mg', NULL, 'Réhydratation', false, false),
    (188, 'SRO (Sels de Réhydratation Orale) Brand1 suspension', 'SRO (Sels de Réhydratation Orale) Brand1 suspension', 'SRO (Sels de Réhydratation Orale)', 'suspension', '250 mg', NULL, 'Réhydratation', false, false),
    (189, 'SRO (Sels de Réhydratation Orale) Brand2 comprimé', 'SRO (Sels de Réhydratation Orale) Brand2 comprimé', 'SRO (Sels de Réhydratation Orale)', 'comprimé', '500 mg', NULL, 'Réhydratation', false, false),
    (190, 'Zinc (Sulfate de zinc) Brand1 comprimé', 'Zinc (Sulfate de zinc) Brand1 comprimé', 'Zinc (Sulfate de zinc)', 'comprimé', '250 mg', NULL, 'Suppléments', false, false),
    (191, 'Zinc (Sulfate de zinc) Brand2 capsule', 'Zinc (Sulfate de zinc) Brand2 capsule', 'Zinc (Sulfate de zinc)', 'capsule', '500 mg', NULL, 'Suppléments', false, false),
    (192, 'Zinc (Sulfate de zinc) Brand3 suspension', 'Zinc (Sulfate de zinc) Brand3 suspension', 'Zinc (Sulfate de zinc)', 'suspension', '750 mg', NULL, 'Suppléments', false, false),
    (193, 'Zinc (Sulfate de zinc) Brand1 capsule', 'Zinc (Sulfate de zinc) Brand1 capsule', 'Zinc (Sulfate de zinc)', 'capsule', '250 mg', NULL, 'Suppléments', false, false),
    (194, 'Zinc (Sulfate de zinc) Brand3 comprimé', 'Zinc (Sulfate de zinc) Brand3 comprimé', 'Zinc (Sulfate de zinc)', 'comprimé', '750 mg', NULL, 'Suppléments', false, false),
    (195, 'Zinc (Sulfate de zinc) Brand2 sirop', 'Zinc (Sulfate de zinc) Brand2 sirop', 'Zinc (Sulfate de zinc)', 'sirop', '500 mg', NULL, 'Suppléments', false, false),
    (196, 'Zinc (Sulfate de zinc) Brand3 sirop', 'Zinc (Sulfate de zinc) Brand3 sirop', 'Zinc (Sulfate de zinc)', 'sirop', '750 mg', NULL, 'Suppléments', false, false),
    (197, 'Zinc (Sulfate de zinc) Brand2 suspension', 'Zinc (Sulfate de zinc) Brand2 suspension', 'Zinc (Sulfate de zinc)', 'suspension', '500 mg', NULL, 'Suppléments', false, false),
    (198, 'Zinc (Sulfate de zinc) Brand3 capsule', 'Zinc (Sulfate de zinc) Brand3 capsule', 'Zinc (Sulfate de zinc)', 'capsule', '750 mg', NULL, 'Suppléments', false, false),
    (199, 'Zinc (Sulfate de zinc) Brand1 suspension', 'Zinc (Sulfate de zinc) Brand1 suspension', 'Zinc (Sulfate de zinc)', 'suspension', '250 mg', NULL, 'Suppléments', false, false),
    (200, 'Zinc (Sulfate de zinc) Brand1 sirop', 'Zinc (Sulfate de zinc) Brand1 sirop', 'Zinc (Sulfate de zinc)', 'sirop', '250 mg', NULL, 'Suppléments', false, false),
    (201, 'Zinc (Sulfate de zinc) Brand2 comprimé', 'Zinc (Sulfate de zinc) Brand2 comprimé', 'Zinc (Sulfate de zinc)', 'comprimé', '500 mg', NULL, 'Suppléments', false, false),
    (202, 'Cotrimoxazole (SMX/TMP) Brand1 sirop', 'Cotrimoxazole (SMX/TMP) Brand1 sirop', 'Cotrimoxazole (SMX/TMP)', 'sirop', '250 mg', NULL, 'Antibiotiques', true, false),
    (203, 'Cotrimoxazole (SMX/TMP) Brand2 comprimé', 'Cotrimoxazole (SMX/TMP) Brand2 comprimé', 'Cotrimoxazole (SMX/TMP)', 'comprimé', '500 mg', NULL, 'Antibiotiques', true, false),
    (204, 'Cotrimoxazole (SMX/TMP) Brand3 comprimé', 'Cotrimoxazole (SMX/TMP) Brand3 comprimé', 'Cotrimoxazole (SMX/TMP)', 'comprimé', '750 mg', NULL, 'Antibiotiques', true, false),
    (205, 'Cotrimoxazole (SMX/TMP) Brand1 suspension', 'Cotrimoxazole (SMX/TMP) Brand1 suspension', 'Cotrimoxazole (SMX/TMP)', 'suspension', '250 mg', NULL, 'Antibiotiques', true, false),
    (206, 'Cotrimoxazole (SMX/TMP) Brand3 sirop', 'Cotrimoxazole (SMX/TMP) Brand3 sirop', 'Cotrimoxazole (SMX/TMP)', 'sirop', '750 mg', NULL, 'Antibiotiques', true, false),
    (207, 'Cotrimoxazole (SMX/TMP) Brand1 capsule', 'Cotrimoxazole (SMX/TMP) Brand1 capsule', 'Cotrimoxazole (SMX/TMP)', 'capsule', '250 mg', NULL, 'Antibiotiques', true, false),
    (208, 'Cotrimoxazole (SMX/TMP) Brand2 capsule', 'Cotrimoxazole (SMX/TMP) Brand2 capsule', 'Cotrimoxazole (SMX/TMP)', 'capsule', '500 mg', NULL, 'Antibiotiques', true, false),
    (209, 'Cotrimoxazole (SMX/TMP) Brand1 comprimé', 'Cotrimoxazole (SMX/TMP) Brand1 comprimé', 'Cotrimoxazole (SMX/TMP)', 'comprimé', '250 mg', NULL, 'Antibiotiques', true, false),
    (210, 'Cotrimoxazole (SMX/TMP) Brand3 capsule', 'Cotrimoxazole (SMX/TMP) Brand3 capsule', 'Cotrimoxazole (SMX/TMP)', 'capsule', '750 mg', NULL, 'Antibiotiques', true, false),
    (211, 'Cotrimoxazole (SMX/TMP) Brand2 suspension', 'Cotrimoxazole (SMX/TMP) Brand2 suspension', 'Cotrimoxazole (SMX/TMP)', 'suspension', '500 mg', NULL, 'Antibiotiques', true, false),
    (212, 'Cotrimoxazole (SMX/TMP) Brand3 suspension', 'Cotrimoxazole (SMX/TMP) Brand3 suspension', 'Cotrimoxazole (SMX/TMP)', 'suspension', '750 mg', NULL, 'Antibiotiques', true, false),
    (213, 'Cotrimoxazole (SMX/TMP) Brand2 sirop', 'Cotrimoxazole (SMX/TMP) Brand2 sirop', 'Cotrimoxazole (SMX/TMP)', 'sirop', '500 mg', NULL, 'Antibiotiques', true, false),
    (214, 'Doxycycline Brand1 sirop', 'Doxycycline Brand1 sirop', 'Doxycycline', 'sirop', '250 mg', NULL, 'Antibiotiques', true, false),
    (215, 'Doxycycline Brand2 comprimé', 'Doxycycline Brand2 comprimé', 'Doxycycline', 'comprimé', '500 mg', NULL, 'Antibiotiques', true, false),
    (216, 'Doxycycline Brand3 comprimé', 'Doxycycline Brand3 comprimé', 'Doxycycline', 'comprimé', '750 mg', NULL, 'Antibiotiques', true, false),
    (217, 'Doxycycline Brand1 suspension', 'Doxycycline Brand1 suspension', 'Doxycycline', 'suspension', '250 mg', NULL, 'Antibiotiques', true, false),
    (218, 'Doxycycline Brand3 capsule', 'Doxycycline Brand3 capsule', 'Doxycycline', 'capsule', '750 mg', NULL, 'Antibiotiques', true, false),
    (219, 'Doxycycline Brand2 capsule', 'Doxycycline Brand2 capsule', 'Doxycycline', 'capsule', '500 mg', NULL, 'Antibiotiques', true, false),
    (220, 'Doxycycline Brand3 sirop', 'Doxycycline Brand3 sirop', 'Doxycycline', 'sirop', '750 mg', NULL, 'Antibiotiques', true, false),
    (221, 'Doxycycline Brand1 comprimé', 'Doxycycline Brand1 comprimé', 'Doxycycline', 'comprimé', '250 mg', NULL, 'Antibiotiques', true, false),
    (222, 'Doxycycline Brand3 suspension', 'Doxycycline Brand3 suspension', 'Doxycycline', 'suspension', '750 mg', NULL, 'Antibiotiques', true, false),
    (223, 'Doxycycline Brand2 suspension', 'Doxycycline Brand2 suspension', 'Doxycycline', 'suspension', '500 mg', NULL, 'Antibiotiques', true, false),
    (224, 'Doxycycline Brand2 sirop', 'Doxycycline Brand2 sirop', 'Doxycycline', 'sirop', '500 mg', NULL, 'Antibiotiques', true, false),
    (225, 'Doxycycline Brand1 capsule', 'Doxycycline Brand1 capsule', 'Doxycycline', 'capsule', '250 mg', NULL, 'Antibiotiques', true, false),
    (226, 'Quinine Brand1 sirop', 'Quinine Brand1 sirop', 'Quinine', 'sirop', '250 mg', NULL, 'Antipaludéens', true, false),
    (227, 'Quinine Brand2 suspension', 'Quinine Brand2 suspension', 'Quinine', 'suspension', '500 mg', NULL, 'Antipaludéens', true, false),
    (228, 'Quinine Brand3 comprimé', 'Quinine Brand3 comprimé', 'Quinine', 'comprimé', '750 mg', NULL, 'Antipaludéens', true, false),
    (229, 'Quinine Brand3 sirop', 'Quinine Brand3 sirop', 'Quinine', 'sirop', '750 mg', NULL, 'Antipaludéens', true, false),
    (230, 'Quinine Brand1 suspension', 'Quinine Brand1 suspension', 'Quinine', 'suspension', '250 mg', NULL, 'Antipaludéens', true, false),
    (231, 'Quinine Brand2 capsule', 'Quinine Brand2 capsule', 'Quinine', 'capsule', '500 mg', NULL, 'Antipaludéens', true, false),
    (232, 'Quinine Brand3 capsule', 'Quinine Brand3 capsule', 'Quinine', 'capsule', '750 mg', NULL, 'Antipaludéens', true, false),
    (233, 'Quinine Brand2 comprimé', 'Quinine Brand2 comprimé', 'Quinine', 'comprimé', '500 mg', NULL, 'Antipaludéens', true, false),
    (234, 'Quinine Brand1 comprimé', 'Quinine Brand1 comprimé', 'Quinine', 'comprimé', '250 mg', NULL, 'Antipaludéens', true, false),
    (235, 'Quinine Brand2 sirop', 'Quinine Brand2 sirop', 'Quinine', 'sirop', '500 mg', NULL, 'Antipaludéens', true, false),
    (236, 'Quinine Brand1 capsule', 'Quinine Brand1 capsule', 'Quinine', 'capsule', '250 mg', NULL, 'Antipaludéens', true, false),
    (237, 'Exemple restreint (démo)', 'Exemple restreint (démo)', NULL, 'fictif', NULL, NULL, 'démonstration', false, true);

CREATE TEMP TABLE _bilan (etape text PRIMARY KEY, n int NOT NULL) ON COMMIT DROP;

-- 1. Fiches déjà présentes SANS conditionnement, alors que le fichier en indique un pour le même nom et dosage :
--    la fiche adopte le conditionnement (pas de doublon), une seule fois par fiche.
WITH candidats AS (
    SELECT DISTINCT ON (c.ligne) c.ligne, m.id
    FROM _catalogue c
    JOIN public.medicaments m ON pg_temp.cle_fiche(m.nom, m.dosage, NULL) = pg_temp.cle_fiche(c.nom, c.dosage, NULL)
                             AND coalesce(btrim(m.conditionnement), '') = ''
    WHERE c.conditionnement IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM public.medicaments e
                      WHERE pg_temp.cle_fiche(e.nom, e.dosage, e.conditionnement) = pg_temp.cle_fiche(c.nom, c.dosage, c.conditionnement))
    ORDER BY c.ligne, m.id
), adoptions AS (
    SELECT DISTINCT ON (id) ligne, id FROM candidats ORDER BY id, ligne
), maj AS (
    UPDATE public.medicaments m SET conditionnement = c.conditionnement
    FROM adoptions a JOIN _catalogue c ON c.ligne = a.ligne
    WHERE m.id = a.id
    RETURNING m.id
)
INSERT INTO _bilan SELECT 'conditionnements_renseignes', count(*) FROM maj;

-- 2. Fiches présentes : seules « ordonnance » et « restreint » sont alignées sur le fichier.
INSERT INTO _bilan
SELECT 'presentes', count(*) FROM _catalogue c
WHERE EXISTS (SELECT 1 FROM public.medicaments m
              WHERE pg_temp.cle_fiche(m.nom, m.dosage, m.conditionnement) = pg_temp.cle_fiche(c.nom, c.dosage, c.conditionnement));

WITH maj AS (
    UPDATE public.medicaments m SET ordonnance = c.ordonnance, restreint = c.restreint, est_demo = true
    FROM _catalogue c
    WHERE pg_temp.cle_fiche(m.nom, m.dosage, m.conditionnement) = pg_temp.cle_fiche(c.nom, c.dosage, c.conditionnement)
      AND (m.ordonnance, m.restreint) IS DISTINCT FROM (c.ordonnance, c.restreint)
    RETURNING m.id
)
INSERT INTO _bilan SELECT 'mises_a_jour', count(*) FROM maj;

-- 3. Fiches absentes : insertion.
WITH ins AS (
    INSERT INTO public.medicaments (nom, nom_commercial, dci, forme, dosage, conditionnement, categorie, ordonnance, restreint, est_demo)
    SELECT c.nom, c.nom_commercial, c.dci, c.forme, c.dosage, c.conditionnement, c.categorie, c.ordonnance, c.restreint, true
    FROM _catalogue c
    WHERE NOT EXISTS (SELECT 1 FROM public.medicaments m
                      WHERE pg_temp.cle_fiche(m.nom, m.dosage, m.conditionnement) = pg_temp.cle_fiche(c.nom, c.dosage, c.conditionnement))
    ORDER BY c.ligne
    RETURNING id
)
INSERT INTO _bilan SELECT 'inserees', count(*) FROM ins;

-- Rapport (à relire avant COMMIT). Premier passage attendu : inserees = fiches_fichier, inchangees = 0 ;
-- passage suivant : inserees = 0, inchangees = fiches_fichier.
SELECT (SELECT count(*) FROM _catalogue)                                                   AS fiches_fichier,
       (SELECT n FROM _bilan WHERE etape = 'inserees')                                     AS inserees,
       (SELECT n FROM _bilan WHERE etape = 'mises_a_jour')                                 AS mises_a_jour,
       (SELECT p.n - u.n FROM _bilan p, _bilan u WHERE p.etape = 'presentes' AND u.etape = 'mises_a_jour') AS inchangees,
       (SELECT n FROM _bilan WHERE etape = 'conditionnements_renseignes')                  AS conditionnements_renseignes,
       (SELECT count(*) FROM _catalogue WHERE restreint)                                   AS restreintes,
       (SELECT count(*) FROM _catalogue WHERE NOT restreint)                               AS non_restreintes,
       (SELECT count(*) FROM public.medicaments WHERE est_demo)                            AS fiches_demo_en_base;

ROLLBACK;   -- SIMULATION. Remplacer par COMMIT pour appliquer.
