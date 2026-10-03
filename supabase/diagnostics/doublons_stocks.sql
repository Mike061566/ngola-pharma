-- ============================================================
-- N'Gola Pharma — Diagnostic LECTURE SEULE : doublons de stock
--
-- À exécuter dans le SQL Editor Supabase (production). Ne modifie RIEN :
-- la transaction est en lecture seule et se termine par ROLLBACK.
-- Résultat attendu à renvoyer : les 4 tableaux (ou une capture de chacun).
--
-- Contexte : tous les scripts du dépôt déclarent UNIQUE(pharmacie_id, medicament_id)
-- sur `stocks`. Deux lignes « pour la même pharmacie et le même médicament » viennent
-- donc probablement de DEUX fiches `medicaments` pour le même produit (ex. 'Coartem'
-- et 'Artemether-Lumefantrine', ou 'Chloroquine' et 'Chloroquine 100mg'), ou bien la
-- contrainte n'existe pas en prod. Les requêtes 1 et 2 tranchent.
-- ============================================================
BEGIN READ ONLY;

-- ── 1. La contrainte d'unicité existe-t-elle sur stocks ? ─────────────
SELECT conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'public.stocks'::regclass AND contype IN ('u', 'p')
ORDER BY conname;

-- ── 2. Doublons STRICTS : même (pharmacie_id, medicament_id) ─────────
-- Attendu : 0 ligne si la contrainte du point 1 existe.
SELECT s.pharmacie_id, p.nom AS pharmacie, s.medicament_id, m.nom AS medicament,
       count(*) AS nb_lignes
FROM stocks s
JOIN pharmacies p ON p.id = s.pharmacie_id
JOIN medicaments m ON m.id = s.medicament_id
GROUP BY s.pharmacie_id, p.nom, s.medicament_id, m.nom
HAVING count(*) > 1;

-- ── 3. Fiches catalogue en double (même produit, ids différents) ─────
-- Clé d'identité d'un produit : DCI + nom commercial + dosage + forme, en minuscules
-- et sans espaces. Deux marques différentes (ex. Doliprane / Efferalgan) ne sont donc
-- PAS regroupées. `nb_stocks` = nombre de lignes de stock qui utilisent la fiche.
WITH cle AS (
    SELECT m.*,
           lower(btrim(coalesce(dci, '')))                       AS k_dci,
           lower(btrim(coalesce(nom_commercial, '')))            AS k_marque,
           lower(regexp_replace(coalesce(dosage, ''), '\s', '', 'g')) AS k_dosage,
           lower(btrim(coalesce(forme, '')))                     AS k_forme
    FROM medicaments m
), groupes AS (
    SELECT k_dci, k_marque, k_dosage, k_forme, count(*) AS nb_fiches
    FROM cle
    GROUP BY k_dci, k_marque, k_dosage, k_forme
    HAVING count(*) > 1
)
SELECT c.k_dci AS dci, c.k_marque AS marque, c.k_dosage AS dosage, c.k_forme AS forme,
       g.nb_fiches,
       c.id AS medicament_id, c.nom, c.created_at,
       (SELECT count(*) FROM stocks s WHERE s.medicament_id = c.id) AS nb_stocks
FROM cle c
JOIN groupes g USING (k_dci, k_marque, k_dosage, k_forme)
ORDER BY c.k_dci, c.k_marque, c.k_dosage, c.created_at;

-- ── 4. Lignes de stock concernées : une ligne par stock, à comparer ───
-- Une pharmacie apparaît plusieurs fois pour un même produit = doublon à arbitrer.
-- Colonnes à lire pour choisir quelle ligne garder : prix_fcfa, en_stock, date_maj, source.
WITH cle AS (
    SELECT m.id, m.nom, m.dosage,
           lower(btrim(coalesce(dci, '')))                       AS k_dci,
           lower(btrim(coalesce(nom_commercial, '')))            AS k_marque,
           lower(regexp_replace(coalesce(dosage, ''), '\s', '', 'g')) AS k_dosage,
           lower(btrim(coalesce(forme, '')))                     AS k_forme
    FROM medicaments m
)
SELECT p.nom AS pharmacie, c.k_dci AS dci, c.k_marque AS marque, c.k_dosage AS dosage,
       s.id AS stock_id, c.id AS medicament_id, c.nom AS medicament,
       s.prix_fcfa, s.en_stock, s.date_maj, s.source,
       count(*) OVER (PARTITION BY s.pharmacie_id, c.k_dci, c.k_marque, c.k_dosage, c.k_forme) AS nb_lignes_meme_produit
FROM stocks s
JOIN cle c ON c.id = s.medicament_id
JOIN pharmacies p ON p.id = s.pharmacie_id
WHERE (s.pharmacie_id, c.k_dci, c.k_marque, c.k_dosage, c.k_forme) IN (
    SELECT s2.pharmacie_id, c2.k_dci, c2.k_marque, c2.k_dosage, c2.k_forme
    FROM stocks s2 JOIN cle c2 ON c2.id = s2.medicament_id
    GROUP BY 1, 2, 3, 4, 5
    HAVING count(*) > 1
)
ORDER BY p.nom, c.k_dci, c.k_marque, c.k_dosage, s.date_maj DESC;

ROLLBACK;
