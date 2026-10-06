// Rappels d'onboarding J+1 / J+3 / J+7 et alerte « dormante » (SPEC 1 §5.3). Planification pure (`planifierRappels`) + exécution
// (`executerRappels`) : l'Edge Function `rappels-onboarding` n'est qu'un adaptateur HTTP appelé une fois par jour par pg_cron.
// Chaque message passe par l'outbox avec une clé d'idempotence `rappel:<pharmacie>:<jalon>` : un rappel n'est jamais envoyé deux fois,
// même si l'exécution est relancée. Aucune suppression, aucun envoi direct.
import { enfiler } from './file-sortie.js';
import { sha256Hex, jetonBase64url } from './securite.js';
import { baseUrl, VALIDITE_ACTIVATION_H } from './decision-demande.js';

export const JALONS = [1, 3, 7];
export const JALON_DORMANTE = 30;
const ETAPES = {
  activation: 'activer votre compte',
  mot_de_passe: 'définir votre mot de passe',
  ma_pharmacie: 'compléter « Ma Pharmacie » (horaires et position)',
  telegram: 'activer Telegram',
  import: 'importer vos stocks',
  confirmation: 'confirmer vos stocks',
  seuil: 'confirmer assez de médicaments pour être publiée',
};
export const libelleEtape = (cle) => ETAPES[cle] || ETAPES.seuil;

/**
 * @param candidats  sortie de candidats_rappels_interne() : [{ pharmacie_id, jours, deja:[jalons], compte_actif, etape, ... }]
 * @returns { rappels:[{ candidat, jalon, sauter:[jalons] }], dormantes:[candidat] }
 *   - jusqu'à J+29 : le plus grand jalon échu et non envoyé est envoyé ; les jalons plus anciens non envoyés sont « sautés » (exécution tardive) ;
 *   - à partir de J+30 : plus de rappel, une seule alerte « dormante » à l'admin (jalon 30).
 */
export function planifierRappels(candidats) {
  const rappels = [], dormantes = [];
  for (const c of candidats || []) {
    const deja = new Set((c.deja || []).map(Number));
    if (c.jours >= JALON_DORMANTE) { if (!deja.has(JALON_DORMANTE)) dormantes.push(c); continue; }
    const dus = JALONS.filter((j) => c.jours >= j && !deja.has(j));
    if (!dus.length) continue;
    const jalon = Math.max(...dus);
    rappels.push({ candidat: c, jalon, sauter: dus.filter((j) => j !== jalon) });
  }
  return { rappels, dormantes };
}

/** Lien direct vers l'étape bloquante : activation (nouveau jeton 72 h) tant que le compte n'existe pas, sinon Espace Pro à l'étape. */
async function lienEtape(c, { magasin, env }) {
  if (!c.compte_actif) {
    const jeton = jetonBase64url(32);
    await magasin.creerJetonActivation(c.demande_id, await sha256Hex(jeton), VALIDITE_ACTIVATION_H);
    return { etape: 'activation', lien: `${baseUrl(env)}/activer.html#t=${jeton}` };
  }
  return { etape: c.etape, lien: `${baseUrl(env)}/pro.html?etape=${encodeURIComponent(c.etape)}` };
}

/**
 * @param ctx  { magasin, env: { APP_BASE_URL, ADMIN_ALERT_EMAIL }, cle, journal? }
 *   magasin : candidatsRappels(), enregistrerRappel(pharmacieId, jalon, canaux), contactsPharmacies(ids), creerJetonActivation(...), enfiler(ligne)
 */
export async function executerRappels({ magasin, env, cle, journal }) {
  const resume = { rappels: 0, sautes: 0, dormantes: 0, emails: 0, telegram: 0, erreurs: 0 };
  const { rappels, dormantes } = planifierRappels(await magasin.candidatsRappels());
  const contacts = rappels.length ? await magasin.contactsPharmacies(rappels.map((r) => r.candidat.pharmacie_id)) : [];

  for (const { candidat: c, jalon, sauter } of rappels) {
    try {
      const { etape, lien } = await lienEtape(c, { magasin, env });
      const variables = { nom_officine: c.nom, etape_libelle: libelleEtape(etape), lien, jours: String(c.jours) };
      const canaux = [];
      const email = await enfiler(magasin, cle, { typeDestinataire: 'pharmacy', destinataireRef: null, canal: 'email', modele: 'onboarding_rappel',
        adresse: c.email, variables, cleBase: `rappel:${c.pharmacie_id}:${jalon}` });
      canaux.push('email'); if (email.cree) resume.emails += 1;
      // Telegram : seulement les contacts activés (/start reçu), non bloqués, non désabonnés, et seulement si le compte est actif :
      // le lien d'activation (personnel, à usage unique) ne part JAMAIS sur Telegram.
      const aTelegram = c.compte_actif ? contacts.filter((x) => x.pharmacie_id === c.pharmacie_id && x.canal === 'telegram' && x.verifie_le && !x.desabonne_le && !x.bloque_le) : [];
      for (const k of aTelegram) {
        const t = await enfiler(magasin, cle, { typeDestinataire: 'pharmacy', destinataireRef: c.pharmacie_id, canal: 'telegram', modele: 'onboarding_rappel',
          adresse: k.adresse, variables, cleBase: `rappel:${c.pharmacie_id}:${jalon}`, contactId: k.id, estDestinataireDemo: k.est_contact_demo === true });
        if (t.cree) resume.telegram += 1;
        if (!canaux.includes('telegram')) canaux.push('telegram');
      }
      await magasin.enregistrerRappel(c.pharmacie_id, jalon, canaux);
      for (const j of sauter) await magasin.enregistrerRappel(c.pharmacie_id, j, []);
      resume.rappels += 1; resume.sautes += sauter.length;
    } catch (e) {
      resume.erreurs += 1;
      journal?.({ evt: 'erreur_rappel', pharmacie: c.pharmacie_id, jalon, erreur: e?.name || 'inconnue' });   // jamais l'adresse ni le contenu
    }
  }

  for (const c of dormantes) {
    if (!env.ADMIN_ALERT_EMAIL) continue;      // pas d'adresse admin : on réessaiera quand elle sera configurée (rien n'est enregistré)
    try {
      await enfiler(magasin, cle, { typeDestinataire: 'admin', destinataireRef: null, canal: 'email', modele: 'onboarding_dormante_admin',
        adresse: env.ADMIN_ALERT_EMAIL, variables: { nom_officine: c.nom, jours: String(c.jours), etape_libelle: libelleEtape(c.compte_actif ? c.etape : 'activation'),
          lien: `${baseUrl(env)}/pro.html` }, cleBase: `rappel:${c.pharmacie_id}:${JALON_DORMANTE}` });
      await magasin.enregistrerRappel(c.pharmacie_id, JALON_DORMANTE, ['email']);
      resume.dormantes += 1;
    } catch (e) {
      resume.erreurs += 1;
      journal?.({ evt: 'erreur_dormante', pharmacie: c.pharmacie_id, erreur: e?.name || 'inconnue' });
    }
  }
  journal?.({ evt: 'rappels_onboarding', ...resume });
  return resume;
}
