import test from 'node:test';
import assert from 'node:assert/strict';
import { creerFournisseurZeptoMail } from '../../supabase/functions/_shared/fournisseur-zeptomail.js';
import { creerFournisseurs } from '../../supabase/functions/_shared/fournisseurs.js';

const rep = (status, corps, entetes = {}) => ({ status, json: async () => corps, headers: { get: (k) => entetes[k.toLowerCase()] ?? null } });
const faux = (r) => { const appels = []; return { appels, f: async (url, init) => { appels.push({ url, init, corps: JSON.parse(init.body) }); if (r instanceof Error) throw r; return r; } }; };
const base = { jeton: 'TOKEN', adresseExpediteur: 'alertes@exemple.test' };
const msg = { adresse: 'pharma@exemple.test', sujet: 'Sujet', texte: 'Corps', cleIdempotence: 'k:email:alerte' };

test('envoi : endpoint, autorisation préfixée, corps texte, référence client', async () => {
  const { f, appels } = faux(rep(201, { request_id: 'req-1' }));
  const r = await creerFournisseurZeptoMail({ ...base, fetchImpl: f }).envoyer(msg);
  assert.deepEqual(r, { idMessage: 'req-1', idDiscussion: null });
  assert.equal(appels[0].url, 'https://api.zeptomail.com/v1.1/email');
  assert.equal(appels[0].init.headers.authorization, 'Zoho-enczapikey TOKEN');
  assert.equal(appels[0].corps.to[0].email_address.address, 'pharma@exemple.test');
  assert.equal(appels[0].corps.subject, 'Sujet'); assert.equal(appels[0].corps.textbody, 'Corps');
  assert.equal(appels[0].corps.client_reference, 'k:email:alerte');
});

test('jeton déjà préfixé non doublé ; hôte régional', async () => {
  const { f, appels } = faux(rep(201, { request_id: 'r' }));
  await creerFournisseurZeptoMail({ ...base, jeton: 'Zoho-enczapikey ABC', hote: 'api.zeptomail.eu', fetchImpl: f }).envoyer(msg);
  assert.equal(appels[0].init.headers.authorization, 'Zoho-enczapikey ABC');
  assert.match(appels[0].url, /^https:\/\/api\.zeptomail\.eu\//);
  assert.throws(() => creerFournisseurZeptoMail({ ...base, hote: 'x.test/evil?', fetchImpl: f }), /ZEPTOMAIL_HOST/);
});

test('429 -> limite_debit ; 5xx et réseau -> transitoire ; 4xx -> permanente sans blocage', async () => {
  let { f } = faux(rep(429, {}, { 'retry-after': '12' }));
  await assert.rejects(creerFournisseurZeptoMail({ ...base, fetchImpl: f }).envoyer(msg), (e) => e.type === 'limite_debit' && e.retryApresS === 12);
  ({ f } = faux(rep(503, {})));
  await assert.rejects(creerFournisseurZeptoMail({ ...base, fetchImpl: f }).envoyer(msg), (e) => e.type === 'transitoire');
  ({ f } = faux(new Error('ECONNRESET')));
  await assert.rejects(creerFournisseurZeptoMail({ ...base, fetchImpl: f }).envoyer(msg), (e) => e.type === 'transitoire');
  ({ f } = faux(rep(422, { error: { code: 'TM_3201', message: 'adresse pharma@exemple.test invalide' } })));
  await assert.rejects(creerFournisseurZeptoMail({ ...base, fetchImpl: f }).envoyer(msg), (e) => e.type === 'permanente' && !e.bloque && /TM_3201/.test(e.message));
});

test('aucune donnée personnelle ni jeton dans les erreurs', async () => {
  const { f } = faux(rep(401, { error: { code: 'TM_101', message: 'jeton TOKEN refusé pour pharma@exemple.test' } }));
  try { await creerFournisseurZeptoMail({ ...base, fetchImpl: f }).envoyer(msg); assert.fail(); }
  catch (e) { assert.doesNotMatch(e.message, /TOKEN|pharma@exemple|Corps/); }
});

test('sujet obligatoire ; sélection EMAIL_PROVIDER=zeptomail', async () => {
  const { f } = faux(rep(201, {}));
  await assert.rejects(creerFournisseurZeptoMail({ ...base, fetchImpl: f }).envoyer({ ...msg, sujet: '' }), (e) => e.type === 'permanente');
  assert.throws(() => creerFournisseurs({ EMAIL_PROVIDER: 'zeptomail' }), /ZEPTOMAIL_TOKEN/);
  assert.throws(() => creerFournisseurs({ EMAIL_PROVIDER: 'zeptomail', ZEPTOMAIL_TOKEN: 't' }), /EMAIL_FROM_ADDRESS/);
  const p = creerFournisseurs({ EMAIL_PROVIDER: 'zeptomail', ZEPTOMAIL_TOKEN: 't', EMAIL_FROM_ADDRESS: 'a@b.test' });
  assert.equal(p.email.mock, false); assert.equal(p.telegram.mock, true);
  assert.throws(() => creerFournisseurs({ SMS_PROVIDER: 'zeptomail' }), /indisponible/);
});
