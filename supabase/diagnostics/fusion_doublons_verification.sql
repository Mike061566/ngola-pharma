-- ============================================================
-- N'Gola Pharma — VÉRIFICATION après la fusion des fiches medicaments (LECTURE SEULE)
-- À exécuter dans le SQL Editor APRÈS la migration 20261003100000. Un seul résultat : une ligne par contrôle,
-- colonne `ok` = true/false. Tout doit être true.
--
-- Paramètres à adapter en tête : nombre de fiches attendu, préfixe de l'id de la pharmacie (il doit en
-- identifier UNE seule : donnez-en assez pour cela), prix attendus.
-- ============================================================
BEGIN READ ONLY;

WITH params AS (
    SELECT 20 AS fiches_attendues,
           '76beb7c3-' AS prefixe_pharmacie,
           5100 AS coartem_prix, true AS coartem_en_stock,
           1500 AS chloroquine_prix, true AS chloroquine_en_stock
),
ma AS (SELECT p.id, p.nom FROM pharmacies p, params WHERE p.id::text LIKE params.prefixe_pharmacie || '%'),
cle AS (
    SELECT concat_ws('|', lower(btrim(coalesce(m.dci, ''))), lower(btrim(coalesce(m.nom_commercial, ''))),
                     lower(regexp_replace(coalesce(m.dosage, ''), '\s', '', 'g')), lower(btrim(coalesce(m.forme, ''))),
                     CASE WHEN btrim(coalesce(m.dci, '')) = '' AND btrim(coalesce(m.nom_commercial, '')) = ''
                          THEN lower(btrim(m.nom)) END) AS k
    FROM medicaments m
),
coartem AS (
    SELECT s.prix_fcfa, s.en_stock FROM stocks s JOIN ma ON ma.id = s.pharmacie_id
    JOIN medicaments m ON m.id = s.medicament_id WHERE m.dci ILIKE 'artemether%'
),
chloroquine AS (
    SELECT s.prix_fcfa, s.en_stock FROM stocks s JOIN ma ON ma.id = s.pharmacie_id
    JOIN medicaments m ON m.id = s.medicament_id
    WHERE m.dci ILIKE 'chloroquine%' AND replace(coalesce(m.dosage, ''), ' ', '') ILIKE '100mg'
),
ibu AS (
    SELECT a.id, a.medicament_id, m.id AS fiche_existe, m.dci,
           (SELECT b.medicament_id_avant FROM sauvegarde_fusion.alertes_avant b WHERE b.id = a.id) AS fiche_avant
    FROM alertes_stock a LEFT JOIN medicaments m ON m.id = a.medicament_id
    WHERE a.medicament_nom ILIKE '%ibupro%'
)
SELECT verification, attendu, obtenu, ok FROM (
    SELECT 1 AS n, 'nombre de fiches medicaments' AS verification,
           params.fiches_attendues::text AS attendu, (SELECT count(*) FROM medicaments)::text AS obtenu,
           (SELECT count(*) FROM medicaments) = params.fiches_attendues AS ok FROM params
    UNION ALL
    SELECT 2, 'groupes de doublons restants (requête de doublons vide)', '0',
           (SELECT count(*) FROM (SELECT k FROM cle GROUP BY k HAVING count(*) > 1) x)::text,
           (SELECT count(*) FROM (SELECT k FROM cle GROUP BY k HAVING count(*) > 1) x) = 0
    UNION ALL
    SELECT 3, 'index unique uq_medicaments_nom_dosage', 'présent',
           CASE WHEN to_regclass('public.uq_medicaments_nom_dosage') IS NOT NULL THEN 'présent' ELSE 'absent' END,
           to_regclass('public.uq_medicaments_nom_dosage') IS NOT NULL
    UNION ALL
    SELECT 4, 'lignes de stock orphelines', '0',
           (SELECT count(*) FROM stocks s WHERE NOT EXISTS (SELECT 1 FROM medicaments m WHERE m.id = s.medicament_id))::text,
           NOT EXISTS (SELECT 1 FROM stocks s WHERE NOT EXISTS (SELECT 1 FROM medicaments m WHERE m.id = s.medicament_id))
    UNION ALL
    SELECT 5, 'alertes orphelines (medicament_id vers une fiche absente)', '0',
           (SELECT count(*) FROM alertes_stock a WHERE a.medicament_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM medicaments m WHERE m.id = a.medicament_id))::text,
           NOT EXISTS (SELECT 1 FROM alertes_stock a WHERE a.medicament_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM medicaments m WHERE m.id = a.medicament_id))
    UNION ALL
    SELECT 6, 'pharmacie ' || coalesce((SELECT nom FROM ma LIMIT 1), '(introuvable)') || ' : Coartem',
           params.coartem_prix || ' FCFA, ' || CASE WHEN params.coartem_en_stock THEN 'en stock' ELSE 'rupture' END || ', 1 ligne',
           (SELECT count(*) FROM ma) || ' pharmacie(s) pour le préfixe ; ' || (SELECT count(*) FROM coartem) || ' ligne(s) : ' || coalesce((SELECT string_agg(prix_fcfa || ' FCFA, ' || CASE WHEN en_stock THEN 'en stock' ELSE 'rupture' END, ' ; ') FROM coartem), '-'),
           (SELECT count(*) FROM ma) = 1 AND (SELECT count(*) FROM coartem) = 1 AND EXISTS (SELECT 1 FROM coartem c WHERE c.prix_fcfa = params.coartem_prix AND c.en_stock = params.coartem_en_stock)
    FROM params
    UNION ALL
    SELECT 7, 'pharmacie ' || coalesce((SELECT nom FROM ma LIMIT 1), '(introuvable)') || ' : Chloroquine 100mg',
           params.chloroquine_prix || ' FCFA, ' || CASE WHEN params.chloroquine_en_stock THEN 'en stock' ELSE 'rupture' END || ', 1 ligne',
           (SELECT count(*) FROM ma) || ' pharmacie(s) pour le préfixe ; ' || (SELECT count(*) FROM chloroquine) || ' ligne(s) : ' || coalesce((SELECT string_agg(prix_fcfa || ' FCFA, ' || CASE WHEN en_stock THEN 'en stock' ELSE 'rupture' END, ' ; ') FROM chloroquine), '-'),
           (SELECT count(*) FROM ma) = 1 AND (SELECT count(*) FROM chloroquine) = 1 AND EXISTS (SELECT 1 FROM chloroquine c WHERE c.prix_fcfa = params.chloroquine_prix AND c.en_stock = params.chloroquine_en_stock)
    FROM params
    UNION ALL
    SELECT 8, 'alerte Ibuprofène rattachée à une fiche existante d''ibuprofène',
           'toutes les alertes Ibuprofène -> fiche existante (DCI ibuprofène)',
           (SELECT count(*) FROM ibu) || ' alerte(s) ; ' || (SELECT count(*) FILTER (WHERE fiche_existe IS NOT NULL AND dci ILIKE 'ibupro%') FROM ibu) || ' rattachée(s) ; ' ||
           (SELECT count(*) FILTER (WHERE fiche_avant IS NOT NULL) FROM ibu) || ' déplacée(s) par la fusion',
           (SELECT count(*) FROM ibu) >= 1 AND (SELECT count(*) FROM ibu WHERE NOT (fiche_existe IS NOT NULL AND dci ILIKE 'ibupro%')) = 0
    UNION ALL
    SELECT 9, 'sauvegarde : fiches supprimées', 'informatif (40 - 20 = 20 attendues)',
           (SELECT count(*) FROM sauvegarde_fusion.medicaments_supprimes)::text,
           (SELECT count(*) FROM sauvegarde_fusion.medicaments_supprimes) > 0
    UNION ALL
    SELECT 10, 'sauvegarde : stocks déplacés / supprimés / remplacés', 'informatif',
           (SELECT count(*) FILTER (WHERE action = 'deplace') || ' / ' || count(*) FILTER (WHERE action = 'supprime') || ' / ' || count(*) FILTER (WHERE action = 'mis_a_jour')
            FROM sauvegarde_fusion.stocks_avant),
           true
) t
ORDER BY n;

ROLLBACK;
