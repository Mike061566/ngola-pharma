-- ============================================================
-- N'Gola Pharma — RETOUR ARRIÈRE de la fusion 20261003100000 (fusion_doublons_medicaments)
--
-- Restaure, depuis le schéma `sauvegarde_fusion` créé par la migration : les fiches supprimées, les lignes de
-- stock supprimées / déplacées / remplacées, et les anciens medicament_id des alertes. Retire l'index unique
-- uq_medicaments_nom_dosage (il n'existait pas avant la fusion).
--
-- ATTENTION : ce script remet les lignes de stock concernées dans leur état d'AVANT la fusion. Toute modification
-- faite sur ces lignes après la fusion (prix, stock) est perdue. À utiliser rapidement ou jamais.
-- La sauvegarde n'est PAS supprimée (voir la fin du fichier pour la purge, à faire à la main plus tard).
-- UNE seule transaction : un contrôle final qui échoue annule tout le retour arrière.
-- ============================================================
BEGIN;

LOCK TABLE public.medicaments, public.stocks, public.alertes_stock IN SHARE ROW EXCLUSIVE MODE;

DO $$
DECLARE
    presente boolean := false;
BEGIN
    IF to_regclass('sauvegarde_fusion.medicaments_supprimes') IS NOT NULL THEN
        EXECUTE 'SELECT EXISTS (SELECT 1 FROM sauvegarde_fusion.medicaments_supprimes)' INTO presente;
    END IF;
    IF NOT presente THEN
        RAISE EXCEPTION 'Rien à annuler : la sauvegarde sauvegarde_fusion est absente ou vide.';
    END IF;
END $$;

-- 1. l'index unique doit disparaître avant de restaurer les fiches
DROP INDEX IF EXISTS public.uq_medicaments_nom_dosage;

-- 2. fiches supprimées
INSERT INTO public.medicaments
    (id, nom, nom_commercial, dci, forme, dosage, categorie, ordonnance, description, image_url, created_at, updated_at)
SELECT id, nom, nom_commercial, dci, forme, dosage, categorie, ordonnance, description, image_url, created_at, updated_at
FROM sauvegarde_fusion.medicaments_supprimes;

-- 3. stocks : lignes supprimées, déplacées, remplacées
INSERT INTO public.stocks (id, pharmacie_id, medicament_id, prix_fcfa, en_stock, date_maj, source, created_at)
SELECT id, pharmacie_id, medicament_id, prix_fcfa, en_stock, date_maj, source, created_at
FROM sauvegarde_fusion.stocks_avant WHERE action = 'supprime';

UPDATE public.stocks s SET medicament_id = b.medicament_id
FROM sauvegarde_fusion.stocks_avant b
WHERE b.action = 'deplace' AND s.id = b.id;

UPDATE public.stocks s
SET prix_fcfa = b.prix_fcfa, en_stock = b.en_stock, date_maj = b.date_maj, source = b.source
FROM sauvegarde_fusion.stocks_avant b
WHERE b.action = 'mis_a_jour' AND s.id = b.id;

-- 4. alertes : anciens medicament_id
UPDATE public.alertes_stock a SET medicament_id = b.medicament_id_avant
FROM sauvegarde_fusion.alertes_avant b
WHERE a.id = b.id;

-- 5. contrôle : l'état restauré correspond exactement à la sauvegarde, sinon tout est annulé
DO $$
DECLARE
    n bigint;
    rec record;
BEGIN
    SELECT count(*) INTO n FROM sauvegarde_fusion.medicaments_supprimes b
    WHERE NOT EXISTS (SELECT 1 FROM public.medicaments m WHERE m.id = b.id AND m.nom = b.nom);
    IF n > 0 THEN RAISE EXCEPTION 'Contrôle : % fiche(s) non restaurée(s)', n; END IF;

    SELECT count(*) INTO n FROM sauvegarde_fusion.stocks_avant b
    WHERE NOT EXISTS (SELECT 1 FROM public.stocks s
                      WHERE s.id = b.id AND s.pharmacie_id = b.pharmacie_id AND s.medicament_id = b.medicament_id
                        AND s.prix_fcfa = b.prix_fcfa AND s.en_stock = b.en_stock AND s.date_maj = b.date_maj
                        AND s.source = b.source);
    IF n > 0 THEN RAISE EXCEPTION 'Contrôle : % ligne(s) de stock non restaurée(s) à l''identique', n; END IF;

    SELECT count(*) INTO n FROM sauvegarde_fusion.alertes_avant b
    WHERE NOT EXISTS (SELECT 1 FROM public.alertes_stock a WHERE a.id = b.id AND a.medicament_id = b.medicament_id_avant);
    IF n > 0 THEN RAISE EXCEPTION 'Contrôle : % alerte(s) non remise(s) sur leur ancienne fiche', n; END IF;

    FOR rec IN
        SELECT c.conrelid::regclass AS tbl, a.attname AS col
        FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
        WHERE c.contype = 'f' AND c.confrelid = 'public.medicaments'::regclass
    LOOP
        EXECUTE format('SELECT count(*) FROM %s t WHERE t.%I IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.medicaments m WHERE m.id = t.%I)',
                       rec.tbl, rec.col, rec.col) INTO n;
        IF n > 0 THEN RAISE EXCEPTION 'Contrôle : % ligne(s) orpheline(s) dans %.%', n, rec.tbl, rec.col; END IF;
    END LOOP;
END $$;

COMMIT;

-- Bilan
SELECT 'fiches restaurées' AS mesure, count(*)::text AS valeur FROM sauvegarde_fusion.medicaments_supprimes
UNION ALL SELECT 'fiches au total', count(*)::text FROM public.medicaments;

-- Purge de la sauvegarde (À LA MAIN, plus tard, une fois le retour arrière ou la fusion définitivement validés).
-- Nécessaire avant de relancer la fusion (la migration refuse de s'exécuter si la sauvegarde n'est pas vide) :
--   DROP SCHEMA sauvegarde_fusion CASCADE;
