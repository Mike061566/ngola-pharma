// Invitation d'une pharmacie DÉJÀ référencée et vérifiée (créée en masse) à activer son compte. Même mécanique que l'approbation d'une demande :
// jeton à usage unique (72 h, seul son hachage est stocké) envoyé par email au titulaire via l'outbox. Réservé à l'admin (jeton vérifié côté
// serveur ET rôle contrôlé en base). En mode démo, le lien est aussi renvoyé à l'admin (aucun email réel ne part vers un tiers) ; jamais en production.
import { enfiler } from './file-sortie.js';
import { sha256Hex, jetonBase64url } from './securite.js';
import { baseUrl, VALIDITE_ACTIVATION_H } from './decision-demande.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function erreurMetier(e) {
  if (e?.code === '42501') return { status: 403, corps: { erreur: 'refuse' } };
  if (e?.code === 'P0002') return { status: 404, corps: { erreur: 'introuvable' } };
  if (e?.code === '55000') return { status: 409, corps: { erreur: /vérifi/.test(e.detail || '') ? 'pharmacie_non_verifiee' : 'email_inconnu' } };
  return null;
}

export async function inviterPharmacie({ jwt, corps }, { magasin, env, cle, journal }) {
  const user = jwt ? await magasin.utilisateurDuJeton(jwt) : null;
  if (!user || !(await magasin.estAdmin(user.id))) return { status: 403, corps: { erreur: 'refuse' } };
  if (!corps || typeof corps !== 'object' || !UUID.test(corps.pharmacie_id || '')) return { status: 400, corps: { erreur: 'requete_invalide' } };
  try {
    const jeton = jetonBase64url(32);
    const hash = await sha256Hex(jeton);
    const r = await magasin.inviterPharmacie(corps.pharmacie_id, user.id, hash, VALIDITE_ACTIVATION_H);
    const lien = `${baseUrl(env)}/activer.html#t=${jeton}`;
    await enfiler(magasin, cle, { typeDestinataire: 'pharmacy', destinataireRef: null, canal: 'email', modele: 'onboarding_invitation', adresse: r.email,
      variables: { nom_officine: r.nom, lien, validite_h: VALIDITE_ACTIVATION_H }, cleBase: `onboarding:pharmacie:${corps.pharmacie_id}:invitation:${hash.slice(0, 12)}` });
    journal?.({ evt: 'pharmacie_invitee', pharmacie: corps.pharmacie_id });
    const sortie = { ok: true };
    if ((await magasin.mode()) === 'demo') sortie.lien_activation = lien;
    return { status: 200, corps: sortie };
  } catch (e) {
    journal?.({ evt: 'erreur_invitation', code: e?.code || null, erreur: e?.name || 'inconnue' });
    return erreurMetier(e) || { status: 500, corps: { erreur: 'erreur_interne' } };
  }
}
