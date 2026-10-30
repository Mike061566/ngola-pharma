// Pré-inscription d'une officine (SPEC 1 §3). Logique testable : l'Edge Function `creer-demande` n'est qu'un adaptateur HTTP.
// Aucune ordonnance n'est collectée (CLAUDE.md règle 5). Justificatifs : PDF/JPG/PNG, 5 Mo max, type vérifié sur les octets.
import { verifierCaptcha } from './captcha.js';
import { normaliserTelephone } from './creation-alerte.js';
import { hmacHex, jetonBase64url } from './securite.js';

export const TAILLE_MAX_FICHIER = 5 * 1024 * 1024;
export const NATURES_OBLIGATOIRES = ['ordre_attestation', 'autorisation_exploitation'];
export const NATURES = ['ordre_attestation', 'autorisation_exploitation', 'id_titulaire', 'autre'];
const JOURS = ['lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim'];
const CHAMPS = ['nom_pharmacie', 'quartier_id', 'adresse', 'telephone_fixe', 'nom_titulaire', 'numero_ordre', 'email_titulaire',
  'telephone_mobile', 'latitude', 'longitude', 'horaires', 'participe_garde', 'consentement_conditions', 'consentement_messages', 'captcha'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;

const ERREURS = {
  corps_invalide: [400, 'Requête invalide.'],
  champ_inconnu: [400, 'Champ non autorisé.'],
  ordonnance_interdite: [400, 'Aucune ordonnance ne doit être envoyée.'],
  nom_invalide: [400, 'Indiquez le nom de l\'officine.'],
  quartier_invalide: [400, 'Choisissez un quartier.'],
  adresse_invalide: [400, 'Indiquez l\'adresse de l\'officine.'],
  telephone_fixe_invalide: [400, 'Numéro fixe de l\'officine invalide (ex. 222 23 45 67).'],
  telephone_mobile_invalide: [400, 'Numéro mobile invalide (ex. 6XX XX XX XX ou +237 6XX XX XX XX).'],
  titulaire_invalide: [400, 'Indiquez le nom complet du pharmacien titulaire.'],
  ordre_invalide: [400, 'Indiquez le numéro d\'inscription à l\'Ordre.'],
  email_invalide: [400, 'Adresse email invalide.'],
  position_invalide: [400, 'Position invalide.'],
  horaires_invalides: [400, 'Horaires invalides : au moins un jour ouvert, heures au format HH:MM, ouverture avant fermeture.'],
  consentement_requis: [400, 'Les deux consentements sont nécessaires.'],
  captcha_invalide: [403, 'Vérification anti-robot échouée. Réessayez.'],
  captcha_indisponible: [503, 'Vérification anti-robot indisponible. Réessayez dans un instant.'],
  captcha_non_configure: [503, 'Service temporairement indisponible.'],
  document_manquant: [400, 'Joignez l\'attestation d\'inscription à l\'Ordre et l\'autorisation d\'exploitation.'],
  document_invalide: [400, 'Document refusé : PDF, JPG ou PNG, 5 Mo au maximum.'],
  limite_quotidienne: [429, 'Trop de demandes aujourd\'hui depuis cette connexion. Réessayez demain.'],
  erreur_interne: [500, 'Une erreur est survenue. Réessayez.'],
};
export const reponseErreur = (code) => ({ status: ERREURS[code][0], corps: { erreur: code, message: ERREURS[code][1] } });

const texte = (v, min, max) => {
  if (typeof v !== 'string') return null;
  const t = v.trim().replace(/\s+/g, ' ');
  return t.length >= min && t.length <= max ? t : null;
};

/** Grille d'horaires { lun: {ouv, fer} | null, ... } -> même forme nettoyée, ou null si invalide. Au moins un jour ouvert. */
export function validerHoraires(h) {
  if (!h || typeof h !== 'object' || Array.isArray(h)) return null;
  const sortie = {};
  for (const k of Object.keys(h)) if (!JOURS.includes(k)) return null;
  for (const j of JOURS) {
    const d = h[j];
    if (d === undefined || d === null) continue;
    if (typeof d !== 'object' || !HHMM.test(d.ouv || '') || !HHMM.test(d.fer || '') || d.ouv >= d.fer) return null;
    sortie[j] = { ouv: d.ouv, fer: d.fer };
  }
  return Object.keys(sortie).length ? sortie : null;
}

/** Valide et normalise les champs texte de la demande. Renvoie { ok, valeur } ou { ok:false, erreur }. */
export function validerChamps(c) {
  if (!c || typeof c !== 'object' || Array.isArray(c)) return { ok: false, erreur: 'corps_invalide' };
  for (const k of Object.keys(c)) {
    if (/ordonnance|prescription/i.test(k)) return { ok: false, erreur: 'ordonnance_interdite' };
    if (!CHAMPS.includes(k)) return { ok: false, erreur: 'champ_inconnu' };
  }
  const nom = texte(c.nom_pharmacie, 2, 120); if (!nom) return { ok: false, erreur: 'nom_invalide' };
  if (typeof c.quartier_id !== 'string' || !UUID.test(c.quartier_id)) return { ok: false, erreur: 'quartier_invalide' };
  const adresse = texte(c.adresse, 3, 250); if (!adresse) return { ok: false, erreur: 'adresse_invalide' };
  const fixe = normaliserTelephone(c.telephone_fixe); if (!fixe) return { ok: false, erreur: 'telephone_fixe_invalide' };
  const mobile = normaliserTelephone(c.telephone_mobile);
  if (!mobile || !mobile.startsWith('+2376')) return { ok: false, erreur: 'telephone_mobile_invalide' };
  const titulaire = texte(c.nom_titulaire, 2, 120); if (!titulaire) return { ok: false, erreur: 'titulaire_invalide' };
  const ordre = texte(c.numero_ordre, 2, 40); if (!ordre) return { ok: false, erreur: 'ordre_invalide' };
  const email = typeof c.email_titulaire === 'string' ? c.email_titulaire.trim().toLowerCase() : '';
  if (email.length > 200 || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return { ok: false, erreur: 'email_invalide' };
  const num = (v, min, max) => v === undefined || v === null ? null : (typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max ? v : NaN);
  const lat = num(c.latitude, -90, 90), lng = num(c.longitude, -180, 180);
  if (Number.isNaN(lat) || Number.isNaN(lng) || (lat === null) !== (lng === null)) return { ok: false, erreur: 'position_invalide' };
  const horaires = validerHoraires(c.horaires); if (!horaires) return { ok: false, erreur: 'horaires_invalides' };
  if (c.consentement_conditions !== true || c.consentement_messages !== true) return { ok: false, erreur: 'consentement_requis' };
  if (typeof c.captcha !== 'string') return { ok: false, erreur: 'captcha_invalide' };
  return { ok: true, valeur: { nom_pharmacie: nom, quartier_id: c.quartier_id, adresse, telephone_fixe: fixe, nom_titulaire: titulaire,
    numero_ordre: ordre, email_titulaire: email, telephone_mobile: mobile, latitude: lat, longitude: lng, horaires,
    participe_garde: c.participe_garde === true, captcha: c.captcha } };
}

/** Type réel d'un fichier d'après ses premiers octets (jamais d'après le nom ni le type déclaré). */
export function detecterTypeFichier(octets) {
  const b = octets instanceof Uint8Array ? octets : new Uint8Array(octets || []);
  if (b.length >= 5 && b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46 && b[4] === 0x2d) return { mime: 'application/pdf', ext: 'pdf' };
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return { mime: 'image/jpeg', ext: 'jpg' };
  if (b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 && b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a) return { mime: 'image/png', ext: 'png' };
  return null;
}

/** fichiers : [{ nature, octets }] -> { ok, documents:[{nature, octets, mime, ext}] } ou { ok:false, erreur }. */
export function validerDocuments(fichiers, { complements = false } = {}) {
  const documents = [];
  for (const f of fichiers || []) {
    if (!NATURES.includes(f.nature)) return { ok: false, erreur: 'document_invalide' };
    const taille = f.octets?.byteLength ?? 0;
    if (taille < 1 || taille > TAILLE_MAX_FICHIER) return { ok: false, erreur: 'document_invalide' };
    const type = detecterTypeFichier(f.octets);
    if (!type) return { ok: false, erreur: 'document_invalide' };
    documents.push({ nature: f.nature, octets: f.octets, ...type });
  }
  if (!complements && !NATURES_OBLIGATOIRES.every((n) => documents.some((d) => d.nature === n))) return { ok: false, erreur: 'document_manquant' };
  if (documents.length > 6) return { ok: false, erreur: 'document_invalide' };
  return { ok: true, documents };
}

/**
 * @param entree  { champs, fichiers }  (champs : objet JSON ; fichiers : [{ nature, octets }])
 * @param ctx     { env: {CAPTCHA_PROVIDER, CAPTCHA_SECRET, SIGNING_SECRET, APP_BASE_URL}, ip, magasin, cle, fetchFn?, journal? }
 *   magasin : { mode(), deposer(chemin, octets, mime), supprimer(chemins), soumettre(payload, empreinteIp), enfiler(ligne) }
 */
export async function traiterDemande(entree, ctx) {
  const v = validerChamps(entree.champs);
  if (!v.ok) return reponseErreur(v.erreur);
  const d = validerDocuments(entree.fichiers);
  if (!d.ok) return reponseErreur(d.erreur);
  const { env, ip, magasin } = ctx;
  const mode = await magasin.mode();
  const cap = await verifierCaptcha({ fournisseur: env.CAPTCHA_PROVIDER || 'mock', secret: env.CAPTCHA_SECRET, jeton: v.valeur.captcha,
    ip, mode, fetchFn: ctx.fetchFn });
  if (!cap.ok) return reponseErreur(cap.raison === 'indisponible' ? 'captcha_indisponible' : cap.raison === 'captcha_non_configure' ? 'captcha_non_configure' : 'captcha_invalide');
  if (!env.SIGNING_SECRET) return reponseErreur('erreur_interne');

  const empreinteIp = ip ? await hmacHex(env.SIGNING_SECRET, `ip:${ip}`) : null;
  const dossier = jetonBase64url(12).replace(/[^A-Za-z0-9]/g, 'x');
  const documents = [];
  const chemins = [];
  try {
    for (const doc of d.documents) {
      const chemin = `${dossier}/${doc.nature}-${jetonBase64url(6).replace(/[^A-Za-z0-9]/g, 'x')}.${doc.ext}`;
      await magasin.deposer(chemin, doc.octets, doc.mime);
      chemins.push(chemin);
      documents.push({ nature: doc.nature, chemin_stockage: chemin, type_mime: doc.mime, taille_octets: doc.octets.byteLength });
    }
    const payload = { ...v.valeur };
    delete payload.captcha;
    const r = await magasin.soumettre({ ...payload, documents }, empreinteIp);
    if (r.erreur) { await magasin.supprimer(chemins); return reponseErreur(r.erreur === 'limite_quotidienne' ? 'limite_quotidienne' : 'erreur_interne'); }
    // Accusé de réception (email, via l'outbox). Un échec d'enfilage ne perd pas la demande.
    try {
      await ctx.accuser?.({ demandeId: r.id, email: v.valeur.email_titulaire, nomOfficine: v.valeur.nom_pharmacie });
    } catch { ctx.journal?.({ evt: 'accuse_non_enfile', demande: r.id }); }
    ctx.journal?.({ evt: 'demande_soumise', demande: r.id, doublon_suspect: r.doublon_suspect === true });
    return { status: 201, corps: { ok: true, reference: String(r.id).slice(0, 8).toUpperCase(),
      message: 'Demande reçue. Un accusé de réception vous est envoyé par email.' } };
  } catch (e) {
    if (chemins.length) { try { await magasin.supprimer(chemins); } catch { /* nettoyage au mieux */ } }
    ctx.journal?.({ evt: 'erreur_demande', erreur: e?.name || 'inconnue' });
    return reponseErreur('erreur_interne');
  }
}
