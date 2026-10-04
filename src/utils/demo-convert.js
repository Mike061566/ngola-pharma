/**
 * Conversion du catalogue de test « drug_variant_catalog.csv » (colonnes drug_id, dci, atc_code, category, variant_id, brand, dosage,
 * form, is_generic, price_xaf, availability) vers le format de chargement de la démo (supabase/seed/demo_catalog.csv).
 *
 * Choix (documentés dans docs/DEMO.md) :
 *  - une fiche par (marque, forme, dosage) : la forme entre dans le nom (« <marque> <forme> »), car l'index unique de `medicaments`
 *    porte sur nom + dosage ; les variantes qui ne diffèrent que par `is_generic`, le prix ou la disponibilité sont regroupées ;
 *  - `price_xaf`, `availability`, `is_generic`, `atc_code` ne sont pas repris : les stocks par pharmacie sont produits par la remise
 *    à zéro de la démo ;
 *  - `restricted` et `requires_prescription` viennent UNIQUEMENT de la feuille de décisions du propriétaire (une ligne par DCI),
 *    jamais d'une déduction : sans décision explicite, la cellule reste vide (le chargeur retient alors « restreint »).
 */
const { decouper } = require('./demo-catalog');

const ENTETE_SOURCE = ['dci', 'category', 'brand', 'dosage', 'form'];
const ENTETE_SORTIE = 'dci,brand_name,strength,form,pack_size,requires_prescription,restricted,category';
const ENTETE_DECISIONS = 'dci,category,atc_code,requires_prescription,restricted';
const bool = (v) => { const t = String(v ?? '').trim().toLowerCase(); return t === 'true' || t === 'false' ? t : ''; };
const csv = (v) => (/[",\n]/.test(String(v)) ? `"${String(v).replace(/"/g, '""')}"` : String(v));

function lire(texte) {
  const lignes = String(texte || '').replace(/^\uFEFF/, '').split(/\r?\n/).filter((l) => l.trim() !== '');
  if (!lignes.length) throw new Error('Fichier vide');
  const entete = decouper(lignes[0]).map((c) => c.toLowerCase());
  return { entete, lignes: lignes.slice(1).map((l) => { const v = decouper(l); const r = {}; entete.forEach((c, i) => { r[c] = v[i] ?? ''; }); return r; }) };
}

/** Feuille de décisions (dci, requires_prescription, restricted) -> Map dci -> { restricted, requires_prescription } (valeurs explicites seulement). */
function lireDecisions(texte) {
  const map = new Map();
  if (!texte || !String(texte).trim()) return map;
  const { entete, lignes } = lire(texte);
  if (!entete.includes('dci')) throw new Error('Feuille de décisions : colonne « dci » manquante');
  for (const r of lignes) map.set(r.dci.trim().toLowerCase(), { restricted: bool(r.restricted), requires_prescription: bool(r.requires_prescription) });
  return map;
}

/** @returns {{ csv: string, stats: object, dcis: object[] }} */
function convertirCatalogueVariantes(texteSource, texteDecisions = '') {
  const { entete, lignes } = lire(texteSource);
  const manquantes = ENTETE_SOURCE.filter((c) => !entete.includes(c));
  if (manquantes.length) throw new Error(`Colonnes manquantes : ${manquantes.join(', ')}`);
  const decisions = lireDecisions(texteDecisions);
  const vus = new Set(), sorties = [], dcis = new Map();
  let ignorees = 0;
  for (const r of lignes) {
    if (!r.dci || !r.brand) throw new Error('Ligne sans dci ou sans marque');
    if (!dcis.has(r.dci)) dcis.set(r.dci, { dci: r.dci, category: r.category, atc_code: (r.atc_code || '').replace(/^WHO ATC:\s*/, '') });
    const nom = `${r.brand} ${r.form}`.trim();
    const cle = [nom, r.dosage].map((x) => x.toLowerCase().replace(/\s+/g, '')).join('|');
    if (vus.has(cle)) { ignorees++; continue; }
    vus.add(cle);
    const d = decisions.get(r.dci.trim().toLowerCase()) || { restricted: '', requires_prescription: '' };
    sorties.push([r.dci, nom, r.dosage, r.form, '', d.requires_prescription, d.restricted, r.category].map(csv).join(','));
  }
  const decidees = [...dcis.keys()].filter((k) => { const d = decisions.get(k.trim().toLowerCase()); return d && d.restricted !== ''; }).length;
  return { csv: [ENTETE_SORTIE, ...sorties].join('\n') + '\n',
    stats: { fiches: sorties.length, variantes_regroupees: ignorees, dci: dcis.size, dci_avec_decision_restricted: decidees, dci_sans_decision: dcis.size - decidees },
    dcis: [...dcis.values()] };
}

/** Feuille de décisions à remplir par le propriétaire : une ligne par DCI, cellules `restricted` et `requires_prescription` VIDES. */
function genererFeuilleDecisions(dcis, texteExistant = '') {
  const existantes = lireDecisions(texteExistant);
  const lignes = dcis.map((d) => {
    const e = existantes.get(d.dci.trim().toLowerCase()) || { restricted: '', requires_prescription: '' };
    return [d.dci, d.category, d.atc_code, e.requires_prescription, e.restricted].map(csv).join(',');
  });
  return [ENTETE_DECISIONS, ...lignes].join('\n') + '\n';
}

module.exports = { convertirCatalogueVariantes, genererFeuilleDecisions, lireDecisions };
