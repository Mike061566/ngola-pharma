#!/usr/bin/env node
/**
 * Compare l'inventaire du schéma de production (supabase/diagnostics/schema_inventory.sql)
 * à l'inventaire attendu (supabase/baseline/inventory.expected.txt).
 *
 *   node scripts/compare-schema.js prod_inventory.csv [inventaire_attendu.txt]
 *
 * Entrée : fichier CSV/texte avec une ligne `type|clé|valeur` par objet (colonne `ligne`).
 * Sortie : objets MANQUANTS en prod, DIFFÉRENTS, et EN TROP. Code de sortie 1 s'il y a des
 * manquants ou des différences (les « en trop » sont signalés mais n'échouent pas).
 * Lecture seule : ce script ne se connecte à aucune base.
 */
const fs = require('fs');
const path = require('path');

const DEFAULT_EXPECTED = path.join(__dirname, '..', 'supabase', 'baseline', 'inventory.expected.txt');

// Correctifs connus : objet manquant/différent -> script SQL qui le pose.
const KNOWN_FIXES = [
  [/^trigger\|pharmacies\.trg_pharmacies_protect\|/, 'supabase/fix_pharmacies_colonnes_protegees.sql'],
  [/^function\|protect_pharmacies_columns\(/, 'supabase/fix_pharmacies_colonnes_protegees.sql'],
  [/^policy\|pharmacies\.Pharmacien modifie sa pharmacie\|/, 'supabase/fix_pharmacies_colonnes_protegees.sql'],
  [/^policy\|profils\.profils_update\|/, 'supabase/fix_profils_pharmacie_id.sql'],
];

function normalizeValue(s) {
  return s.replace(/\b(?:public|extensions)\./g, '').replace(/\s+/g, ' ').trim();
}

/** Lit un contenu CSV/texte et renvoie Map<"type|clé", valeur>. Ignore `info|` et les lignes non conformes. */
function parseInventory(content) {
  const entries = new Map();
  for (let raw of content.replace(/^﻿/, '').split(/\r?\n/)) {
    let line = raw.trim();
    if (line.startsWith('"') && line.endsWith('"') && line.length >= 2) {
      line = line.slice(1, -1).replace(/""/g, '"');
    }
    const m = /^([a-z_]+)\|([^|]*)\|(.*)$/.exec(line);
    if (!m || m[1] === 'info') continue;
    entries.set(`${m[1]}|${normalizeValue(m[2])}`, normalizeValue(m[3]));
  }
  return entries;
}

/** Les informations `info|count...` (comptes de lignes), à titre indicatif. */
function parseInfo(content) {
  const out = [];
  for (let raw of content.replace(/^﻿/, '').split(/\r?\n/)) {
    let line = raw.trim();
    if (line.startsWith('"') && line.endsWith('"')) line = line.slice(1, -1);
    const m = /^info\|([^|]*)\|(.*)$/.exec(line);
    if (m) out.push(`${m[1]} = ${m[2]}`);
  }
  return out;
}

function compareInventories(expected, prod) {
  const missing = [];
  const different = [];
  const extra = [];
  for (const [key, value] of expected) {
    if (!prod.has(key)) missing.push({ key, expected: value });
    else if (prod.get(key) !== value) different.push({ key, expected: value, prod: prod.get(key) });
  }
  for (const [key, value] of prod) {
    // Les extensions installées en plus (propres à Supabase) ne sont pas des écarts.
    if (!expected.has(key) && !key.startsWith('extension|')) extra.push({ key, prod: value });
  }
  return { missing, different, extra };
}

function fixHint(key, value) {
  const probe = `${key}|${value}`;
  const hit = KNOWN_FIXES.find(([re]) => re.test(probe));
  return hit ? hit[1] : null;
}

function formatReport({ missing, different, extra }, info) {
  const out = [];
  const hints = new Set();
  const section = (titre, items, render) => {
    out.push(`\n== ${titre} (${items.length}) ==`);
    items.forEach((it) => {
      out.push(render(it));
      const hint = fixHint(it.key, it.expected || it.prod || '');
      if (hint) hints.add(hint);
    });
  };
  section('MANQUANT en prod', missing, (it) => `- ${it.key}\n    attendu : ${it.expected}`);
  section('DIFFÉRENT', different, (it) => `- ${it.key}\n    attendu : ${it.expected}\n    en prod : ${it.prod}`);
  section('EN TROP en prod (absent de la baseline)', extra, (it) => `- ${it.key}\n    en prod : ${it.prod}`);
  if (hints.size) {
    out.push('\nCorrectifs du dépôt qui couvrent ces écarts :');
    hints.forEach((h) => out.push(`  - ${h}`));
  }
  if (info.length) {
    out.push('\nComptes de lignes en prod (informatif) :');
    info.forEach((i) => out.push(`  ${i}`));
  }
  return out.join('\n');
}

function main(argv) {
  const [prodPath, expectedPath = DEFAULT_EXPECTED] = argv;
  if (!prodPath) {
    console.error('Usage : node scripts/compare-schema.js prod_inventory.csv [inventaire_attendu.txt]');
    return 2;
  }
  const prodContent = fs.readFileSync(prodPath, 'utf8');
  const prod = parseInventory(prodContent);
  if (prod.size === 0) {
    console.error('Aucune ligne `type|clé|valeur` reconnue dans le fichier de prod.');
    return 2;
  }
  const expected = parseInventory(fs.readFileSync(expectedPath, 'utf8'));
  const result = compareInventories(expected, prod);
  console.log(formatReport(result, parseInfo(prodContent)));
  const ecarts = result.missing.length + result.different.length;
  console.log(ecarts === 0 ? '\n✅ La prod correspond à la baseline.' : `\n❌ ${ecarts} écart(s) à examiner.`);
  return ecarts === 0 ? 0 : 1;
}

if (require.main === module) process.exit(main(process.argv.slice(2)));

module.exports = { parseInventory, parseInfo, compareInventories, normalizeValue, fixHint };
