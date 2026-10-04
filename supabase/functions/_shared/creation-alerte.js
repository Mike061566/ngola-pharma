// Création d'une alerte par le patient (SPEC 2 §3). Logique testable : l'Edge Function `creer-alerte` n'est qu'un
// adaptateur HTTP. Aucune ordonnance n'est collectée (CLAUDE.md règle 5) : tout champ hors liste blanche est refusé.
import { calculerExpiration, verifierDemarrageRoutage } from './routage.js';
import { chiffrer, versBytea } from './chiffrement.js';
import { verifierCaptcha } from './captcha.js';
import { hmacHex, sha256Hex, aleatoireBase32, jetonBase64url } from './securite.js';

const CHAMPS = ['medicament_id', 'requete', 'quartier_id', 'lat', 'lng', 'urgence', 'canal', 'telephone', 'consentement', 'captcha'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ERREURS = {
  corps_invalide: [400, 'Requête invalide.'],
  champ_inconnu: [400, 'Champ non autorisé.'],
  ordonnance_interdite: [400, 'Aucune ordonnance ne doit être envoyée : elle se présente à la pharmacie, lors de l\'achat ou du retrait.'],
  medicament_ou_requete: [400, 'Choisissez un médicament dans la liste.'],
  quartier_invalide: [400, 'Choisissez un quartier.'],
  position_invalide: [400, 'Position invalide.'],
  urgence_invalide: [400, 'Urgence invalide.'],
  canal_invalide: [400, 'Canal de retour invalide.'],
  telephone_invalide: [400, 'Numéro de téléphone invalide (ex. 6XX XX XX XX ou +237 6XX XX XX XX).'],
  telephone_inattendu: [400, 'Un numéro n\'est attendu que pour le canal SMS.'],
  consentement_requis: [400, 'Votre consentement est nécessaire pour recevoir un SMS.'],
  captcha_invalide: [403, 'Vérification anti-robot échouée. Réessayez.'],
  captcha_indisponible: [503, 'Vérification anti-robot indisponible. Réessayez dans un instant.'],
  captcha_non_configure: [503, 'Service temporairement indisponible.'],
  routage_desactive: [503, 'La recherche automatique n\'est pas disponible pour le moment.'],
  limite_quotidienne: [429, 'Trop de demandes aujourd\'hui. Réessayez demain ou rendez-vous dans une pharmacie de garde.'],
  refuse: [403, 'Demande refusée.'],
  erreur_interne: [500, 'Une erreur est survenue. Réessayez.'],
};
const reponseErreur = (code) => ({ status: ERREURS[code][0], corps: { erreur: code, message: ERREURS[code][1] } });

/** Numéro camerounais -> E.164 (+2376XXXXXXXX), ou null. Accepte espaces, points, tirets, 6XXXXXXXX, 237..., +237... */
export function normaliserTelephone(brut) {
  if (typeof brut !== 'string') return null;
  let t = brut.replace(/[\s.\-()]/g, '');
  if (t.startsWith('+237')) t = t.slice(4);
  else if (t.startsWith('00237')) t = t.slice(5);
  else if (t.startsWith('237') && t.length === 12) t = t.slice(3);
  return /^[2368]\d{8}$/.test(t) ? `+237${t}` : null;
}

/** Valide et normalise le corps de la requête. Renvoie { ok, valeur } ou { ok:false, erreur }. */
export function validerCorps(c) {
  if (!c || typeof c !== 'object' || Array.isArray(c)) return { ok: false, erreur: 'corps_invalide' };
  for (const k of Object.keys(c)) {
    if (/ordonnance|prescription|photo|image|document|scan/i.test(k)) return { ok: false, erreur: 'ordonnance_interdite' };
    if (!CHAMPS.includes(k)) return { ok: false, erreur: 'champ_inconnu' };
  }
  const medicament = c.medicament_id ?? null;
  const requete = typeof c.requete === 'string' ? c.requete.trim().replace(/\s+/g, ' ') : null;
  if (medicament !== null && (typeof medicament !== 'string' || !UUID.test(medicament))) return { ok: false, erreur: 'medicament_ou_requete' };
  if ((medicament === null) === (!requete)) return { ok: false, erreur: 'medicament_ou_requete' };   // exactement l'un des deux
  if (requete && (requete.length < 2 || requete.length > 120)) return { ok: false, erreur: 'medicament_ou_requete' };
  if (typeof c.quartier_id !== 'string' || !UUID.test(c.quartier_id)) return { ok: false, erreur: 'quartier_invalide' };
  const num = (v, min, max) => v === undefined || v === null ? null : (typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max ? v : NaN);
  const lat = num(c.lat, -90, 90), lng = num(c.lng, -180, 180);
  if (Number.isNaN(lat) || Number.isNaN(lng) || (lat === null) !== (lng === null)) return { ok: false, erreur: 'position_invalide' };
  const urgence = c.urgence ?? 'normal';
  if (urgence !== 'normal' && urgence !== 'urgent') return { ok: false, erreur: 'urgence_invalide' };
  const canal = c.canal ?? 'none';
  if (!['telegram', 'sms', 'none'].includes(canal)) return { ok: false, erreur: 'canal_invalide' };
  let telephone = null;
  if (canal === 'sms') {
    telephone = normaliserTelephone(c.telephone);
    if (!telephone) return { ok: false, erreur: 'telephone_invalide' };
    if (c.consentement !== true) return { ok: false, erreur: 'consentement_requis' };
  } else if (c.telephone !== undefined && c.telephone !== null && c.telephone !== '') {
    return { ok: false, erreur: 'telephone_inattendu' };
  }
  if (typeof c.captcha !== 'string') return { ok: false, erreur: 'captcha_invalide' };
  return { ok: true, valeur: { medicament, requete, quartier: c.quartier_id, lat, lng, urgence, canal, telephone,
    consentement: c.consentement === true, captcha: c.captcha } };
}

/**
 * @param corps  JSON de la requête
 * @param ctx    { env, ip, magasin, cle, maintenant?, fetchFn?, journal? }
 *               env : ALERT_AUTO_ROUTING, CAPTCHA_PROVIDER, CAPTCHA_SECRET, SIGNING_SECRET, TELEGRAM_BOT_USERNAME, APP_BASE_URL
 * @returns {Promise<{ status:number, corps:object }>}
 */
export async function traiterCreation(corps, ctx) {
  const { env = {}, ip = null, magasin, cle, maintenant = () => new Date(), fetchFn, journal = () => {} } = ctx;
  try {
    const config = await magasin.lireConfig();
    const mode = config.mode_application === 'production' ? 'production' : 'demo';

    // Feature flag et verrou de production : désactivé = comportement actuel (dispatch manuel par l'admin).
    const nbValidations = mode === 'production' ? await magasin.compterValidations() : 0;
    const demarrage = verifierDemarrageRoutage({ mode, routageAuto: env.ALERT_AUTO_ROUTING === 'true', nbValidationsPharmacien: nbValidations });
    if (!demarrage.actif) return reponseErreur('routage_desactive');

    const v = validerCorps(corps);
    if (!v.ok) return reponseErreur(v.erreur);
    const d = v.valeur;

    const captcha = await verifierCaptcha({ fournisseur: env.CAPTCHA_PROVIDER || 'mock', secret: env.CAPTCHA_SECRET,
      jeton: d.captcha, ip, mode, fetchFn });
    if (!captcha.ok) {
      if (captcha.raison === 'captcha_non_configure') return reponseErreur('captcha_non_configure');
      return reponseErreur(captcha.raison === 'indisponible' ? 'captcha_indisponible' : 'captcha_invalide');
    }

    // Empreintes : le numéro (si fourni) sinon l'IP, hachés (HMAC) ; l'IP seule sert aussi à la limite par IP.
    const empreinteIp = ip ? await hmacHex(env.SIGNING_SECRET, `ip:${ip}`) : null;
    const empreinte = d.telephone ? await hmacHex(env.SIGNING_SECRET, `tel:${d.telephone}`) : empreinteIp;
    if (!empreinte) return reponseErreur('erreur_interne');                // ni numéro ni IP : pas de limitation possible
    const contactChiffre = d.telephone ? versBytea(await chiffrer(cle, d.telephone)) : null;
    const maintenantD = maintenant();
    const expire = calculerExpiration({ urgence: d.urgence }, config, maintenantD);

    let res = null;
    for (let essai = 0; essai < 3 && !res; essai++) {
      try {
        res = await magasin.creerAlerte({
          p_id_public: `NG-${aleatoireBase32(8)}`, p_medicament_id: d.medicament, p_requete_brute: d.requete,
          p_quartier_id: d.quartier, p_lat: d.lat, p_lng: d.lng, p_urgence: d.urgence, p_canal_patient: d.canal,
          p_contact_chiffre: contactChiffre, p_empreinte_patient: empreinte, p_empreinte_ip: empreinteIp,
          p_consentement: d.consentement, p_expire_le: expire.toISOString() });
      } catch (e) {
        if (!String(e.message).includes('23505') || essai === 2) throw e;      // collision d'identifiant public : on retire
      }
    }
    if (res.refus) return reponseErreur(res.refus === 'limite_quotidienne' ? 'limite_quotidienne' : res.refus === 'consentement_requis' ? 'consentement_requis' : 'refuse');

    const sortie = { id_public: res.id_public, statut: res.statut, fusionnee: res.fusionnee === true,
      lien_suivi: `${String(env.APP_BASE_URL || 'https://ngola-pharma.com').replace(/\/+$/, '')}/alerte/${res.id_public}` };
    // Telegram : lien profond à usage unique (jeton stocké haché). Le chat_id est enregistré au /start (PR 5).
    if (d.canal === 'telegram' && !res.fusionnee && env.TELEGRAM_BOT_USERNAME) {
      const jeton = jetonBase64url(32);
      const heures = Number(config.jeton_telegram_patient_h) > 0 ? Number(config.jeton_telegram_patient_h) : 72;
      await magasin.creerJetonTelegram({ jeton_hash: await sha256Hex(jeton), objet: 'patient_alert', ref_id: res.alerte_id,
        expire_le: new Date(maintenantD.getTime() + heures * 3600000).toISOString() });
      sortie.lien_telegram = `https://t.me/${env.TELEGRAM_BOT_USERNAME}?start=${jeton}`;
    }
    journal({ evt: 'alerte_creee', statut: res.statut, fusionnee: sortie.fusionnee });   // ni numéro, ni IP, ni médicament
    return { status: res.fusionnee ? 200 : 201, corps: sortie };
  } catch (e) {
    journal({ evt: 'erreur_creation', erreur: e?.name || 'inconnue' });
    return reponseErreur('erreur_interne');
  }
}
