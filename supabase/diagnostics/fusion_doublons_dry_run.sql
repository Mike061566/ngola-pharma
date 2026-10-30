-- ============================================================
-- N'Gola Pharma — DRY RUN de la fusion des fiches `medicaments` en double (LECTURE SEULE)
--
-- À exécuter dans le SQL Editor Supabase (production). Ne modifie RIEN : transaction en lecture
-- seule + ROLLBACK. Un seul résultat, une ligne par groupe / conflit, trié par section.
--
-- Pour chaque groupe de fiches équivalentes (même DCI + nom commercial + dosage + forme), la future
-- migration de fusion fera :
--   1. fiche GARDÉE   : par défaut celle qui porte le plus de lignes de stock, puis la plus ancienne,
--                       puis l'id le plus petit. Surchargeable ci-dessous (override).
--   2. fiches SUPPRIMÉES : toutes les autres du groupe.
--   3. stocks DÉPLACÉS   : une pharmacie qui n'a une ligne que sur une fiche supprimée voit cette
--                       ligne rattachée à la fiche gardée.
--   4. CONFLITS résolus  : une pharmacie qui a des lignes sur plusieurs fiches du groupe n'en garde
--                       qu'UNE, sur la fiche gardée : la plus récente (date_maj), à égalité celle
--                       « en stock », puis celle de la fiche gardée. Les autres sont supprimées.
--   5. alertes_stock.medicament_id qui pointent vers une fiche supprimée sont rattachées à la gardée.
--
-- Sections du résultat : RESUME (par groupe), CONFLIT (par pharmacie en conflit), A_EXAMINER
-- (fiches proches NON fusionnées : à trancher à la main), COLLISION_INDEX (doit être VIDE : sinon l'index
-- unique de la migration échouerait), TOTAL.
-- ============================================================
BEGIN READ ONLY;

WITH
-- Forcer la fiche gardée d'un groupe : remplacer la ligne ci-dessous par
--   override(id) AS (VALUES ('<id fiche gardée Coartem>'::uuid), ('<id fiche gardée Chloroquine>'::uuid))
override(id) AS (VALUES (NULL::uuid)),

