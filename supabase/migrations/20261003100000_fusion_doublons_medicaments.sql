-- ============================================================
-- N'Gola Pharma — Fusion des fiches `medicaments` en double + unicité
-- Migration 20261003100000. PRODUCTION : à exécuter À LA MAIN, après relecture, APRÈS un dry run
-- (supabase/diagnostics/fusion_doublons_dry_run.sql) dont le résultat est validé.
--
-- Règles (validées sur le dry run de production) :
--   * Groupe de doublons : même DCI + nom commercial + dosage (sans espaces) + forme, en minuscules.
--   * Fiche GARDÉE : celle qui porte le plus de lignes de stock, puis la plus ancienne, puis l'id le plus petit.
--   * Stock : une pharmacie n'a plus qu'UNE ligne par groupe, sur la fiche gardée.
--       - ligne la plus récente (date_maj) gagnante ; à égalité, celle « en stock » ;
--       - pharmacie sans ligne sur la fiche gardée : la ligne gagnante est DÉPLACÉE sur la fiche gardée ;
--       - pharmacie avec ligne sur la fiche gardée : la ligne gardée prend les valeurs de la gagnante.
--   * alertes_stock.medicament_id des fiches supprimées -> rattachés à la fiche gardée.
--   * Autres clés étrangères vers medicaments : aucune connue (recherches n'en a pas). Si une autre existe,
--     la migration ÉCHOUE avant toute modification.
--
-- Sauvegarde : schéma `sauvegarde_fusion` (hors API) = anciennes fiches, anciennes lignes de stock, anciens
-- medicament_id des alertes. Retour arrière : supabase/rollback/20261003100000_fusion_doublons_medicaments_rollback.sql
--
-- Tout est dans UNE transaction : un contrôle final (aucun doublon restant, aucune clé étrangère orpheline,
-- comptes cohérents) lève une exception qui annule TOUT. Rien n'est supprimé sans sauvegarde préalable.
-- ============================================================
BEGIN;

-- Écritures bloquées (lecture autorisée) pendant la fusion : l'Espace Pro ne peut pas modifier un stock en cours de route.
LOCK TABLE public.medicaments, public.stocks, public.alertes_stock IN SHARE ROW EXCLUSIVE MODE;

-- ── 0. Garde-fous ─────────────────────────────────────────────────────
DO $$
DECLARE
    autres text;
    deja boolean := false;
BEGIN
    -- SQL dynamique : la table n'existe pas encore à la première exécution.
    IF to_regclass('sauvegarde_fusion.medicaments_supprimes') IS NOT NULL THEN
        EXECUTE 'SELECT EXISTS (SELECT 1 FROM sauvegarde_fusion.medicaments_supprimes)' INTO deja;
    END IF;
    IF deja THEN
        RAISE EXCEPTION 'Fusion déjà exécutée : la sauvegarde sauvegarde_fusion n''est pas vide. Annuler avec le script de retour arrière, puis purger la sauvegarde, avant de relancer.';
    END IF;

    SELECT string_agg(c.conrelid::regclass || '.' || c.conname, ', ') INTO autres
    FROM pg_constraint c
    WHERE c.contype = 'f' AND c.confrelid = 'public.medicaments'::regclass
      AND c.conrelid NOT IN ('public.stocks'::regclass, 'public.alertes_stock'::regclass);
    IF autres IS NOT NULL THEN
        RAISE EXCEPTION 'Clé(s) étrangère(s) vers medicaments non gérée(s) par cette migration : %. Aucune modification faite.', autres;
    END IF;
END $$;

-- ── 1. Sauvegarde (schéma non exposé par l'API) ───────────────────────
CREATE SCHEMA IF NOT EXISTS sauvegarde_fusion;
REVOKE ALL ON SCHEMA sauvegarde_fusion FROM PUBLIC;

CREATE TABLE IF NOT EXISTS sauvegarde_fusion.medicaments_supprimes (
    LIKE public.medicaments,
    gardee_id uuid NOT NULL,
    cle text NOT NULL,
    fusion_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id)
);
CREATE TABLE IF NOT EXISTS sauvegarde_fusion.stocks_avant (
    LIKE public.stocks,
    action text NOT NULL CHECK (action IN ('deplace', 'supprime', 'mis_a_jour')),
    gardee_id uuid NOT NULL,
    cle text NOT NULL,
    fusion_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id)
);
CREATE TABLE IF NOT EXISTS sauvegarde_fusion.alertes_avant (
    id uuid PRIMARY KEY,
    medicament_id_avant uuid NOT NULL,
    gardee_id uuid NOT NULL,
    fusion_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE sauvegarde_fusion.medicaments_supprimes ENABLE ROW LEVEL SECURITY;
ALTER TABLE sauvegarde_fusion.stocks_avant ENABLE ROW LEVEL SECURITY;
ALTER TABLE sauvegarde_fusion.alertes_avant ENABLE ROW LEVEL SECURITY;

-- ── 2. Plan (tables temporaires, supprimées au COMMIT) ────────────────
CREATE TEMP TABLE _avant ON COMMIT DROP AS
SELECT (SELECT count(*) FROM public.medicaments) AS fiches,
       (SELECT count(*) FROM public.stocks) AS stocks,
       (SELECT count(*) FROM public.alertes_stock) AS alertes;

CREATE TEMP TABLE _plan_fiches ON COMMIT DROP AS
WITH fiches AS (
    SELECT m.id, m.created_at,
           concat_ws('|',
               lower(btrim(coalesce(m.dci, ''))),
               lower(btrim(coalesce(m.nom_commercial, ''))),
               lower(regexp_replace(coalesce(m.dosage, ''), '\s', '', 'g')),
               lower(btrim(coalesce(m.forme, ''))),
               CASE WHEN btrim(coalesce(m.dci, '')) = '' AND btrim(coalesce(m.nom_commercial, '')) = ''
                    THEN lower(btrim(m.nom)) END) AS cle
    FROM public.medicaments m
),
doublons AS (
    SELECT f.*, (SELECT count(*) FROM public.stocks s WHERE s.medicament_id = f.id) AS nb_stocks
    FROM fiches f
    WHERE f.cle IN (SELECT cle FROM fiches GROUP BY cle HAVING count(*) > 1)
),
rang AS (
    SELECT d.*, row_number() OVER (PARTITION BY d.cle ORDER BY d.nb_stocks DESC, d.created_at ASC, d.id ASC) AS rn
    FROM doublons d
)
SELECT r.id, r.cle, r.rn, (r.rn = 1) AS gardee,
       first_value(r.id) OVER (PARTITION BY r.cle ORDER BY r.rn) AS gardee_id
FROM rang r;

CREATE TEMP TABLE _plan_stocks ON COMMIT DROP AS
WITH base AS (
    SELECT s.id, s.pharmacie_id, p.cle, p.gardee_id, (s.medicament_id = p.gardee_id) AS est_gardee,
           row_number() OVER (PARTITION BY s.pharmacie_id, p.cle
                              ORDER BY s.date_maj DESC, s.en_stock DESC, (s.medicament_id = p.gardee_id) DESC, s.id ASC) AS rang
    FROM public.stocks s
    JOIN _plan_fiches p ON p.id = s.medicament_id
),
agg AS (
    SELECT b.*,
           (array_agg(b.id) FILTER (WHERE b.est_gardee) OVER (PARTITION BY b.pharmacie_id, b.cle))[1] AS id_ligne_gardee,
           (array_agg(b.id) FILTER (WHERE b.rang = 1)   OVER (PARTITION BY b.pharmacie_id, b.cle))[1] AS id_gagnante
    FROM base b
),
surv AS (
    SELECT a.*, coalesce(a.id_ligne_gardee, a.id_gagnante) AS id_survivante FROM agg a
)
SELECT v.id, v.pharmacie_id, v.cle, v.gardee_id, v.id_gagnante, v.id_survivante,
       CASE WHEN v.id = v.id_survivante
            THEN CASE WHEN v.id = v.id_gagnante
                      THEN CASE WHEN v.est_gardee THEN 'conserve' ELSE 'deplace' END
                      ELSE 'mis_a_jour' END
            ELSE 'supprime' END AS action
FROM surv v;

-- ── 3. Sauvegardes AVANT toute modification ───────────────────────────
INSERT INTO sauvegarde_fusion.stocks_avant
    (id, pharmacie_id, medicament_id, prix_fcfa, en_stock, date_maj, source, created_at, action, gardee_id, cle)
SELECT s.id, s.pharmacie_id, s.medicament_id, s.prix_fcfa, s.en_stock, s.date_maj, s.source, s.created_at,
       p.action, p.gardee_id, p.cle
FROM _plan_stocks p JOIN public.stocks s ON s.id = p.id
WHERE p.action <> 'conserve';

INSERT INTO sauvegarde_fusion.alertes_avant (id, medicament_id_avant, gardee_id)
SELECT a.id, a.medicament_id, p.gardee_id
FROM public.alertes_stock a JOIN _plan_fiches p ON p.id = a.medicament_id
WHERE NOT p.gardee;

INSERT INTO sauvegarde_fusion.medicaments_supprimes
    (id, nom, nom_commercial, dci, forme, dosage, categorie, ordonnance, description, image_url,
     created_at, updated_at, gardee_id, cle)
SELECT m.id, m.nom, m.nom_commercial, m.dci, m.forme, m.dosage, m.categorie, m.ordonnance, m.description,
       m.image_url, m.created_at, m.updated_at, p.gardee_id, p.cle
FROM public.medicaments m JOIN _plan_fiches p ON p.id = m.id
WHERE NOT p.gardee;

-- ── 4. Fusion ─────────────────────────────────────────────────────────
-- 4a. la ligne gardée prend les valeurs de la ligne gagnante (qui est sur une fiche supprimée)
UPDATE public.stocks k
SET prix_fcfa = w.prix_fcfa, en_stock = w.en_stock, date_maj = w.date_maj, source = w.source
FROM _plan_stocks pk
JOIN public.stocks w ON w.id = pk.id_gagnante
WHERE pk.action = 'mis_a_jour' AND k.id = pk.id;

-- 4b. lignes perdantes supprimées
DELETE FROM public.stocks WHERE id IN (SELECT id FROM _plan_stocks WHERE action = 'supprime');

-- 4c. lignes gagnantes sans ligne sur la fiche gardée : déplacées
UPDATE public.stocks s
SET medicament_id = p.gardee_id
FROM _plan_stocks p
WHERE p.action = 'deplace' AND s.id = p.id;

-- 4d. alertes rattachées à la fiche gardée
UPDATE public.alertes_stock a
SET medicament_id = p.gardee_id
FROM _plan_fiches p
WHERE p.id = a.medicament_id AND NOT p.gardee;

-- 4e. suppression des fiches en double (plus aucune référence à ce stade)
DO $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM public.stocks s JOIN _plan_fiches p ON p.id = s.medicament_id WHERE NOT p.gardee;
    IF n > 0 THEN RAISE EXCEPTION 'Contrôle : % ligne(s) de stock référencent encore une fiche à supprimer', n; END IF;
    SELECT count(*) INTO n FROM public.alertes_stock a JOIN _plan_fiches p ON p.id = a.medicament_id WHERE NOT p.gardee;
    IF n > 0 THEN RAISE EXCEPTION 'Contrôle : % alerte(s) référencent encore une fiche à supprimer', n; END IF;
END $$;

DELETE FROM public.medicaments WHERE id IN (SELECT id FROM _plan_fiches WHERE NOT gardee);

-- ── 5. Unicité : nom normalisé + dosage normalisé ─────────────────────
DO $$
DECLARE
    conflits text;
BEGIN
    SELECT string_agg(k, ' ; ') INTO conflits
    FROM (SELECT lower(btrim(nom)) || ' / ' || lower(regexp_replace(coalesce(dosage, ''), '\s', '', 'g')) AS k
          FROM public.medicaments
          GROUP BY 1 HAVING count(*) > 1) x;
    IF conflits IS NOT NULL THEN
        RAISE EXCEPTION 'Index unique impossible : fiches distinctes de même nom et dosage normalisés : %. Aucune modification conservée.', conflits;
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_medicaments_nom_dosage
    ON public.medicaments (lower(btrim(nom)), lower(regexp_replace(coalesce(dosage, ''), '\s', '', 'g')));

-- ── 6. Contrôle final : toute anomalie annule TOUTE la transaction ────
DO $$
DECLARE
    n bigint;
    attendu bigint;
    rec record;
BEGIN
    -- 6a. plus aucun groupe de doublons
    SELECT count(*) INTO n FROM (
        SELECT concat_ws('|',
                   lower(btrim(coalesce(m.dci, ''))), lower(btrim(coalesce(m.nom_commercial, ''))),
                   lower(regexp_replace(coalesce(m.dosage, ''), '\s', '', 'g')), lower(btrim(coalesce(m.forme, ''))),
                   CASE WHEN btrim(coalesce(m.dci, '')) = '' AND btrim(coalesce(m.nom_commercial, '')) = ''
                        THEN lower(btrim(m.nom)) END) AS cle
        FROM public.medicaments m GROUP BY 1 HAVING count(*) > 1) x;
    IF n > 0 THEN RAISE EXCEPTION 'Contrôle final : % groupe(s) de doublons restant(s)', n; END IF;

    -- 6b. aucune clé étrangère orpheline (toutes les clés étrangères vers medicaments)
    FOR rec IN
        SELECT c.conrelid::regclass AS tbl, a.attname AS col
        FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
        WHERE c.contype = 'f' AND c.confrelid = 'public.medicaments'::regclass
    LOOP
        EXECUTE format('SELECT count(*) FROM %s t WHERE t.%I IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.medicaments m WHERE m.id = t.%I)',
                       rec.tbl, rec.col, rec.col) INTO n;
        IF n > 0 THEN RAISE EXCEPTION 'Contrôle final : % ligne(s) orpheline(s) dans %.%', n, rec.tbl, rec.col; END IF;
    END LOOP;

    -- 6c. comptes cohérents avec la sauvegarde
    SELECT fiches - (SELECT count(*) FROM sauvegarde_fusion.medicaments_supprimes) INTO attendu FROM _avant;
    SELECT count(*) INTO n FROM public.medicaments;
    IF n <> attendu THEN RAISE EXCEPTION 'Contrôle final : % fiches au lieu de % attendues', n, attendu; END IF;

    SELECT stocks - (SELECT count(*) FROM sauvegarde_fusion.stocks_avant WHERE action = 'supprime') INTO attendu FROM _avant;
    SELECT count(*) INTO n FROM public.stocks;
    IF n <> attendu THEN RAISE EXCEPTION 'Contrôle final : % lignes de stock au lieu de % attendues', n, attendu; END IF;

    SELECT alertes INTO attendu FROM _avant;
    SELECT count(*) INTO n FROM public.alertes_stock;
    IF n <> attendu THEN RAISE EXCEPTION 'Contrôle final : % alertes au lieu de % (aucune alerte ne doit disparaître)', n, attendu; END IF;

    -- 6d. l'index d'unicité existe
    IF to_regclass('public.uq_medicaments_nom_dosage') IS NULL THEN
        RAISE EXCEPTION 'Contrôle final : index uq_medicaments_nom_dosage absent';
    END IF;
END $$;

COMMIT;

-- Bilan (après COMMIT) : ce que la fusion a fait, d'après la sauvegarde.
SELECT 'fiches supprimées' AS mesure, count(*)::text AS valeur FROM sauvegarde_fusion.medicaments_supprimes
UNION ALL SELECT 'stocks déplacés', count(*)::text FROM sauvegarde_fusion.stocks_avant WHERE action = 'deplace'
UNION ALL SELECT 'stocks supprimés (conflits)', count(*)::text FROM sauvegarde_fusion.stocks_avant WHERE action = 'supprime'
UNION ALL SELECT 'valeurs de stock remplacées', count(*)::text FROM sauvegarde_fusion.stocks_avant WHERE action = 'mis_a_jour'
UNION ALL SELECT 'alertes rattachées', count(*)::text FROM sauvegarde_fusion.alertes_avant
UNION ALL SELECT 'fiches restantes', count(*)::text FROM public.medicaments;
