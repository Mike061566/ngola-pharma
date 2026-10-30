import { test } from 'node:test';
import assert from 'node:assert/strict';
import { traiterCreation, validerCorps, normaliserTelephone } from '../../supabase/functions/_shared/creation-alerte.js';
import { verifierCaptcha } from '../../supabase/functions/_shared/captcha.js';
import { traiterSuivi } from '../../supabase/functions/_shared/suivi-alerte.js';
import { enTetesCors, ipClient } from '../../supabase/functions/_shared/http.js';
import { hmacHex, sha256Hex, aleatoireBase32 } from '../../supabase/functions/_shared/securite.js';
import { dechiffrer, depuisBytea } from '../../supabase/functions/_shared/chiffrement.js';
import { cleTest, horloge, magasinAlertesMemoire } from './aide.mjs';

const MED = '11111111-1111-4111-8111-111111111111';
const QUARTIER = '22222222-2222-4222-8222-222222222222';
const ENV = { ALERT_AUTO_ROUTING: 'true', CAPTCHA_PROVIDER: 'mock', SIGNING_SECRET: 'secret-de-test-assez-long-1234', TELEGRAM_BOT_USERNAME: 'NGolaTestBot', APP_BASE_URL: 'https://ngola.test' };
const corpsOk = (s = {}) => ({ medicament_id: MED, quartier_id: QUARTIER, urgence: 'normal', canal: 'none', captcha: 'mock-ok', ...s });

async function lancer(corps, { env = ENV, config = { mode_application: 'demo' }, ip = '203.0.113.7', validations = 0, fetchFn } = {}) {
  const h = horloge(); const cle = await cleTest(); const journal = [];
  const magasin = magasinAlertesMemoire({ config, validations, horloge: h });
  const r = await traiterCreation(corps, { env, ip, magasin, cle, maintenant: h.maintenant, fetchFn, journal: (e) => journal.push(e) });
  return { r, magasin, cle, journal, h };
}

test('création nominale : 201, identifiant public, empreintes hachées, rien de personnel en clair', async () => {
  const { r, magasin, journal } = await lancer(corpsOk());
  assert.equal(r.status, 201);
  assert.match(r.corps.id_public, /^NG-[0-9A-HJKMNP-TV-Z]{8}$/);
  assert.equal(r.corps.statut, 'new');
  assert.equal(r.corps.lien_suivi, `https://ngola.test/alerte/${r.corps.id_public}`);
  const c = magasin.etat.creations[0];
  assert.equal(c.p_medicament_id, MED);
  assert.equal(c.p_empreinte_patient, await hmacHex(ENV.SIGNING_SECRET, 'ip:203.0.113.7'));
  assert.equal(c.p_empreinte_ip, c.p_empreinte_patient);
  assert.equal(c.p_contact_chiffre, null);
  assert.doesNotMatch(JSON.stringify(c), /203\.0\.113\.7/);
  assert.doesNotMatch(JSON.stringify(journal), /203\.0\.113|NG-|11111111/);
});

test('expiration calculée : T+2 h ; urgent T+1 h', async () => {
  const a = await lancer(corpsOk());
  assert.equal(a.magasin.etat.creations[0].p_expire_le, '2026-10-05T12:00:00.000Z');
  const u = await lancer(corpsOk({ urgence: 'urgent' }));
  assert.equal(u.magasin.etat.creations[0].p_expire_le, '2026-10-05T11:00:00.000Z');
});

test('SMS : numéro normalisé E.164, chiffré, consentement obligatoire, empreinte = numéro', async () => {
  const sans = await lancer(corpsOk({ canal: 'sms', telephone: '699 12 34 56' }));
  assert.equal(sans.r.status, 400); assert.equal(sans.r.corps.erreur, 'consentement_requis');
  const { r, magasin, cle } = await lancer(corpsOk({ canal: 'sms', telephone: '699 12 34 56', consentement: true }));
  assert.equal(r.status, 201);
  const c = magasin.etat.creations[0];
  assert.equal(await dechiffrer(cle, depuisBytea(c.p_contact_chiffre)), '+237699123456');
  assert.equal(c.p_empreinte_patient, await hmacHex(ENV.SIGNING_SECRET, 'tel:+237699123456'));
  assert.notEqual(c.p_empreinte_patient, c.p_empreinte_ip);
  assert.equal(c.p_consentement, true);
  assert.doesNotMatch(JSON.stringify(c), /699123456/);
});

