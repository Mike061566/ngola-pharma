// Sélection des fournisseurs par variables d'environnement : TELEGRAM_PROVIDER, SMS_PROVIDER, EMAIL_PROVIDER.
// Défaut : `mock` (aucun envoi réel). Les fournisseurs réels arrivent en PR 7 : tant qu'ils n'existent pas, toute
// autre valeur est REFUSÉE (on n'ignore jamais silencieusement une configuration d'envoi).
import { creerFournisseurMock } from './fournisseur-mock.js';
import { CANAUX } from './canaux.js';

const REGISTRE = { mock: creerFournisseurMock };

export function creerFournisseurs(env = {}, options = {}) {
  const sortie = {};
  for (const canal of CANAUX) {
    const nom = String(env[`${canal.toUpperCase()}_PROVIDER`] || 'mock').toLowerCase();
    const fabrique = REGISTRE[nom];
    if (!fabrique) {
      throw new Error(`${canal.toUpperCase()}_PROVIDER=${nom} : fournisseur indisponible (seul « mock » existe avant la PR 7)`);
    }
    sortie[canal] = fabrique(canal, options);
  }
  return sortie;
}
