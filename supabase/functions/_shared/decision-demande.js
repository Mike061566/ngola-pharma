// Décisions de la console admin sur une demande (SPEC 1 §4) : approuver, refuser, demander des compléments, renvoyer l'invitation.
// Le contrôle « admin » est fait ICI (jeton Supabase vérifié côté serveur) ET en base (decider_demande_interne).
// Tous les messages passent par l'outbox. En mode démo, les liens sont aussi renvoyés à l'admin (l'email du candidat
// n'est jamais envoyé réellement à un tiers hors liste blanche) ; en production, jamais.
import { enfiler } from './file-sortie.js';
import { sha256Hex, jetonBase64url } from './securite.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const VALIDITE_ACTIVATION_H = 72;
export const VALIDITE_COMPLEMENTS_J = 14;
const DECISIONS = ['approve', 'reject', 'request_info', 'resend_invite'];

export const baseUrl = (env) => String(env.APP_BASE_URL || 'https://ngola-pharma.com').replace(/\/+$/, '');

/** Erreurs métier levées par la base -> réponse HTTP claire (le détail brut n'est jamais renvoyé ni journalisé). */
function erreurMetier(e) {
  if (e?.code === '42501') return { status: 403, corps: { erreur: 'refuse' } };
  if (e?.code === '22023') return { status: 400, corps: { erreur: 'motif_obligatoire' } };
  if (e?.code === '55000') return { status: 409, corps: { erreur: /Checklist/.test(e.detail || '') ? 'checklist_incomplete' : 'etat_invalide' } };
  if (e?.code === 'P0002') return { status: 404, corps: { erreur: 'introuvable' } };
  return null;
}

/** @returns {Promise<{status:number, corps:object}>} */
export async function deciderDemande({ jwt, corps }, { magasin, env, cle, journal }) {
  const user = jwt ? await magasin.utilisateurDuJeton(jwt) : null;
  if (!user || !(await magasin.estAdmin(user.id))) return { status: 403, corps: { erreur: 'refuse' } };
  if (!corps || typeof corps !== 'object' || !UUID.test(corps.demande_id || '') || !DECISIONS.includes(corps.decision)) {
    return { status: 400, corps: { erreur: 'requete_invalide' } };
  }
  const motif = typeof corps.motif === 'string' ? corps.motif.trim().slice(0, 1000) : '';
  const id = corps.demande_id;
  const demande = await magasin.lireDemande(id);
  if (!demande) return { status: 404, corps: { erreur: 'introuvable' } };
  const demo = (await magasin.mode()) === 'demo';
  const sortie = { ok: true };

  const envoyer = (modele, variables, suffixe) => enfiler(magasin, cle, {
    typeDestinataire: 'pharmacy', destinataireRef: null, canal: 'email', modele, adresse: demande.email_titulaire,
    variables: { nom_officine: demande.nom_pharmacie, ...variables }, cleBase: `onboarding:${id}:${modele}:${suffixe}` });

  async function inviter() {
    const jeton = jetonBase64url(32);
    const hash = await sha256Hex(jeton);
    await magasin.creerJetonActivation(id, hash, VALIDITE_ACTIVATION_H);
    const lien = `${baseUrl(env)}/activer.html#t=${jeton}`;
    await envoyer('onboarding_approuve', { lien, validite_h: VALIDITE_ACTIVATION_H }, hash.slice(0, 12));
    await magasin.marquerInvitation(id, false, true);
    if (demo) sortie.lien_activation = lien;
  }

  try {
    if (corps.decision === 'resend_invite') {
      if (demande.statut !== 'approved') return { status: 409, corps: { erreur: 'etat_invalide' } };
      await inviter();
    } else {
      const r = await magasin.decider(id, corps.decision, motif, user.id);
      if (corps.decision === 'approve') { sortie.pharmacie_id = r.pharmacie_id; await inviter(); }
      else if (corps.decision === 'reject') await envoyer('onboarding_refuse', { motif }, 'refus');
      else {
        const jeton = jetonBase64url(24);
        await magasin.definirJetonComplements(id, await sha256Hex(jeton), new Date(Date.now() + VALIDITE_COMPLEMENTS_J * 86400000).toISOString());
        const lien = `${baseUrl(env)}/complements.html#t=${jeton}`;
        await envoyer('onboarding_complements', { motif, lien }, (await sha256Hex(jeton)).slice(0, 12));
        if (demo) sortie.lien_complements = lien;
      }
    }
    journal?.({ evt: 'demande_decidee', demande: id, decision: corps.decision });
    return { status: 200, corps: sortie };
  } catch (e) {
    const metier = erreurMetier(e);
    journal?.({ evt: 'erreur_decision', code: e?.code || null, erreur: e?.name || 'inconnue' });
    return metier || { status: 500, corps: { erreur: 'erreur_interne' } };
  }
}
