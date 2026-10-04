#!/usr/bin/env node
/**
 * Convertit le catalogue de test (drug_variant_catalog.csv) en catalogue de démonstration chargeable, et maintient la feuille de
 * décisions du propriétaire (une ligne par DCI : requires_prescription, restricted).
 *
 *   node scripts/demo-convert-catalog.js [--source supabase/seed/source/drug_variant_catalog.csv]
 *        [--decisions supabase/seed/demo_classification.csv] [--sortie supabase/seed/demo_catalog.csv]
 *
 * - `restricted` et `requires_prescription` ne viennent QUE de la feuille de décisions (valeurs « true » / « false » écrites par le
 *   propriétaire). Une cellule vide reste vide : le chargeur retient alors « restreint » (défaut sûr). Ce script ne décide de rien.
 * - La feuille est créée (cellules vides) si elle n'existe pas ; si elle existe, vos décisions sont conservées.
 * - La fiche fictive « Exemple restreint (démo) » est ajoutée (restricted=true, obligatoire pour la démonstration du garde-fou).
 * - Aucun accès réseau, aucune clé.
 */
const fs = require('fs');
const path = require('path');
const { convertirCatalogueVariantes, genererFeuilleDecisions } = require('../src/utils/demo-convert');

function lireArguments(argv) {
  const a = { source: 'supabase/seed/source/drug_variant_catalog.csv', decisions: 'supabase/seed/demo_classification.csv', sortie: 'supabase/seed/demo_catalog.csv' };
  for (let i = 0; i < argv.length; i++) {
    const k = { '--source': 'source', '--decisions': 'decisions', '--sortie': 'sortie' }[argv[i]];
    if (!k) throw new Error(`Argument inconnu : ${argv[i]}`);
    a[k] = argv[++i];
    if (!a[k]) throw new Error(`${argv[i - 1]} : valeur manquante`);
  }
  return a;
}

function main() {
  const a = lireArguments(process.argv.slice(2));
  const lire = (f) => (fs.existsSync(f) ? fs.readFileSync(f, 'utf-8') : '');
  const decisions = lire(a.decisions);
  const r = convertirCatalogueVariantes(fs.readFileSync(a.source, 'utf-8'), decisions);
  fs.writeFileSync(a.decisions, genererFeuilleDecisions(r.dcis, decisions));
  fs.writeFileSync(a.sortie, r.csv + ',Exemple restreint (démo),,fictif,,false,true,démonstration\n');
  console.log(`✅ ${a.sortie} : ${r.stats.fiches} fiches (${r.stats.variantes_regroupees} variantes regroupées) + la fiche fictive`);
  console.log(`   ${r.stats.dci} DCI : ${r.stats.dci_avec_decision_restricted} avec décision « restricted », ${r.stats.dci_sans_decision} SANS décision (restreintes par défaut)`);
  console.log(`   Feuille de décisions du propriétaire : ${a.decisions}`);
  console.log('   Chargement : node scripts/demo-reset.js --confirmer --catalogue ' + path.relative(process.cwd(), a.sortie));
}

if (require.main === module) { try { main(); } catch (e) { console.error(`❌ ${e.message}`); process.exit(1); } }
module.exports = { lireArguments };
