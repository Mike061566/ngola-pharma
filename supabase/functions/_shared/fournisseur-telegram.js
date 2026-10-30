// Fournisseur Telegram réel (Bot API). Jamais utilisé en dev/test : les tests injectent un `fetch` factice.
// Le jeton vient de TELEGRAM_BOT_TOKEN (variable d'environnement) ; il n'apparaît dans aucun message d'erreur ni journal.
// Correspondance des erreurs : 429 -> limite_debit (retry_after) ; 403 (bot bloqué) / 400 « chat not found » -> permanente + bloque ;
// autre 4xx -> permanente ; 5xx / réseau -> transitoire.
import { ErreurFournisseur } from './erreurs.js';

const ORIGINE = 'https://api.telegram.org';

function clavier(boutons) {
  if (!boutons?.length) return undefined;
  return {
    inline_keyboard: boutons.map((ligne) => ligne.map((b) => (b.url
      ? { text: b.texte, url: b.url }
      : { text: b.texte, callback_data: b.donnees }))),
  };
}

export function creerFournisseurTelegram({ jeton, fetchImpl = globalThis.fetch, delaiMs = 10000 } = {}) {
  if (!jeton) throw new Error('TELEGRAM_BOT_TOKEN manquant');

  async function appeler(methode, corps) {
    let reponse;
    try {
      reponse = await fetchImpl(`${ORIGINE}/bot${jeton}/${methode}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(corps),
        signal: typeof AbortSignal?.timeout === 'function' ? AbortSignal.timeout(delaiMs) : undefined,
      });
    } catch {
      throw new ErreurFournisseur(`telegram ${methode} : réseau`, { type: 'transitoire' });
    }
    let json = null;
    try { json = await reponse.json(); } catch { /* corps non JSON */ }
    if (reponse.ok && json?.ok) return json.result;
    const code = json?.error_code ?? reponse.status;
    const description = String(json?.description || '').toLowerCase();
    if (code === 429) {
      throw new ErreurFournisseur('telegram : limite de débit', {
        type: 'limite_debit', retryApresS: Number(json?.parameters?.retry_after) || 5,
      });
    }
    if (code === 403 || (code === 400 && /chat not found|user is deactivated/.test(description))) {
      throw new ErreurFournisseur(`telegram ${methode} : destinataire injoignable (${code})`, { type: 'permanente', bloque: true });
    }
    if (code >= 500 || !code) throw new ErreurFournisseur(`telegram ${methode} : erreur ${code || 'inconnue'}`, { type: 'transitoire' });
    throw new ErreurFournisseur(`telegram ${methode} : refus ${code}`, { type: 'permanente' });
  }

  return {
    canal: 'telegram',
    mock: false,
    async envoyer({ adresse, texte, format, boutons }) {
      const r = await appeler('sendMessage', {
        chat_id: adresse,
        text: texte,
        ...(format === 'html' ? { parse_mode: 'HTML' } : {}),
        disable_web_page_preview: true,
        reply_markup: clavier(boutons),
      });
      return { idMessage: String(r.message_id), idDiscussion: String(r.chat?.id ?? adresse) };
    },
    async modifierMessage({ idDiscussion, idMessage, texte, boutons, format = 'html' }) {
      await appeler('editMessageText', {
        chat_id: idDiscussion,
        message_id: Number(idMessage),
        text: texte,
        ...(format === 'html' ? { parse_mode: 'HTML' } : {}),
        reply_markup: clavier(boutons) ?? { inline_keyboard: [] },
      });
      return { ok: true };
    },
    async repondreCallback({ idCallback, texte }) {
      await appeler('answerCallbackQuery', { callback_query_id: idCallback, text: texte });
      return { ok: true };
    },
  };
}