test('téléphone : formats acceptés et refusés', () => {
  for (const [brut, attendu] of [['699123456', '+237699123456'], ['+237 699 12 34 56', '+237699123456'], ['237699123456', '+237699123456'],
    ['00237 6 99 12 34 56', '+237699123456'], ['6.99.12.34.56', '+237699123456'], ['222 23 45 67', '+237222234567']]) assert.equal(normaliserTelephone(brut), attendu, brut);
  for (const mauvais of ['12345', '+33612345678', '799123456', '', null, 699123456, '699 12 34 5a']) assert.equal(normaliserTelephone(mauvais), null, String(mauvais));
});

test('Telegram : jeton à usage unique stocké HACHÉ, lien profond renvoyé une seule fois', async () => {
  const { r, magasin } = await lancer(corpsOk({ canal: 'telegram' }));
  const m = /^https:\/\/t\.me\/NGolaTestBot\?start=([A-Za-z0-9_-]{40,})$/.exec(r.corps.lien_telegram);
  assert.ok(m, 'lien profond');
  const j = magasin.etat.jetons[0];
  assert.equal(j.jeton_hash, await sha256Hex(m[1]));
  assert.notEqual(j.jeton_hash, m[1]);
  assert.equal(j.objet, 'patient_alert');
  assert.equal(j.ref_id, 'a-new');
  assert.equal(new Date(j.expire_le).getTime() - new Date('2026-10-05T10:00:00Z').getTime(), 72 * 3600000);
});

test('fusion : alerte existante renvoyée en 200, aucun nouveau jeton Telegram', async () => {
  const h = horloge(); const cle = await cleTest(); const magasin = magasinAlertesMemoire({ config: {}, horloge: h });
  magasin.etat.reponseCreation = { alerte_id: 'a-old', id_public: 'NG-ABCDEFGH', statut: 'routing', raison_revue: null, fusionnee: true, refus: null };
  const r = await traiterCreation(corpsOk({ canal: 'telegram' }), { env: ENV, ip: '1.1.1.1', magasin, cle, maintenant: h.maintenant });
  assert.equal(r.status, 200); assert.equal(r.corps.fusionnee, true); assert.equal(r.corps.id_public, 'NG-ABCDEFGH');
  assert.equal(magasin.etat.jetons.length, 0); assert.equal(r.corps.lien_telegram, undefined);
});

test('refus renvoyés par la base : limite quotidienne -> 429, bloqué -> 403 générique, needs_review exposé', async () => {
  const h = horloge(); const cle = await cleTest();
  const via = async (reponse) => { const m = magasinAlertesMemoire({ horloge: h }); m.etat.reponseCreation = reponse; return traiterCreation(corpsOk(), { env: ENV, ip: '1.1.1.1', magasin: m, cle, maintenant: h.maintenant }); };
  const lim = await via({ refus: 'limite_quotidienne' }); assert.equal(lim.status, 429); assert.match(lim.corps.message, /pharmacie de garde/);
  const blo = await via({ refus: 'bloque' }); assert.equal(blo.status, 403); assert.equal(blo.corps.erreur, 'refuse');
  const rev = await via({ alerte_id: 'x', id_public: 'NG-ABCDEFGH', statut: 'needs_review', raison_revue: 'restreint', fusionnee: false, refus: null });
  assert.equal(rev.status, 201); assert.equal(rev.corps.statut, 'needs_review');
});

