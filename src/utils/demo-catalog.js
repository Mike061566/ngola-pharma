/**
 * Catalogue de démonstration (SPEC 2 §4.0bis) : lecture et validation de `supabase/seed/demo_catalog.csv`, puis chargement.
 * Colonnes : dci, brand_name, strength, form, pack_size, requires_prescription, restricted.
 *
 * RÈGLE : `restricted` est une DÉCISION DU PROPRIÉTAIRE. Ce module ne la déduit jamais : `false` n'est accepté que s'il est écrit
 * explicitement ; une valeur absente ou illisible donne `true` (restreint) avec un avertissement. La fiche fictive
 * « Exemple restreint (démo) » est toujours restreinte. Le chargement n'a lieu qu'en mode démo.
 * `pack_size` n'a pas de colonne dans `medicaments` : il est lu mais ignoré.
 */
const COLONNES = ['dci', 'brand_name', 'strength', 'form', 'pack_size', 'requires_prescription', 'restricted'];
const FICTIF = 'exemple restreint (démo)';

function decouper(ligne) {
  const sortie = []; let cur = ''; let q = false;
  for (let i = 0; i < ligne.length; i++) {
    const c = ligne[i];
    if (c === '"') { if (q && ligne[i + 1] === '"') { cur += '"'; i++; } else q = !q; }
    else if (c === ',' && !q) { sortie.push(cur.trim()); cur = ''; }
    else cur += c;
  }
  sortie.push(cur.trim());
  return sortie;
}

const bool = (v) => { const t = String(v ?? '').trim().toLowerCase(); return t === 'true' ? true : t === 'false' ? false : null; };
const norm = (s) => String(s ?? '').trim().toLowerCase();
const cleNomDosage = (m) => `${norm(m.nom)}|${norm(m.dosage).replace(/\s+/g, '')}`;

/** @returns {{ medicaments: object[], erreurs: string[], avertissements: string[] }} */
function analyserCatalogueDemo(texte) {
  const erreurs = [], avertissements = [], medicaments = [];
  const lignes = String(texte || '').replace(/^\uFEFF/, '').split(/\r?\n/).filter((l) => l.trim() !== '');
  if (lignes.length === 0) return { medicaments, erreurs: ['Fichier vide'], avertissements };
  const entete = decouper(lignes[0]).map((c) => c.toLowerCase());
  const manquantes = COLONNES.filter((c) => !entete.includes(c));
  if (manquantes.length) return { medicaments, erreurs: [`Colonnes manquantes : ${manquantes.join(', ')}`], avertissements };
  const vus = new Set();
  lignes.slice(1).forEach((l, i) => {
    const n = i + 2;
    const v = decouper(l); const r = {};
    entete.forEach((c, j) => { r[c] = v[j] ?? ''; });
    const nom = r.brand_name || r.dci;
    if (!nom) { erreurs.push(`Ligne ${n} : ni brand_name ni dci`); return; }
    const ordo = bool(r.requires_prescription);
    if (r.requires_prescription !== '' && ordo === null) { erreurs.push(`Ligne ${n} : requires_prescription doit valoir true ou false`); return; }
    if (ordo === null) avertissements.push(`Ligne ${n} (${nom}) : requires_prescription vide, false retenu (à confirmer)`);
    let restreint = bool(r.restricted);
    if (restreint === null) { restreint = true; avertissements.push(`Ligne ${n} (${nom}) : restricted absent ou illisible, restreint retenu (défaut sûr)`); }
    if (norm(nom) === FICTIF && restreint !== true) { erreurs.push(`Ligne ${n} : « Exemple restreint (démo) » doit rester restricted=true`); return; }
    const med = { nom, nom_commercial: r.brand_name || null, dci: r.dci || null, forme: r.form || null, dosage: r.strength || null,
      categorie: 'démonstration', ordonnance: ordo === true, restreint, est_demo: true };
    const cle = cleNomDosage(med);
    if (vus.has(cle)) { avertissements.push(`Ligne ${n} (${nom}) : doublon dans le fichier, ignoré`); return; }
    vus.add(cle);
    medicaments.push(med);
  });
  return { medicaments, erreurs, avertissements };
}

/**
 * Charge le catalogue (idempotent : une fiche déjà présente, même nom et même dosage, est mise à jour, jamais dupliquée).
 * `sb` : client Supabase SERVICE ROLE. Refuse hors mode démo.
 */
async function chargerCatalogueDemo(sb, medicaments) {
  const mode = await sb.rpc('mode_public');
  if (mode.error) throw new Error(`Mode illisible : ${mode.error.code || 'erreur'}`);
  if (mode.data !== 'demo') throw new Error('Chargement refusé : l\'application n\'est pas en mode démo');
  const { data: existants, error } = await sb.from('medicaments').select('id, nom, dosage, ordonnance, restreint');
  if (error) throw new Error(`Lecture du catalogue : ${error.code || 'erreur'}`);
  const index = new Map((existants || []).map((m) => [cleNomDosage(m), m]));
  const bilan = { inseres: 0, mis_a_jour: 0, inchanges: 0, restreints: 0, non_restreints: 0 };
  for (const m of medicaments) {
    m.restreint ? bilan.restreints++ : bilan.non_restreints++;
    const ex = index.get(cleNomDosage(m));
    if (!ex) {
      const r = await sb.from('medicaments').insert(m);
      if (r.error) throw new Error(`Insertion de « ${m.nom} » : ${r.error.code || 'erreur'}`);
      bilan.inseres++;
    } else if (ex.ordonnance !== m.ordonnance || ex.restreint !== m.restreint) {
      const r = await sb.from('medicaments').update({ ordonnance: m.ordonnance, restreint: m.restreint, est_demo: true }).eq('id', ex.id);
      if (r.error) throw new Error(`Mise à jour de « ${m.nom} » : ${r.error.code || 'erreur'}`);
      bilan.mis_a_jour++;
    } else bilan.inchanges++;
  }
  return bilan;
}

module.exports = { analyserCatalogueDemo, chargerCatalogueDemo };
