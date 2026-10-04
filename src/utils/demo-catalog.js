/**
 * Catalogue de démonstration (SPEC 2 §4.0bis) : lecture et validation de `supabase/seed/demo_catalog.csv`, puis chargement.
 * Colonnes : dci, brand_name, strength, form, pack_size, requires_prescription, restricted.
 *
 * RÈGLE : `restricted` est une DÉCISION DU PROPRIÉTAIRE. Ce module ne la déduit jamais : `false` n'est accepté que s'il est écrit
 * explicitement ; une valeur absente ou illisible donne `true` (restreint) avec un avertissement. La fiche fictive
 * « Exemple restreint (démo) » est toujours restreinte. Le chargement n'a lieu qu'en mode démo.
 * `pack_size` alimente `medicaments.conditionnement` (nom français de la colonne) ; il fait partie de l'identité de la fiche (nom + dosage +
 * conditionnement, comme l'index unique). Ce module n'écrit JAMAIS restricted/requires_prescription autrement que d'après le fichier (inchangé).
 * `category` (facultative) alimente `categorie`.
 * Les avertissements répétitifs sont regroupés (les 5 premiers sont détaillés, puis un total).
 */
const COLONNES = ['dci', 'brand_name', 'strength', 'form', 'pack_size', 'requires_prescription', 'restricted'];   // + `category` facultative
const FICTIF = 'exemple restreint (démo)';

function decouper(ligne) {   // découpe une ligne CSV (guillemets, "" échappé)
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
const sansEspaces = (v) => norm(v).replace(/\s+/g, '');
const cleNomDosage = (m) => `${norm(m.nom)}|${sansEspaces(m.dosage)}|${sansEspaces(m.conditionnement)}`;   // même clé que l'index unique
const cleSansConditionnement = (m) => `${norm(m.nom)}|${sansEspaces(m.dosage)}`;

/** @returns {{ medicaments: object[], erreurs: string[], avertissements: string[] }} */
function analyserCatalogueDemo(texte) {
  const erreurs = [], medicaments = [];
  const brut = { restricted: [], ordonnance: [], doublon: [] };
  const avertissements = [];
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
    if (ordo === null) brut.ordonnance.push(`Ligne ${n} (${nom}) : requires_prescription vide, false retenu (à confirmer)`);
    let restreint = bool(r.restricted);
    if (restreint === null) { restreint = true; brut.restricted.push(`Ligne ${n} (${nom}) : restricted absent ou illisible, restreint retenu (défaut sûr)`); }
    if (norm(nom) === FICTIF && restreint !== true) { erreurs.push(`Ligne ${n} : « Exemple restreint (démo) » doit rester restricted=true`); return; }
    const med = { nom, nom_commercial: r.brand_name || null, dci: r.dci || null, forme: r.form || null, dosage: r.strength || null, conditionnement: (r.pack_size || '').trim() || null,
      categorie: r.category || 'démonstration', ordonnance: ordo === true, restreint, est_demo: true };
    const cle = cleNomDosage(med);
    if (vus.has(cle)) { brut.doublon.push(`Ligne ${n} (${nom}) : doublon dans le fichier, ignoré`); return; }
    vus.add(cle);
    medicaments.push(med);
  });
  const libelles = { restricted: 'fiche(s) sans décision « restricted » : restreint(es) par défaut', ordonnance: 'fiche(s) sans requires_prescription : false retenu (à confirmer)', doublon: 'doublon(s) ignoré(s)' };
  for (const k of Object.keys(brut)) {
    avertissements.push(...brut[k].slice(0, 5));
    if (brut[k].length > 5) avertissements.push(`… ${brut[k].length} ${libelles[k]} au total`);
  }
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
  const { data: existants, error } = await sb.from('medicaments').select('id, nom, dosage, conditionnement, ordonnance, restreint');
  if (error) throw new Error(`Lecture du catalogue : ${error.code || 'erreur'}`);
  const index = new Map((existants || []).map((m) => [cleNomDosage(m), m]));
  // Fiches existantes SANS conditionnement : si le fichier en indique un pour le même nom et dosage, la fiche l'adopte (pas de doublon).
  const sansPack = new Map();
  (existants || []).filter((m) => !norm(m.conditionnement)).forEach((m) => { if (!sansPack.has(cleSansConditionnement(m))) sansPack.set(cleSansConditionnement(m), m); });
  const adoptees = new Set();
  const bilan = { inseres: 0, mis_a_jour: 0, inchanges: 0, restreints: 0, non_restreints: 0 };
  for (const m of medicaments) {
    m.restreint ? bilan.restreints++ : bilan.non_restreints++;
    let ex = index.get(cleNomDosage(m));
    if (!ex && m.conditionnement) {
      const candidate = sansPack.get(cleSansConditionnement(m));
      if (candidate && !adoptees.has(candidate.id)) {
        adoptees.add(candidate.id);
        const r = await sb.from('medicaments').update({ conditionnement: m.conditionnement }).eq('id', candidate.id);   // seulement le conditionnement
        if (r.error) throw new Error(`Mise à jour du conditionnement de « ${m.nom} » : ${r.error.code || 'erreur'}`);
        bilan.conditionnements_renseignes = (bilan.conditionnements_renseignes || 0) + 1;
        ex = { ...candidate, conditionnement: m.conditionnement };
        index.set(cleNomDosage(m), ex);
      }
    }
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

module.exports = { analyserCatalogueDemo, chargerCatalogueDemo, decouper };
