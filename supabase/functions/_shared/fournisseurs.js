// Sélection des fournisseurs par variables d'environnement : TELEGRAM_PROVIDER, SMS_PROVIDER, EMAIL_PROVIDER.
// Défaut : `mock` (aucun envoi réel). Telegram réel (PR 7) : TELEGRAM_PROVIDER=telegram + TELEGRAM_BOT_TOKEN.
// Email réel : EMAIL_PROVIDER=zeptomail + ZEPTOMAIL_TOKEN + EMAIL_FROM_ADDRESS. SMS réel (Orange) : à brancher après confirmation de la couverture. Toute valeur inconnue est REFUSÉE
// (on n'ignore jamais silencieusement une configuration d'envoi).
import { creerFournisseurMock } from './fournisseur-mock.js';
import { creerFournisseurZeptoMail } from './fournisseur-zeptomail.js';
import { creerFournisseurTelegram } from './fournisseur-telegram.js';
import { CANAUX } from './canaux.js';

const REGISTRE = {
  mock: { telegram: creerFournisseurMock, sms: creerFournisseurMock, email: creerFournisseurMock },
  zeptomail: { email: (canal, o, env) => creerFournisseurZeptoMail({ jeton: env.ZEPTOMAIL_TOKEN, adresseExpediteur: env.EMAIL_FROM_ADDRESS,
    nomExpediteur: env.EMAIL_FROM_NAME || undefined, hote: env.ZEPTOMAIL_HOST || undefined, fetchImpl: o.fetchImpl }) },
  telegram: { telegram: (canal, o, env) => creerFournisseurTelegram({ jeton: env.TELEGRAM_BOT_TOKEN, fetchImpl: o.fetchImpl }) },
};

export function creerFournisseurs(env = {}, options = {}) {
  const sortie = {};
  for (const canal of CANAUX) {
    const nom = String(env[`${canal.toUpperCase()}_PROVIDER`] || 'mock').toLowerCase();
    const fabrique = REGISTRE[nom]?.[canal];
    if (!fabrique) {
      throw new Error(`${canal.toUpperCase()}_PROVIDER=${nom} : fournisseur indisponible pour ce canal (disponibles : mock ; telegram pour Telegram ; zeptomail pour l'email)`);
    }
    sortie[canal] = fabrique(canal, options, env);
  }
  return sortie;
}
