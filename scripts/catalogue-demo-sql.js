#!/usr/bin/env node
/**
 * Génère `supabase/ops/charger_catalogue_demo.sql` depuis `supabase/seed/demo_catalog.csv` (phase I2 de docs/MISE-EN-PRODUCTION.md).
 *
 *   node scripts/catalogue-demo-sql.js            → réécrit le fichier SQL
 *   node scripts/catalogue-demo-sql.js --verifier → échoue si le fichier SQL n'est plus à jour du CSV
 *
 * Même lecture que `scripts/demo-reset.js --catalogue` (analyserCatalogueDemo) et même logique que chargerCatalogueDemo, mais
 * exécutable dans le SQL Editor de Supabase : ni Node.js chez le propriétaire, ni clé service_role dans un terminal.
 * Ne décide JAMAIS de la classification : `restreint` et `ordonnance` viennent du CSV (restricted vide → restreint, défaut sûr).
 */
const fs = require('fs');
const path = require('path');
const { analyserCatalogueDemo } = require('../src/utils/demo-catalog');

const CSV = path.join(__dirname, '../supabase/seed/demo_catalog.csv');
const SQL = path.join(__dirname, '../supabase/ops/charger_catalogue_demo.sql');

const litteral = (v) => (v === null || v === undefined ? 'NULL' : `'${String(v).replace(/'/g, "''")}'`);

function genererSqlCatalogueDemo(texteCsv) {
  const { medicaments, erreurs } = analyserCatalogueDemo(texteCsv);
  if (erreurs.length) throw new Error(`Catalogue invalide : ${erreurs.join(' ; ')}`);
  const restreintes = medicaments.filter((m) => m.restreint).length;
  const valeurs = medicaments.map((m, i) => `    (${[i + 1, litteral(m.nom), litteral(m.nom_commercial), litteral(m.dci), litteral(m.forme), litteral(m.dosage),
    litteral(m.conditionnement), litteral(m.categorie), m.ordonnance, m.restreint].join(', ')})`).join(',\n');

  return `-- ============================================================
-- Chargement du catalogue de démonstration (phase I2 de docs/MISE-EN-PRODUCTION.md) — À EXÉCUTER À LA MAIN dans le SQL Editor.
-- FICHIER GÉNÉRÉ par \`node scripts/catalogue-demo-sql.js\` depuis supabase/seed/demo_catalog.csv : ne pas le modifier à la main.
--
-- Équivalent SQL de \`node scripts/demo-reset.js --catalogue supabase/seed/demo_catalog.csv\` (partie catalogue), sans Node.js
-- ni clé service_role. Même lecture du fichier, mêmes règles :
--   - refusé si l'application n'est pas en mode démo ;
--   - une fiche déjà présente (même nom, dosage et conditionnement, comme l'index unique) n'est jamais dupliquée : seules
--     « ordonnance » et « restreint » sont alignées sur le fichier ;
--   - classification : AUCUNE décision ici. « restricted » vide dans le fichier → fiche restreinte (défaut sûr) ;
--     la classification réelle est faite par votre pharmacien validateur (phase I3).
-- Fichier : ${medicaments.length} fiches, dont ${restreintes} restreinte(s) et ${medicaments.length - restreintes} non restreinte(s).
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
    SELECT lower(btrim(p_nom)) || '|' || lower(regexp_replace(coalesce(p_dosage, ''), '\\s', '', 'g'))
           || '|' || lower(regexp_replace(coalesce(p_conditionnement, ''), '\\s', '', 'g'))
$f$;

CREATE TEMP TABLE _catalogue (
    ligne int PRIMARY KEY, nom text NOT NULL, nom_commercial text, dci text, forme text, dosage text, conditionnement text,
    categorie text NOT NULL, ordonnance boolean NOT NULL, restreint boolean NOT NULL
) ON COMMIT DROP;
INSERT INTO _catalogue (ligne, nom, nom_commercial, dci, forme, dosage, conditionnement, categorie, ordonnance, restreint) VALUES
${valeurs};

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
`;
}

if (require.main === module) {
  const sql = genererSqlCatalogueDemo(fs.readFileSync(CSV, 'utf-8'));
  if (process.argv.includes('--verifier')) {
    const actuel = fs.existsSync(SQL) ? fs.readFileSync(SQL, 'utf-8') : '';
    if (actuel !== sql) { console.error('❌ supabase/ops/charger_catalogue_demo.sql n\'est plus à jour : node scripts/catalogue-demo-sql.js'); process.exit(1); }
    console.log('✅ charger_catalogue_demo.sql à jour du CSV');
  } else {
    fs.writeFileSync(SQL, sql);
    console.log(`✅ ${path.relative(process.cwd(), SQL)} généré`);
  }
}

module.exports = { genererSqlCatalogueDemo };