test('collision d\'identifiant public : nouvelle tentative (3 essais au plus)', async () => {
  const h = horloge(); const cle = await cleTest(); const m = magasinAlertesMemoire({ horloge: h });
  let n = 0; const orig = m.creerAlerte;
  m.creerAlerte = async (p) => { n += 1; if (n < 3) throw new Error('creerAlerte : 23505'); return orig(p); };
  const r = await traiterCreation(corpsOk(), { env: ENV, ip: '1.1.1.1', magasin: m, cle, maintenant: h.maintenant });
  assert.equal(r.status, 201); assert.equal(n, 3);
  let k = 0; m.creerAlerte = async () => { k += 1; throw new Error('creerAlerte : 23505'); };
  assert.equal((await traiterCreation(corpsOk(), { env: ENV, ip: '1.1.1.1', magasin: m, cle, maintenant: h.maintenant })).status, 500);
  assert.equal(k, 3);
});

test('ordonnance : tout champ de type ordonnance/photo/document est refusé avec le message de la spec ; champs inconnus refusés', () => {
  for (const champ of ['ordonnance', 'numero_ordonnance', 'photo', 'photo_ordonnance', 'document', 'scan', 'prescription', 'image']) {
    const r = validerCorps({ ...corpsOk(), [champ]: 'x' });
    assert.equal(r.erreur, 'ordonnance_interdite', champ);
  }
  assert.equal(validerCorps({ ...corpsOk(), nom: 'Jean' }).erreur, 'champ_inconnu');
  assert.equal(validerCorps({ ...corpsOk(), role: 'admin' }).erreur, 'champ_inconnu');
});

test('validation : médicament XOR texte libre, quartier, position, urgence, canal, téléphone inattendu', () => {
  assert.equal(validerCorps(corpsOk({ medicament_id: undefined })).erreur, 'medicament_ou_requete');
  assert.equal(validerCorps(corpsOk({ requete: 'quelque chose' })).erreur, 'medicament_ou_requete');
  assert.equal(validerCorps(corpsOk({ medicament_id: 'pas-un-uuid' })).erreur, 'medicament_ou_requete');
  assert.equal(validerCorps(corpsOk({ medicament_id: undefined, requete: 'x' })).erreur, 'medicament_ou_requete');
  assert.equal(validerCorps(corpsOk({ medicament_id: undefined, requete: 'a'.repeat(121) })).erreur, 'medicament_ou_requete');
  assert.deepEqual(validerCorps(corpsOk({ medicament_id: undefined, requete: '  vitamine   C  ' })).valeur.requete, 'vitamine C');
  assert.equal(validerCorps(corpsOk({ quartier_id: 'x' })).erreur, 'quartier_invalide');
  assert.equal(validerCorps(corpsOk({ quartier_id: undefined })).erreur, 'quartier_invalide');
  assert.equal(validerCorps(corpsOk({ lat: 91, lng: 11 })).erreur, 'position_invalide');
  assert.equal(validerCorps(corpsOk({ lat: 3.8 })).erreur, 'position_invalide');
  assert.equal(validerCorps(corpsOk({ lat: '3.8', lng: '11' })).erreur, 'position_invalide');
  assert.equal(validerCorps(corpsOk({ lat: 3.8, lng: 11.5 })).ok, true);
  assert.equal(validerCorps(corpsOk({ urgence: 'critique' })).erreur, 'urgence_invalide');
  assert.equal(validerCorps(corpsOk({ canal: 'whatsapp' })).erreur, 'canal_invalide');
  assert.equal(validerCorps(corpsOk({ canal: 'telegram', telephone: '699123456' })).erreur, 'telephone_inattendu');
  assert.equal(validerCorps(corpsOk({ canal: 'sms', telephone: 'abc', consentement: true })).erreur, 'telephone_invalide');
  assert.equal(validerCorps(null).erreur, 'corps_invalide');
  assert.equal(validerCorps([]).erreur, 'corps_invalide');
  assert.equal(validerCorps(corpsOk({ captcha: undefined })).erreur, 'captcha_invalide');
});

test('feature flag : ALERT_AUTO_ROUTING absent ou faux -> 503 (comportement actuel : dispatch manuel)', async () => {
  for (const flag of [undefined, 'false', '1', 'TRUE']) {
    const { r, magasin } = await lancer(corpsOk(), { env: { ...ENV, ALERT_AUTO_ROUTING: flag } });
    assert.equal(r.status, 503, String(flag)); assert.equal(r.corps.erreur, 'routage_desactive');
    assert.equal(magasin.etat.creations.length, 0);
  }
});

