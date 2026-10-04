// Mise en file d'une notification (outbox). Appelé par le serveur (Edge Functions), jamais par un handler HTTP
// public pour un envoi direct : tout passe par l'outbox (SPEC 2 §0.3).
import { CANAUX, TYPES_DESTINATAIRE } from './canaux.js';
import { rendre } from './modeles.js';
import { chiffrer, versBytea } from './chiffrement.js';

/** Clé d'idempotence : `<cle_base>:<canal>:<modele>` (+ `:<contact>` : un message par agent de la pharmacie). */
export function cleIdempotence(cleBase, canal, modele, contactId = null) {
  return [cleBase, canal, modele, contactId].filter(Boolean).join(':');
}

/**
 * @param magasin  voir magasin-supabase.js (méthode enfiler)
 * @param cle      CryptoKey AES-GCM (chiffrement.js)
 * @param msg      { typeDestinataire, destinataireRef, canal, modele, adresse, variables, cleBase,
 *                   contactId?, estDestinataireDemo?, exempteBudget?, canauxTentes? }
 * @returns {Promise<{ cree: boolean, cleIdempotence: string }>} cree=false : déjà en file (doublon ignoré)
 */
export async function enfiler(magasin, cle, msg) {
  if (!TYPES_DESTINATAIRE.includes(msg.typeDestinataire)) throw new Error('typeDestinataire invalide');
  if (!CANAUX.includes(msg.canal)) throw new Error('canal invalide');
  if (!msg.cleBase) throw new Error('cleBase obligatoire (idempotence)');
  if (typeof msg.adresse !== 'string' || msg.adresse.trim() === '') throw new Error('adresse obligatoire');
  // Rendu à blanc : un modèle inconnu ou une variable manquante est refusé AVANT d'entrer dans la file.
  rendre(msg.modele, msg.canal, msg.variables);
  const ligne = {
    cle_idempotence: cleIdempotence(msg.cleBase, msg.canal, msg.modele, msg.contactId),
    type_destinataire: msg.typeDestinataire,
    destinataire_ref: msg.destinataireRef ?? null,
    canal: msg.canal,
    modele: msg.modele,
    adresse_chiffree: versBytea(await chiffrer(cle, msg.adresse)),
    variables: msg.variables || {},
    contact_id: msg.contactId ?? null,
    cle_base: msg.cleBase,
    canaux_tentes: msg.canauxTentes || [],
    est_destinataire_demo: msg.estDestinataireDemo === true,
    exempte_budget: msg.exempteBudget === true,
  };
  const cree = await magasin.enfiler(ligne);
  return { cree, cleIdempotence: ligne.cle_idempotence };
}
