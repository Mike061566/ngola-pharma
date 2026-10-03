// Fournisseur « mock/console » : aucun envoi réel, aucun réseau. Défaut en développement et en test (CLAUDE.md règle 3).
//
// Interface commune d'un fournisseur de canal (ChannelProvider, SPEC 2 §0.4) :
//   canal : 'telegram' | 'sms' | 'email'
//   async envoyer({ adresse, texte, format, sujet, boutons, cleIdempotence, idOutbox })
//        -> { idMessage, idDiscussion }          (lève ErreurFournisseur en cas d'échec)
// Le fournisseur Telegram ajoute :
//   async modifierMessage({ idDiscussion, idMessage, texte, boutons })   (editMessageText, PR 5)
//
// Journal : seulement l'identifiant d'outbox, le canal et le modèle. Jamais l'adresse ni le contenu.
//
// Pour essayer les cas d'échec à la main, l'adresse peut commencer par :
//   mock-echec-transitoire | mock-echec-permanent | mock-bloque | mock-limite
import { ErreurFournisseur } from './erreurs.js';

export function creerFournisseurMock(canal, { journal = null, comportement = null } = {}) {
  let n = 0;
  const envoyes = [];      // en mémoire uniquement (tests) : jamais journalisé
  const modifies = [];
  return {
    canal,
    mock: true,
    envoyes,
    modifies,
    async envoyer(msg) {
      if (typeof comportement === 'function') await comportement(msg);
      const a = String(msg.adresse || '');
      if (a.startsWith('mock-echec-transitoire')) throw new ErreurFournisseur('mock : échec transitoire', { type: 'transitoire' });
      if (a.startsWith('mock-echec-permanent')) throw new ErreurFournisseur('mock : échec permanent', { type: 'permanente' });
      if (a.startsWith('mock-bloque')) throw new ErreurFournisseur('mock : contact bloqué', { type: 'permanente', bloque: true });
      if (a.startsWith('mock-limite')) throw new ErreurFournisseur('mock : limite de débit', { type: 'limite_debit', retryApresS: 2 });
      n += 1;
      envoyes.push(msg);
      if (journal) journal({ fournisseur: 'mock', canal, idOutbox: msg.idOutbox ?? null, modele: msg.modele ?? null });
      return { idMessage: `mock-${canal}-${n}`, idDiscussion: canal === 'telegram' ? a : null };
    },
    async modifierMessage(args) {
      if (canal !== 'telegram') throw new ErreurFournisseur('modifierMessage : Telegram seulement', { type: 'permanente' });
      modifies.push(args);
      if (journal) journal({ fournisseur: 'mock', canal, action: 'modifierMessage' });
      return { ok: true };
    },
  };
}