test('verrou de production : flag actif + production sans validation pharmacien -> refusé ; avec validation -> accepté', async () => {
  const prod = { mode_application: 'production' };
  const e = { ...ENV, CAPTCHA_PROVIDER: 'turnstile', CAPTCHA_SECRET: 's' };
  const fetchOk = async () => ({ ok: true, json: async () => ({ success: true }) });
  assert.equal((await lancer(corpsOk(), { env: e, config: prod, validations: 0, fetchFn: fetchOk })).r.corps.erreur, 'routage_desactive');
  assert.equal((await lancer(corpsOk(), { env: e, config: prod, validations: 1, fetchFn: fetchOk })).r.status, 201);
});

test('captcha : jeton absent ou invalide refusé AVANT toute écriture ; mock refusé en production', async () => {
  const mauvais = await lancer(corpsOk({ captcha: 'faux' }));
  assert.equal(mauvais.r.status, 403); assert.equal(mauvais.r.corps.erreur, 'captcha_invalide');
  assert.equal(mauvais.magasin.etat.creations.length, 0);
  const prodMock = await lancer(corpsOk(), { config: { mode_application: 'production' }, validations: 1 });
  assert.equal(prodMock.r.status, 503); assert.equal(prodMock.r.corps.erreur, 'captcha_non_configure');
});

test('captcha Turnstile : appel siteverify avec secret, jeton et IP ; échec réseau = indisponible', async () => {
  let appel;
  const fetchFn = async (url, init) => { appel = { url, corps: init.body.toString() }; return { ok: true, json: async () => ({ success: true }) }; };
  assert.deepEqual(await verifierCaptcha({ fournisseur: 'turnstile', secret: 'S', jeton: 'J', ip: '1.2.3.4', mode: 'production', fetchFn }), { ok: true });
  assert.equal(appel.url, 'https://challenges.cloudflare.com/turnstile/v0/siteverify');
  assert.match(appel.corps, /secret=S/); assert.match(appel.corps, /response=J/); assert.match(appel.corps, /remoteip=1\.2\.3\.4/);
  assert.equal((await verifierCaptcha({ fournisseur: 'turnstile', secret: 'S', jeton: 'J', fetchFn: async () => ({ ok: true, json: async () => ({ success: false }) }) })).raison, 'jeton_invalide');
  assert.equal((await verifierCaptcha({ fournisseur: 'turnstile', secret: 'S', jeton: 'J', fetchFn: async () => { throw new Error('réseau'); } })).raison, 'indisponible');
  assert.equal((await verifierCaptcha({ fournisseur: 'turnstile', secret: 'S', jeton: 'J', fetchFn: async () => ({ ok: false }) })).raison, 'indisponible');
  assert.equal((await verifierCaptcha({ fournisseur: 'turnstile', jeton: 'J', fetchFn })).raison, 'captcha_non_configure');
  assert.equal((await verifierCaptcha({ fournisseur: 'inconnu', jeton: 'J', mode: 'demo' })).raison, 'captcha_non_configure');
  assert.equal((await verifierCaptcha({ fournisseur: 'mock', jeton: '', mode: 'demo' })).raison, 'jeton_absent');
  assert.equal((await verifierCaptcha({ fournisseur: 'mock', jeton: 'mock-ok', mode: 'demo' })).ok, true);
});

test('sans IP ni numéro : pas de limitation possible -> erreur interne, rien créé', async () => {
  const { r, magasin } = await lancer(corpsOk(), { ip: null });
  assert.equal(r.status, 500); assert.equal(magasin.etat.creations.length, 0);
});

test('erreur de base : 500 sans détail', async () => {
  const h = horloge(); const cle = await cleTest(); const m = magasinAlertesMemoire({ horloge: h });
  m.creerAlerte = async () => { throw new Error('creerAlerte : 42501 détail 203.0.113.7'); };
  const journal = [];
  const r = await traiterCreation(corpsOk(), { env: ENV, ip: '203.0.113.7', magasin: m, cle, maintenant: h.maintenant, journal: (e) => journal.push(e) });
  assert.equal(r.status, 500); assert.doesNotMatch(JSON.stringify([r, journal]), /203\.0\.113|42501/);
});

