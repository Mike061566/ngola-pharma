import test from 'node:test';
import assert from 'node:assert/strict';
import { creerFournisseurTelegram } from '../../supabase/functions/_shared/fournisseur-telegram.js';
import { creerFournisseurs } from '../../supabase/functions/_shared/fournisseurs.js';

const rep = (status, corps) => ({ ok: status < 300, status, json: async () => corps });
function faux(reponse) {
  const appels = [];
  const f = async (url, init) => { appels.push({ url, corps: JSON.parse(init.body) }); if (reponse instanceof Error) throw reponse; return typeof reponse === 'function' ? reponse(appels.length) : reponse; };
  return { f, appels };
}

test('envoyer : sendMessage HTML avec clavier, renvoie les identifiants', async () => {
  const { f, appels } = faux(rep(200, { ok: true, result: { message_id: 42, chat: { id: 777 } } }));
  const p = creerFournisseurTelegram({ jeton: 'JETON', fetchImpl: f });
  const r = await p.envoyer({ adresse: '777', texte: '<b>x</b>', format: 'html',
    boutons: [[{ texte: 'Oui', donnees: 'r:e1:a' }, { texte: 'Prix', url: 'https://x.test/r/A' }]] });
  assert.deepEqual(r, { idMessage: '42', idDiscussion: '777' });
  assert.match(appels[0].url, /\/botJETON\/sendMessage$/);
  assert.equal(appels[0].corps.parse_mode, 'HTML');
  assert.deepEqual(appels[0].corps.reply_markup.inline_keyboard[0][0], { text: 'Oui', callback_data: 'r:e1:a' });
  assert.deepEqual(appels[0].corps.reply_markup.inline_keyboard[0][1], { text: 'Prix', url: 'https://x.test/r/A' });
});

test('429 -> limite_debit avec retry_after', async () => {
  const { f } = faux(rep(429, { ok: false, error_code: 429, parameters: { retry_after: 9 } }));
  await assert.rejects(creerFournisseurTelegram({ jeton: 'J', fetchImpl: f }).envoyer({ adresse: '1', texte: 't' }),
    (e) => e.type === 'limite_debit' && e.retryApresS === 9);
});

test('403 et chat introuvable -> permanente + bloque', async () => {
  for (const [code, d] of [[403, 'Forbidden: bot was blocked by the user'], [400, 'Bad Request: chat not found']]) {
    const { f } = faux(rep(code, { ok: false, error_code: code, description: d }));
    await assert.rejects(creerFournisseurTelegram({ jeton: 'J', fetchImpl: f }).envoyer({ adresse: '1', texte: 't' }),
      (e) => e.type === 'permanente' && e.bloque === true);
  }
});

test('5xx et réseau -> transitoire ; autre 4xx -> permanente sans blocage', async () => {
  let { f } = faux(rep(502, { ok: false, error_code: 502 }));
  await assert.rejects(creerFournisseurTelegram({ jeton: 'J', fetchImpl: f }).envoyer({ adresse: '1', texte: 't' }), (e) => e.type === 'transitoire');
  ({ f } = faux(new Error('ECONNRESET')));
  await assert.rejects(creerFournisseurTelegram({ jeton: 'J', fetchImpl: f }).envoyer({ adresse: '1', texte: 't' }), (e) => e.type === 'transitoire');
  ({ f } = faux(rep(400, { ok: false, error_code: 400, description: 'Bad Request: can\'t parse entities' })));
  await assert.rejects(creerFournisseurTelegram({ jeton: 'J', fetchImpl: f }).envoyer({ adresse: '1', texte: 't' }), (e) => e.type === 'permanente' && !e.bloque);
});

test('le jeton, l\'adresse et le texte n\'apparaissent jamais dans les messages d\'erreur', async () => {
  const { f } = faux(rep(403, { ok: false, error_code: 403, description: 'Forbidden' }));
  try { await creerFournisseurTelegram({ jeton: 'SECRET-JETON', fetchImpl: f }).envoyer({ adresse: '5551234', texte: 'contenu privé' }); assert.fail(); }
  catch (e) { assert.doesNotMatch(e.message, /SECRET-JETON|5551234|contenu privé/); }
});

test('modifierMessage retire les boutons ; repondreCallback acquitte', async () => {
  const { f, appels } = faux(rep(200, { ok: true, result: true }));
  const p = creerFournisseurTelegram({ jeton: 'J', fetchImpl: f });
  await p.modifierMessage({ idDiscussion: '7', idMessage: '42', texte: 'Merci' });
  await p.repondreCallback({ idCallback: 'cb1', texte: 'Enregistré' });
  assert.match(appels[0].url, /editMessageText$/);
  assert.deepEqual(appels[0].corps.reply_markup, { inline_keyboard: [] });
  assert.equal(appels[0].corps.message_id, 42);
  assert.match(appels[1].url, /answerCallbackQuery$/);
});

test('sélection : mock par défaut, telegram exige un jeton, sms/email réels refusés', () => {
  assert.equal(creerFournisseurs({}).telegram.mock, true);
  assert.throws(() => creerFournisseurs({ TELEGRAM_PROVIDER: 'telegram' }), /TELEGRAM_BOT_TOKEN/);
  const p = creerFournisseurs({ TELEGRAM_PROVIDER: 'telegram', TELEGRAM_BOT_TOKEN: 'J' });
  assert.equal(p.telegram.mock, false); assert.equal(p.sms.mock, true);
  assert.throws(() => creerFournisseurs({ SMS_PROVIDER: 'telegram' }), /indisponible/);
  assert.throws(() => creerFournisseurs({ EMAIL_PROVIDER: 'resend' }), /indisponible/);
});
