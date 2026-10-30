#!/usr/bin/env node
/**
 * Remet les données de démonstration à zéro (SPEC 2 §4.0bis) — rejouable : même état à chaque exécution.
 *
 *   SUPABASE_URL=... SUPABASE_SERVICE_KEY=... node scripts/demo-reset.js --confirmer [--nb-pharmacies 6] [--catalogue supabase/seed/demo_catalog.csv]
 *
 * - REFUSE de s'exécuter si l'application n'est pas en mode démo (contrôle côté base, deux fois).
 * - Sans `--confirmer`, n'écrit rien : affiche seulement la cible et ce qui serait fait.
 * - Efface alertes, messages en file, jetons patients, liste de blocage ; rétablit un échantillon déterministe de pharmacies de
 *   démonstration (vérifiées, publiées, ouvertes 24 h/24) et leurs stocks. Conserve contacts et liste blanche des comptes de test.
 * - N'envoie AUCUN message. Ne décide JAMAIS de la classification d'un médicament : `restricted` vient du CSV du propriétaire.
 * - Les clés viennent de l'environnement : jamais dans le dépôt ni dans la ligne de commande.
 */
require('dotenv').config();
const fs = require('fs');
const path = require('path');
const { createClient } = require('@supabase/supabase-js');
const { analyserCatalogueDemo, chargerCatalogueDemo } = require('../src/utils/demo-catalog');
const { reinitialiserDemo } = require('../src/utils/demo-reset');

function lireArguments(argv) {
  const a = { confirmer: false, nbPharmacies: 6, catalogue: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--confirmer') a.confirmer = true;
    else if (argv[i] === '--nb-pharmacies') a.nbPharmacies = parseInt(argv[++i], 10);
    else if (argv[i] === '--catalogue') a.catalogue = argv[++i] || 'supabase/seed/demo_catalog.csv';
    else throw new Error(`Argument inconnu : ${argv[i]}`);
  }
  if (!Number.isInteger(a.nbPharmacies) || a.nbPharmacies < 1 || a.nbPharmacies > 50) throw new Error('--nb-pharmacies : entier de 1 à 50');
  return a;
}

async function main() {
  const a = lireArguments(process.argv.slice(2));
  const url = process.env.SUPABASE_URL, cle = process.env.SUPABASE_SERVICE_KEY;
  if (!url || !cle) { console.error('❌ SUPABASE_URL et SUPABASE_SERVICE_KEY requis (variables d\'environnement)'); process.exit(1); }
  console.log(`Cible : ${new URL(url).host}`);
  if (!a.confirmer) {
    console.log('Simulation (aucune écriture). Ajoutez --confirmer pour remettre les données de démonstration à zéro.');
    console.log(`Serait fait : purge des alertes et messages, ${a.nbPharmacies} pharmacies de démonstration rétablies${a.catalogue ? `, chargement de ${a.catalogue}` : ''}.`);
    return;
  }
  const sb = createClient(url, cle, { auth: { persistSession: false } });
  if (a.catalogue) {
    const analyse = analyserCatalogueDemo(fs.readFileSync(path.resolve(a.catalogue), 'utf-8'));
    analyse.avertissements.forEach((w) => console.warn(`⚠️  ${w}`));
    if (analyse.erreurs.length) { analyse.erreurs.forEach((e) => console.error(`❌ ${e}`)); process.exit(1); }
    const bilan = await chargerCatalogueDemo(sb, analyse.medicaments);
    console.log(`Catalogue : ${bilan.inseres} inséré(s), ${bilan.mis_a_jour} mis à jour, ${bilan.inchanges} inchangé(s) — ${bilan.restreints} restreint(s), ${bilan.non_restreints} non restreint(s)`);
  }
  const r = await reinitialiserDemo(sb, { nbPharmacies: a.nbPharmacies });
  console.log(`✅ Remise à zéro : ${r.alertes_supprimees} alerte(s) et ${r.messages_supprimes} message(s) supprimés, ${r.stocks} stocks rétablis`);
  console.log(`   Pharmacies du scénario : ${r.pharmacies_scenario.join(', ') || '(aucune)'}`);
  console.log(`   Empreinte de l'état : ${r.empreinte}  (identique à chaque exécution)`);
  (r.avertissements || []).forEach((w) => console.warn(`⚠️  ${w}`));
}

if (require.main === module) main().catch((e) => { console.error(`❌ ${e.message}`); process.exit(1); });
module.exports = { lireArguments };