// ── Suivi public ──
test('suivi : format d\'identifiant, 404, état sans donnée patient ni pharmacie avant réponse', async () => {
  const h = horloge(); const m = magasinAlertesMemoire({ horloge: h });
  m.etat.suivis = { 'NG-ABCDEFGH': { id: 'a1', id_public: 'NG-ABCDEFGH', statut: 'routing', urgence: 'normal', cree_le: 'x', expire_le: 'y',
    patient_notifie_le: null, contact_patient_chiffre: '\\xdead', empreinte_patient: 'h', medicaments: { nom: 'Ibuprofène', dosage: '400mg', ordonnance: true }, quartiers: { nom: 'Bastos' } } };
  assert.equal((await traiterSuivi('nimporte', { magasin: m })).status, 400);
  assert.equal((await traiterSuivi('NG-ZZZZZZZZ', { magasin: m })).status, 404);
  const r = await traiterSuivi('NG-ABCDEFGH', { magasin: m });
  assert.equal(r.status, 200);
  assert.equal(r.corps.medicament, 'Ibuprofène 400mg'); assert.equal(r.corps.sur_ordonnance, true);
  assert.equal(r.corps.pharmacies, undefined);
  assert.doesNotMatch(JSON.stringify(r.corps), /dead|empreinte|contact|"h"/);
});

test('suivi : pharmacies affichées seulement quand une pharmacie a répondu (statut answered)', async () => {
  const h = horloge(); const m = magasinAlertesMemoire({ horloge: h });
  const base = { id: 'a1', id_public: 'NG-ABCDEFGH', statut: 'answered', urgence: 'normal', medicaments: null, quartiers: null };
  m.pharmaciesDisponibles = async () => [{ nom: 'P', prix_fcfa: 1000 }];
  m.etat.suivis = { 'NG-ABCDEFGH': { ...base, statut: 'routing', patient_notifie_le: null } };
  assert.equal((await traiterSuivi('NG-ABCDEFGH', { magasin: m })).corps.pharmacies, undefined);
  m.etat.suivis = { 'NG-ABCDEFGH': { ...base, patient_notifie_le: null } };
  assert.deepEqual((await traiterSuivi('NG-ABCDEFGH', { magasin: m })).corps.pharmacies, [{ nom: 'P', prix_fcfa: 1000 }]);
});

// ── HTTP, sécurité ──
test('CORS : seule une origine de la liste est reflétée ; IP : cf-connecting-ip puis x-forwarded-for', () => {
  const req = (origin) => ({ headers: new Headers(origin ? { origin } : {}) });
  assert.equal(enTetesCors(req('https://ngola.test'), 'https://ngola.test, https://autre.test')['access-control-allow-origin'], 'https://ngola.test');
  assert.equal(enTetesCors(req('https://evil.test'), 'https://ngola.test')['access-control-allow-origin'], undefined);
  assert.equal(enTetesCors(req('https://ngola.test'), undefined)['access-control-allow-origin'], undefined);
  assert.equal(ipClient(new Headers({ 'cf-connecting-ip': '1.1.1.1', 'x-forwarded-for': '2.2.2.2' })), '1.1.1.1');
  assert.equal(ipClient(new Headers({ 'x-forwarded-for': '2.2.2.2, 3.3.3.3' })), '2.2.2.2');
  assert.equal(ipClient(new Headers()), null);
});

test('hmacHex : déterministe, dépend du secret ; secret trop court refusé ; base32 sans caractères ambigus', async () => {
  const a = await hmacHex('un-secret-assez-long-123', 'x'), b = await hmacHex('un-secret-assez-long-123', 'x');
  assert.equal(a, b); assert.equal(a.length, 64);
  assert.notEqual(a, await hmacHex('un-autre-secret-assez-long', 'x'));
  await assert.rejects(hmacHex('court', 'x'));
  assert.match(aleatoireBase32(200), /^[0-9A-HJKMNP-TV-Z]{200}$/);
});