fiches AS (
    SELECT m.id, m.nom, m.nom_commercial, m.dci, m.dosage, m.forme, m.created_at,
           concat_ws('|',
               lower(btrim(coalesce(m.dci, ''))),
               lower(btrim(coalesce(m.nom_commercial, ''))),
               lower(regexp_replace(coalesce(m.dosage, ''), '\s', '', 'g')),
               lower(btrim(coalesce(m.forme, ''))),
               -- sans DCI ni marque, le nom départage (même règle que l'Espace Pro)
               CASE WHEN btrim(coalesce(m.dci, '')) = '' AND btrim(coalesce(m.nom_commercial, '')) = ''
                    THEN lower(btrim(m.nom)) END) AS cle
    FROM medicaments m
),
doublons AS (
    SELECT f.*, (SELECT count(*) FROM stocks s WHERE s.medicament_id = f.id) AS nb_stocks
    FROM fiches f
    WHERE f.cle IN (SELECT cle FROM fiches GROUP BY cle HAVING count(*) > 1)
),
rang AS (
    SELECT d.*,
           row_number() OVER (
               PARTITION BY d.cle
               ORDER BY (d.id IN (SELECT id FROM override WHERE id IS NOT NULL)) DESC,
                        d.nb_stocks DESC, d.created_at ASC, d.id ASC) AS rn
    FROM doublons d
),
gardee AS (SELECT cle, id AS gardee_id, nom AS gardee_nom, dosage AS gardee_dosage,
                  coalesce(nullif(btrim(nom_commercial), ''), nom) AS gardee_produit FROM rang WHERE rn = 1),

lignes AS (
    SELECT g.cle, s.pharmacie_id, s.id AS stock_id, (s.medicament_id = g.gardee_id) AS est_gardee,
           s.prix_fcfa, s.en_stock, s.date_maj
    FROM gardee g
    JOIN rang r ON r.cle = g.cle
    JOIN stocks s ON s.medicament_id = r.id
),
par_pharmacie AS (
    SELECT l.cle, l.pharmacie_id,
           count(*) AS n_lignes,
           bool_or(l.est_gardee) AS a_ligne_gardee,
           (array_agg(l.est_gardee ORDER BY l.date_maj DESC, l.en_stock DESC, l.est_gardee DESC, l.stock_id))[1] AS gagnante_est_gardee,
           string_agg(
               (CASE WHEN l.est_gardee THEN '[gardée] ' ELSE '[supprimée] ' END) ||
               l.prix_fcfa || ' FCFA, ' || (CASE WHEN l.en_stock THEN 'en stock' ELSE 'rupture' END) ||
               ', maj ' || to_char(l.date_maj, 'YYYY-MM-DD HH24:MI'),
               '  >>  ' ORDER BY l.date_maj DESC, l.en_stock DESC, l.est_gardee DESC, l.stock_id) AS detail,
           (array_agg(l.prix_fcfa || ' FCFA, ' || (CASE WHEN l.en_stock THEN 'en stock' ELSE 'rupture' END)
                      ORDER BY l.date_maj DESC, l.en_stock DESC, l.est_gardee DESC, l.stock_id))[1] AS valeur_retenue
    FROM lignes l
    GROUP BY l.cle, l.pharmacie_id
),
resume AS (
    SELECT g.cle, g.gardee_id, g.gardee_nom, g.gardee_dosage, g.gardee_produit,
           (SELECT string_agg(r.id || ' (' || r.nom || ')', ' ; ' ORDER BY r.created_at, r.id)
              FROM rang r WHERE r.cle = g.cle AND r.rn > 1) AS supprimees,
           (SELECT count(*) FROM rang r WHERE r.cle = g.cle AND r.rn > 1) AS nb_supprimees,
           coalesce((SELECT count(*) FILTER (WHERE NOT pp.a_ligne_gardee) FROM par_pharmacie pp WHERE pp.cle = g.cle), 0) AS deplaces,
           coalesce((SELECT count(*) FILTER (WHERE pp.n_lignes > 1) FROM par_pharmacie pp WHERE pp.cle = g.cle), 0) AS conflits,
           coalesce((SELECT count(*) FILTER (WHERE pp.a_ligne_gardee AND NOT pp.gagnante_est_gardee) FROM par_pharmacie pp WHERE pp.cle = g.cle), 0) AS gardee_remplacee,
           coalesce((SELECT sum(pp.n_lignes - 1) FROM par_pharmacie pp WHERE pp.cle = g.cle), 0) AS lignes_supprimees,
           (SELECT count(*) FROM alertes_stock a JOIN rang r ON r.id = a.medicament_id WHERE r.cle = g.cle AND r.rn > 1) AS alertes
    FROM gardee g
)
SELECT section, produit, fiche_gardee, fiches_supprimees, stocks_deplaces, conflits_resolus, detail
FROM (
    SELECT 1 AS ordre, 'RESUME' AS section,
           r.gardee_produit || ' ' || coalesce(r.gardee_dosage, '') AS produit,
           r.gardee_id || ' (' || r.gardee_nom || ')' AS fiche_gardee,
           r.supprimees AS fiches_supprimees,
           r.deplaces::int AS stocks_deplaces,
           r.conflits::int AS conflits_resolus,
           r.lignes_supprimees || ' ligne(s) de stock supprimée(s) ; ' ||
           r.gardee_remplacee || ' fois la valeur de la fiche gardée est remplacée par celle d''une fiche supprimée ; ' ||
           r.alertes || ' alerte(s) rattachée(s) à la fiche gardée' AS detail
    FROM resume r

    UNION ALL
    SELECT 2, 'CONFLIT',
           r.gardee_produit || ' ' || coalesce(r.gardee_dosage, ''),
           NULL, NULL, NULL, NULL,
           ph.nom || ' — retenu : ' || pp.valeur_retenue || CASE WHEN pp.gagnante_est_gardee THEN ' (ligne de la fiche gardée)' ELSE ' (ligne d''une fiche supprimée)' END ||
           '  ||  ' || pp.detail
    FROM par_pharmacie pp
    JOIN resume r ON r.cle = pp.cle
    JOIN pharmacies ph ON ph.id = pp.pharmacie_id
    WHERE pp.n_lignes > 1

    UNION ALL
    -- Fiches proches mais NON fusionnées : même DCI + marque + dosage, formes différentes
    SELECT 3, 'A_EXAMINER',
           lower(btrim(coalesce(f.dci, ''))) || ' / ' || lower(btrim(coalesce(f.nom_commercial, ''))) || ' / ' || coalesce(f.dosage, ''),
           NULL, string_agg(f.id || ' (' || f.nom || ', forme ' || coalesce(f.forme, '?') || ')', ' ; ' ORDER BY f.created_at),
           NULL, NULL, 'formes différentes : fusionner seulement si c''est le même produit'
    FROM fiches f
    WHERE btrim(coalesce(f.dci, '')) <> ''
    GROUP BY lower(btrim(coalesce(f.dci, ''))), lower(btrim(coalesce(f.nom_commercial, ''))), coalesce(f.dosage, '')
    HAVING count(DISTINCT lower(btrim(coalesce(f.forme, '')))) > 1

    UNION ALL
    -- Après fusion, l'index unique (nom + dosage normalisés) doit pouvoir être créé : toute ligne ici ferait ÉCHOUER la migration
    SELECT 3, 'COLLISION_INDEX',
           lower(btrim(f.nom)) || ' / ' || lower(regexp_replace(coalesce(f.dosage, ''), '\s', '', 'g')),
           NULL, string_agg(f.id || ' (' || f.nom || ')', ' ; ' ORDER BY f.created_at),
           NULL, NULL, 'même nom + dosage après fusion : corriger ou fusionner à la main AVANT la migration'
    FROM fiches f
    WHERE f.id NOT IN (SELECT id FROM rang WHERE rn > 1)
    GROUP BY lower(btrim(f.nom)), lower(regexp_replace(coalesce(f.dosage, ''), '\s', '', 'g'))
    HAVING count(*) > 1

    UNION ALL
    SELECT 4, 'TOTAL', count(*) || ' groupe(s) de doublons', NULL, NULL,
           coalesce(sum(r.deplaces), 0)::int, coalesce(sum(r.conflits), 0)::int,
           coalesce(sum(r.nb_supprimees), 0) || ' fiche(s) supprimée(s) ; ' ||
           coalesce(sum(r.lignes_supprimees), 0) || ' ligne(s) de stock supprimée(s) ; ' ||
           coalesce(sum(r.alertes), 0) || ' alerte(s) rattachée(s) ; catalogue : ' ||
           (SELECT count(*) FROM medicaments) || ' -> ' ||
           ((SELECT count(*) FROM medicaments) - coalesce(sum(r.nb_supprimees), 0)) || ' fiches'
    FROM resume r
) t
ORDER BY ordre, produit, fiche_gardee;

ROLLBACK;
