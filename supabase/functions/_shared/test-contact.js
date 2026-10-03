// Test d'envoi demandé par un pharmacien depuis l'Espace Pro (SPEC 2 §10) : un message de test part vers UN de ses contacts,
// via l'outbox (liste blanche de la démo, budget et repli appliqués par le worker). Limité à 1 test par minute et par contact.
import { enfiler } from './file-sortie.js';

/** @returns {{status:number, corps:object}} */
export async function traiterTestContact({ contactId, utilisateurId }, { magasin, cle, maintenant = () => new Date() }) {
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (typeof contactId !== 'string' || !UUID.test(contactId)) return { status: 400, corps: { erreur: 'contact_invalide' } };
  const profil = utilisateurId ? await magasin.lireProfil(utilisateurId) : null;
  if (!profil || profil.role !== 'pharmacien' || !profil.pharmacie_id) return { status: 403, corps: { erreur: 'refuse' } };
  const c = await magasin.lireContactPharmacie(contactId);
  if (!c || c.pharmacie_id !== profil.pharmacie_id) return { status: 404, corps: { erreur: 'introuvable' } };   // jamais le contact d'une autre pharmacie
  if (c.desabonne_le || c.bloque_le) return { status: 409, corps: { erreur: 'contact_inactif' } };
  if (c.canal === 'telegram' && !c.verifie_le) return { status: 409, corps: { erreur: 'telegram_non_active' } };
  const minute = Math.floor(maintenant().getTime() / 60000);
  const r = await enfiler(magasin, cle, { typeDestinataire: 'pharmacy', destinataireRef: c.pharmacie_id, canal: c.canal, modele: 'test_envoi', adresse: c.adresse,
    variables: {}, cleBase: `test:${c.id}:${minute}`, contactId: c.id, estDestinataireDemo: c.est_contact_demo === true });
  return r.cree ? { status: 202, corps: { statut: 'en_file' } } : { status: 429, corps: { erreur: 'trop_frequent' } };
}
