// Sélection des fournisseurs par variables d'environnement : TELEGRAM_PROVIDER, SMS_PROVIDER, EMAIL_PROVIDER.
// Défaut : `mock` (aucun envoi réel). Telegram réel (PR 7) : TELEGRAM_PROVIDER=telegram + TELEGRAM_BOT_TOKEN.
// SMS et email réels : à brancher quand les fournisseurs seront choisis. Toute valeur inconnue est REFUSÉE
// (on n'ignore jamais silencieusement une configuration d'envoi).
import { creerFournisseurMock } from './fournisseur-mock.js';
import { creerFournisseurTelegram } from './fournisseur-telegram.js';
import { CANAUX } from './canaux.js';

const REGISTRE = {
  mock: { telegram: creerFournisseurMock, sms: creerFournisseurMock, email: creerFournisseurMock },
  telegram: { telegram: (canal, o, env) => creerFournisseurTelegram({ jeton: env.TELEGRAM_BOT_TOKEN, fetchImpl: o.fetchImpl }) },
};

export function creerFournisseurs(env = {}, options = {}) {
  const sortie = {};
  for (const canal of CANAUX) {
    const nom = String(env[`${canal.toUpperCase()}_PROVIDER`] || 'mock').toLowerCase();
    const fabrique = REGISTRE[nom]?.[canal];
    if (!fabrique) {
      throw new Error(`${canal.toUpperCase()}_PROVIDER=${nom} : fournisseur indisponible pour ce canal (disponibles : mock, telegram pour Telegram)`);
    }
    sortie[canal] = fabrique(canal, options, env);
  }
  return sortie;
}
