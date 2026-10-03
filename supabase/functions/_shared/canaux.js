// Canaux de messagerie et repli (SPEC 2 §6). Aucune dépendance : importable par Deno (Edge Functions) et par Node (tests).
import { MODELES } from './modeles.js';

/** Ordre de repli pour une pharmacie : Telegram, puis SMS, puis email. */
export const CANAUX = ['telegram', 'sms', 'email'];
export const TYPES_DESTINATAIRE = ['pharmacy', 'patient', 'admin'];
export const CANAUX_PAYANTS = ['sms', 'email'];

// Modèles « frères » d'un même message, un par canal (la spec nomme les variantes SMS et email à part).
const FAMILLES = {
  alerte_demande: { telegram: 'alerte_demande', sms: 'alerte_demande_sms', email: 'alerte_demande_email' },
  reponse_patient: { telegram: 'reponse_patient', sms: 'reponse_patient_sms' },
};

/** Modèle à utiliser sur `canal` pour le même message que `modele`, ou null s'il n'existe pas sur ce canal. */
export function modeleDeRepli(modele, canal) {
  const def = MODELES[modele];
  if (def && def.canaux[canal]) return modele;
  for (const famille of Object.values(FAMILLES)) {
    if (Object.values(famille).includes(modele)) {
      const cible = famille[canal];
      return cible && MODELES[cible] && MODELES[cible].canaux[canal] ? cible : null;
    }
  }
  return null;
}
