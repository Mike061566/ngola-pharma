import { test } from 'node:test';
import assert from 'node:assert/strict';
import { analyserMiseAJour, traiterMiseAJour, traiterLien, codeValide, texteConfirmation, texteCollegue } from '../../supabase/functions/_shared/reponses.js';
import { traiterTestContact } from '../../supabase/functions/_shared/test-contact.js';
import { traiterOutbox } from '../../supabase/functions/_shared/traitement.js';
import { creerFournisseurMock } from '../../supabase/functions/_shared/fournisseur-mock.js';
import { sha256Hex, hmacHex } from '../../supabase/functions/_shared/securite.js';
import { dechiffrer, depuisBytea } from '../../supabase/functions/_shared/chiffrement.js';
import { cleTest, horloge, magasinAlertesMemoire, ajouterReponsesMemoire } from './aide.mjs';

const SECRET = 'secret-de-test-assez-long-1234';
const ENVOI1 = 'abcdef01-0000-4000-8000-000000000001', ENVOI2 = 'abcdef02-0000-4000-8000-000000000002';
const TOKEN = 'JetonDeTest_0123456789-abcdefghij';
const msg = (texte, chat = 111, extra = {}) => ({ update_id: 1, message: { message_id: 5, chat: { id: chat, type: 'private' }, from: { id: chat, first_name: 'Amina' }, text: texte, ...extra } });
const clic = (donnees, chat = 111) => ({ update_id: 2, callback_query: { id: 'cb1', from: { id: chat }, data: donnees, message: { message_id: 77, chat: { id: chat, type: 'private' } } } });
const contact = (id, ph, chat, s = {}) => ({ id, pharmacie_id: ph, canal: 'telegram', adresse: String(chat), verifie_le: '2026-10-01', desabonne_le: null, bloque_le: null, est_contact_demo: true, ...s });

async function monter({ config = { mode_application: 'production' }, contacts, demoAdresses = [] } = {}) {
  const h = horloge('2026-10-05T10:00:00Z'); const cle = await cleTest(); const journal = [];
  const pharmacies = [{ id: 'p1', nom: 'Pharmacie <Centre>' }, { id: 'p2', nom: 'Pharmacie 2' }];
  const alertes = [{ id: 'a1', id_public: 'NG-ABCDEFGH', statut: 'routing', expire_le: '2026-10-05T12:00:00Z', canal_patient: 'none', contact_patient_chiffre: null, consentement_le: null }];
  const magasin = ajouterReponsesMemoire(magasinAlertesMemoire({ config, alertes, pharmacies, demoAdresses, horloge: h,
    contacts: contacts ?? [contact('c1', 'p1', 111), contact('c2', 'p1', 222), contact('c3', 'p2', 333)] }), h);
  magasin.etat.envois.push(
    { id: ENVOI1, alerte_id: 'a1', pharmacie_id: 'p1', statut: 'sent' }, { id: ENVOI2, alerte_id: 'a1', pharmacie_id: 'p2', statut: 'sent' });
  // messages Telegram déjà envoyés aux deux agents de p1
  magasin.etat.lignes.push(
    { id: 'o1', cle_base: ENVOI1, canal: 'telegram', modele: 'alerte_demande', contact_id: 'c1', id_discussion_fournisseur: '111', id_message_fournisseur: '77', statut: 'sent' },
    { id: 'o2', cle_base: ENVOI1, canal: 'telegram', modele: 'alerte_demande', contact_id: 'c2', id_discussion_fournisseur: '222', id_message_fournisseur: '88', statut: 'sent' });
  const fournisseur = creerFournisseurMock('telegram');
  const traiter = (update) => traiterMiseAJour(update, { magasin, cle, fournisseur, env: { SIGNING_SECRET: SECRET }, config: { decalage_horaire_min: 60 }, maintenant: h.maintenant, journal: (e) => journal.push(e) });
  return { h, cle, magasin, etat: magasin.etat, fournisseur, traiter, journal, outbox: () => magasin.etat.lignes.filter((l) => !l.id.startsWith('o')) };
}
const shortId = (id) => id.slice(0, 8);

// ── Analyse des mises à jour ──
test('analyse : /start avec ou sans jeton, @bot, /stop, /aide, texte, fichiers, groupes, callback', () => {
  assert.deepEqual(analyserMiseAJour(msg(`/start ${TOKEN}`)), { type: 'start', chatId: '111', nom: 'Amina', jeton: TOKEN });
  assert.equal(analyserMiseAJour(msg('/start')).jeton, null);
  assert.equal(analyserMiseAJour(msg(`/start@NGolaBot ${TOKEN}`)).jeton, TOKEN);
  assert.equal(analyserMiseAJour(msg('/start court')).jeton, null, 'jeton de mauvais format');
  assert.equal(analyserMiseAJour(msg('/start ' + 'x'.repeat(200))).jeton, null);
  assert.equal(analyserMiseAJour(msg('/STOP')).type, 'stop');
  assert.equal(analyserMiseAJour(msg('/aide')).type, 'aide');
  assert.equal(analyserMiseAJour(msg('/help')).type, 'aide');
  assert.equal(analyserMiseAJour(msg('bonjour')).type, 'texte');
  assert.equal(analyserMiseAJour(msg('/inconnu')).type, 'texte');
  assert.equal(analyserMiseAJour(msg(undefined, 111, { text: undefined, photo: [{ file_id: 'x' }] })).type, 'media');
  assert.equal(analyserMiseAJour(msg(undefined, 111, { text: undefined, document: { file_id: 'x' } })).type, 'media');
  assert.equal(analyserMiseAJour({ update_id: 1, message: { chat: { id: -5, type: 'group' }, text: '/start' } }).type, 'ignore');
  assert.equal(analyserMiseAJour({ update_id: 1, message: { chat: { id: -5, type: 'supergroup' }, photo: [{}] } }).type, 'ignore');
  assert.deepEqual(analyserMiseAJour(clic('r:abcdef01:a')), { type: 'callback', chatId: '111', idCallback: 'cb1', messageId: 77, donnees: 'r:abcdef01:a' });
  assert.equal(analyserMiseAJour({ callback_query: { id: 'x', from: { id: 999 }, data: 'r:abcdef01:a', message: { message_id: 1, chat: { id: 111, type: 'private' } } } }).type, 'ignore', 'expéditeur ≠ chat');
  for (const mauvais of [null, undefined, 5, 'x', {}, { message: {} }]) assert.equal(analyserMiseAJour(mauvais).type, 'ignore');
});

// ── Boutons ──
test('clic « Disponible » : réponse enregistrée une fois, message retiré des boutons, collègue informé, clic acquitté', async () => {
  const t = await monter();
  const r = await t.traiter(clic(`r:${shortId(ENVOI1)}:a`, 111));
  assert.equal(r.resultat, 'enregistree');
  assert.deepEqual(t.etat.appelsReponse, [{ envoiId: ENVOI1, reponse: 'available', prix: null, canal: 'telegram', utilisateur: null }]);
  const edits = t.fournisseur.modifies;
  const propre = edits.find((e) => e.idDiscussion === '111'), collegue = edits.find((e) => e.idDiscussion === '222');
  assert.equal(propre.idMessage, 77); assert.equal(propre.texte, texteConfirmation('available', '11:00')); assert.deepEqual(propre.boutons, []);
  assert.equal(collegue.idMessage, '88'); assert.equal(collegue.texte, texteCollegue('11:00')); assert.deepEqual(collegue.boutons, []);
  assert.equal(edits.length, 2);
  assert.equal(t.fournisseur.callbacks[0].idCallback, 'cb1');
});

test('« Indisponible » : réponse unavailable ; le second agent qui clique ensuite voit « déjà traitée par un collègue »', async () => {
  const t = await monter();
  await t.traiter(clic(`r:${shortId(ENVOI1)}:u`, 111));
  assert.equal(t.etat.appelsReponse[0].reponse, 'unavailable');
  t.fournisseur.modifies.length = 0;
  const r2 = await t.traiter(clic(`r:${shortId(ENVOI1)}:a`, 222));
  assert.equal(r2.resultat, 'deja_traitee');
  assert.equal(t.etat.reponsesEnvoi.get(ENVOI1).reponse, 'unavailable', 'la première réponse l\'emporte');
  assert.equal(t.fournisseur.modifies.length, 1);
  assert.equal(t.fournisseur.modifies[0].idDiscussion, '222'); assert.equal(t.fournisseur.modifies[0].texte, texteCollegue('11:00'));
});

test('sécurité : chat inconnu, contact non vérifié, bloqué, désabonné -> ignoré, aucune écriture, rien de personnel journalisé', async () => {
  const contacts = [contact('c1', 'p1', 111), contact('c4', 'p1', 444, { verifie_le: null }), contact('c5', 'p1', 555, { bloque_le: '2026-10-02' }), contact('c6', 'p1', 666, { desabonne_le: '2026-10-02' })];
  const t = await monter({ contacts });
  for (const chat of [999, 444, 555, 666]) {
    const r = await t.traiter(clic(`r:${shortId(ENVOI1)}:a`, chat));
    assert.equal(r.resultat, 'ignore', String(chat));
  }
  assert.equal(t.etat.appelsReponse.length, 0);
  assert.equal(t.fournisseur.modifies.length, 0); assert.equal(t.fournisseur.callbacks.length, 0);
  assert.ok(t.journal.every((e) => e.evt === 'callback_ignore'));
  assert.doesNotMatch(JSON.stringify(t.journal), /999|444|555|666|abcdef01/);
});

test('sécurité : callback_data invalide, trop long, ou envoi d\'une autre pharmacie -> aucune réponse enregistrée', async () => {
  const t = await monter();
  for (const d of ['', 'x', 'r:abcdef01:z', 'r:ABCDEF01:a', 'r:abcdef01:a:extra', 'r:' + 'a'.repeat(80) + ':a', 'r:abcdef0:a']) {
    assert.equal((await t.traiter(clic(d))).resultat, 'ignore', d);
  }
  const autre = await t.traiter(clic(`r:${shortId(ENVOI2)}:a`, 111));      // l'envoi de la pharmacie 2, cliqué par un agent de la pharmacie 1
  assert.equal(autre.resultat, 'introuvable');
  assert.equal(t.etat.appelsReponse.length, 0);
  assert.equal(t.fournisseur.callbacks.length, 1);
});

test('demande expirée : message « a expiré », rien d\'enregistré côté pharmacie', async () => {
  const t = await monter();
  t.etat.alertes[0].statut = 'expired';
  const r = await t.traiter(clic(`r:${shortId(ENVOI1)}:a`));
  assert.equal(r.resultat, 'expiree');
  assert.match(t.fournisseur.modifies[0].texte, /expiré/);
  assert.equal(t.etat.reponsesEnvoi.size, 0);
});

test('échec d\'édition Telegram : journalisé sans casser le traitement', async () => {
  const t = await monter();
  t.fournisseur.modifierMessage = async () => { throw new Error('400 chat 111 introuvable'); };
  const r = await t.traiter(clic(`r:${shortId(ENVOI1)}:a`));
  assert.equal(r.resultat, 'enregistree');
  assert.ok(t.journal.some((e) => e.evt === 'edition_echouee'));
  assert.doesNotMatch(JSON.stringify(t.journal), /111|introuvable/);
});

// ── /start : activation d'une pharmacie ──
async function ajouterJeton(t, objet, ref, { expire = '2026-10-08T10:00:00Z' } = {}) {
  t.etat.jetonsTg.set(await sha256Hex(TOKEN), { objet, ref_id: ref, expire_le: expire, utilise: false });
}

test('/start <jeton> pharmacie : contact lié et vérifié, message d\'activation en file (nom échappé à l\'envoi), jeton à usage unique', async () => {
  const t = await monter({ contacts: [contact('cn', 'p1', 'en_attente:x', { verifie_le: null })] });
  await ajouterJeton(t, 'pharmacy_contact', 'cn');
  const r = await t.traiter(msg(`/start ${TOKEN}`, 777));
  assert.equal(r.resultat, 'active');
  const c = t.etat.contacts.find((x) => x.id === 'cn');
  assert.equal(c.adresse, '777'); assert.ok(c.verifie_le);
  const m = t.outbox()[0];
  assert.equal(m.modele, 'telegram_activation'); assert.equal(m.contact_id, 'cn'); assert.equal(m.variables.nom, 'Amina'); assert.equal(m.variables.pharmacie, 'Pharmacie <Centre>');
  assert.equal(m.est_destinataire_demo, true); assert.equal(m.destinataire_ref, 'p1');
  assert.equal(await dechiffrer(t.cle, depuisBytea(m.adresse_chiffree)), '777');
  // le même jeton rejoué est refusé
  const r2 = await t.traiter({ ...msg(`/start ${TOKEN}`, 888), update_id: 9 });
  assert.equal(r2.resultat, 'refuse');
  assert.equal(t.outbox().find((l) => l.cle_base === 'tg:9:lien_invalide').modele, 'lien_invalide');
  assert.equal(t.etat.contacts.find((x) => x.id === 'cn').adresse, '777', 'le contact n\'a pas changé de compte');
});

test('/start : jeton expiré, inconnu, absent -> « lien non valable », rien de lié', async () => {
  const t = await monter({ contacts: [contact('cn', 'p1', 'en_attente:x', { verifie_le: null })] });
  await ajouterJeton(t, 'pharmacy_contact', 'cn', { expire: '2026-10-05T09:59:59Z' });
  assert.equal((await t.traiter(msg(`/start ${TOKEN}`, 777))).resultat, 'refuse');
  assert.equal((await t.traiter({ ...msg('/start autre-jeton-inconnu-123456', 777), update_id: 3 })).resultat, 'refuse');
  assert.equal((await t.traiter({ ...msg('/start', 777), update_id: 4 })).resultat, 'invalide');
  assert.equal(t.etat.contacts.find((x) => x.id === 'cn').verifie_le, null);
  assert.ok(t.outbox().every((l) => l.modele === 'lien_invalide'));
});

test('/start : plafond de comptes Telegram atteint -> message dédié', async () => {
  const contacts = [1, 2, 3].map((i) => contact(`v${i}`, 'p1', 100 + i)).concat([contact('cn', 'p1', 'en_attente:x', { verifie_le: null })]);
  const t = await monter({ contacts });
  await ajouterJeton(t, 'pharmacy_contact', 'cn');
  assert.equal((await t.traiter(msg(`/start ${TOKEN}`, 777))).resultat, 'limite_contacts');
  assert.equal(t.outbox()[0].modele, 'limite_contacts');
});

test('/start <jeton> patient : chat_id CHIFFRÉ, empreinte HMAC, consentement horodaté ; réponse « patient_lie »', async () => {
  const t = await monter();
  await ajouterJeton(t, 'patient_alert', 'a1');
  const r = await t.traiter(msg(`/start ${TOKEN}`, 5551234));
  assert.equal(r.resultat, 'patient');
  const a = t.etat.alertes[0];
  assert.equal(a.canal_patient, 'telegram'); assert.ok(a.consentement_le);
  assert.equal(await dechiffrer(t.cle, depuisBytea(a.contact_patient_chiffre)), '5551234');
  assert.equal(a.empreinte_telegram, await hmacHex(SECRET, 'tg:5551234'));
  assert.doesNotMatch(JSON.stringify(a), /5551234/);
  assert.equal(t.outbox()[0].modele, 'patient_lie'); assert.equal(t.outbox()[0].type_destinataire, 'patient');
});

// ── /stop, /aide, fichiers ──
test('/stop : contacts de pharmacie désabonnés (plus aucun message), alertes du patient détachées, confirmation', async () => {
  const t = await monter();
  const empreinte = await hmacHex(SECRET, 'tg:111');
  t.etat.alertes[0].empreinte_telegram = empreinte; t.etat.alertes[0].contact_patient_chiffre = '\\x00'; t.etat.alertes[0].canal_patient = 'telegram';
  const r = await t.traiter(msg('/stop', 111));
  assert.equal(r.contacts, 1);
  assert.ok(t.etat.contacts.find((c) => c.id === 'c1').desabonne_le);
  assert.equal(t.etat.contacts.find((c) => c.id === 'c2').desabonne_le, null, 'les autres comptes ne sont pas touchés');
  assert.equal(t.etat.alertes[0].contact_patient_chiffre, null); assert.equal(t.etat.alertes[0].canal_patient, 'none');
  assert.equal(t.outbox()[0].modele, 'desabonnement_ok');
  // le worker n'enverra plus rien vers ce contact
  t.etat.lignes.push({ ...t.outbox()[0], id: 'x1', statut: 'queued', cle_idempotence: 'zz', contact_id: 'c1', modele: 'alerte_demande', variables: { drug: 'X', quartier: 'Q', heure: '1', code: 'C', envoi_court: 'e' }, tentatives: 0, prochaine_tentative_le: '2026-10-05T09:00:00Z', est_destinataire_demo: true });
  const f = { telegram: creerFournisseurMock('telegram'), sms: creerFournisseurMock('sms'), email: creerFournisseurMock('email') };
  await traiterOutbox({ magasin: t.magasin, fournisseurs: f, cle: t.cle, maintenant: t.h.maintenant, dormir: t.h.dormir });
  assert.equal(t.etat.lignes.find((l) => l.id === 'x1').statut, 'cancelled');
});

test('photo ou document : ignorés (jamais conservés), réponse « aucune ordonnance à envoyer » ; texte libre : aide', async () => {
  const t = await monter();
  const r = await t.traiter(msg(undefined, 111, { text: undefined, photo: [{ file_id: 'SECRET_FILE_ID', file_size: 1234 }], caption: 'mon ordonnance 0612345678' }));
  assert.equal(r.type, 'media');
  const m = t.outbox()[0];
  assert.equal(m.modele, 'ordonnance_refus');
  assert.doesNotMatch(JSON.stringify(t.etat), /SECRET_FILE_ID|0612345678|mon ordonnance/);
  assert.doesNotMatch(JSON.stringify(t.journal), /SECRET_FILE_ID|0612345678/);
  await t.traiter({ ...msg('bonjour', 111), update_id: 8 });
  assert.equal(t.outbox().find((l) => l.cle_base === 'tg:8:aide_bot').modele, 'aide_bot');
});

test('les groupes sont ignorés (chats privés uniquement) ; les rejeux Telegram (même update_id) ne dupliquent pas la réponse', async () => {
  const t = await monter();
  assert.equal((await t.traiter({ update_id: 5, message: { chat: { id: -9, type: 'group' }, text: '/aide' } })).type, 'ignore');
  assert.equal(t.outbox().length, 0);
  await t.traiter(msg('/aide', 111)); await t.traiter(msg('/aide', 111));
  assert.equal(t.outbox().length, 1);
});

test('mode démo : une réponse du bot vers un compte hors liste blanche part en suppressed_demo (aucun appel fournisseur)', async () => {
  const t = await monter({ config: { mode_application: 'demo' } });
  await t.traiter(msg('/aide', 4242));
  assert.equal(t.outbox()[0].est_destinataire_demo, false);
  const f = { telegram: creerFournisseurMock('telegram'), sms: creerFournisseurMock('sms'), email: creerFournisseurMock('email') };
  await traiterOutbox({ magasin: t.magasin, fournisseurs: f, cle: t.cle, maintenant: t.h.maintenant, dormir: t.h.dormir });
  assert.equal(t.outbox()[0].statut, 'suppressed_demo'); assert.equal(f.telegram.envoyes.length, 0);
});

// ── Lien /r/<code> ──
const LIEN = { id: ENVOI1, statut: 'sent', pharmacie_nom: 'Pharmacie 1', alerte_statut: 'routing', expire_le: '2026-10-05T12:00:00Z', urgence: 'normal', medicament: 'Ibuprofène 400mg', forme: 'comprimé',
  sur_ordonnance: true, quartier: 'Bastos', prix_stock: 1500, reponse: null, prix_repondu: null, repondu_le: null };
async function monterLien(lien = LIEN) {
  const t = await monter();
  t.etat.liens = { ABCDEFGH23: { ...lien }, ZZZZZZZZZZ: { ...lien, id: 'inconnu' } };
  const appel = (methode, entree) => traiterLien(methode, entree, { magasin: t.magasin, fournisseur: t.fournisseur, config: { decalage_horaire_min: 60 }, maintenant: t.h.maintenant, journal: () => {} });
  return { ...t, appel };
}

test('lien : format du code, code inconnu -> 404 identique (aucune information)', async () => {
  const t = await monterLien();
  for (const code of ['', 'abc', 'abcdefgh23', 'ABCDEFGHI3', 'ABCDEFGH2', 'ABCDEFGH234', null, undefined, '../etc/passwd']) {
    assert.equal(codeValide(code), false, String(code));
    assert.deepEqual(await t.appel('GET', { code }), { status: 404, corps: { erreur: 'introuvable' } });
  }
  assert.deepEqual(await t.appel('GET', { code: 'MMMMMMMMMM' }), { status: 404, corps: { erreur: 'introuvable' } });
});

test('lien GET : informations de la demande avec prix pré-rempli, sans aucune donnée patient', async () => {
  const t = await monterLien();
  const r = await t.appel('GET', { code: 'ABCDEFGH23' });
  assert.equal(r.status, 200);
  assert.deepEqual(r.corps, { pharmacie: 'Pharmacie 1', medicament: 'Ibuprofène 400mg', forme: 'comprimé', quartier: 'Bastos', sur_ordonnance: true, urgence: 'normal',
    expire_le: '2026-10-05T12:00:00Z', prix_prefill: 1500, etat: 'ouvert', reponse: null, prix: null, heure_reponse: null });
});

test('lien POST : réponse « Disponible » avec prix ; tous les messages Telegram de la pharmacie perdent leurs boutons ; rejouée = idempotent', async () => {
  const t = await monterLien();
  const r = await t.appel('POST', { code: 'ABCDEFGH23', reponse: 'available', prix: 1700 });
  assert.equal(r.status, 200); assert.equal(r.corps.resultat, 'enregistree'); assert.equal(r.corps.prix, 1700); assert.equal(r.corps.heure, '11:00');
  assert.deepEqual(t.etat.appelsReponse[0], { envoiId: ENVOI1, reponse: 'available', prix: 1700, canal: 'link', utilisateur: null });
  assert.equal(t.fournisseur.modifies.length, 2);
  assert.ok(t.fournisseur.modifies.every((e) => e.texte === texteConfirmation('available', '11:00') && e.boutons.length === 0));
  const bis = await t.appel('POST', { code: 'ABCDEFGH23', reponse: 'unavailable' });
  assert.equal(bis.status, 200); assert.equal(bis.corps.deja, true); assert.equal(bis.corps.reponse, 'available');
  assert.equal(t.etat.reponsesEnvoi.size, 1);
});

test('lien POST : prix non entier, négatif, démesuré, réponse invalide, alerte expirée', async () => {
  const t = await monterLien();
  assert.equal((await t.appel('POST', { code: 'ABCDEFGH23', reponse: 'available', prix: 12.5 })).status, 400);
  assert.equal((await t.appel('POST', { code: 'ABCDEFGH23', reponse: 'available', prix: '1000' })).status, 400);
  assert.equal((await t.appel('POST', { code: 'ABCDEFGH23', reponse: 'available', prix: -1 })).status, 400);
  assert.equal((await t.appel('POST', { code: 'ABCDEFGH23', reponse: 'available', prix: 99999999 })).status, 400);
  assert.equal((await t.appel('POST', { code: 'ABCDEFGH23', reponse: 'peut-etre' })).status, 400);
  assert.equal(t.etat.reponsesEnvoi.size, 0);
  t.etat.alertes[0].statut = 'expired'; t.etat.liens.ABCDEFGH23.alerte_statut = 'expired';
  const r = await t.appel('POST', { code: 'ABCDEFGH23', reponse: 'available', prix: 1000 });
  assert.equal(r.status, 410);
  const g = await t.appel('GET', { code: 'ABCDEFGH23' });
  assert.equal(g.corps.etat, 'expire');
});

// ── Test d'envoi ──
test('test d\'envoi : seulement un contact de SA pharmacie, actif ; 1 par minute ; message de test en file (démo respectée)', async () => {
  const t = await monter();
  t.etat.profils = { u1: { id: 'u1', role: 'pharmacien', pharmacie_id: 'p1' }, u2: { id: 'u2', role: 'pharmacien', pharmacie_id: 'p2' }, adm: { id: 'adm', role: 'admin', pharmacie_id: null } };
  const ctx = { magasin: t.magasin, cle: t.cle, maintenant: t.h.maintenant };
  assert.equal((await traiterTestContact({ contactId: 'pas-un-uuid', utilisateurId: 'u1' }, ctx)).status, 400);
  const U = '00000000-0000-4000-8000-0000000000c1';
  t.etat.contacts.push({ ...contact(U, 'p1', 111) });
  assert.equal((await traiterTestContact({ contactId: U, utilisateurId: 'adm' }, ctx)).status, 403);
  assert.equal((await traiterTestContact({ contactId: U, utilisateurId: 'inconnu' }, ctx)).status, 403);
  assert.equal((await traiterTestContact({ contactId: U, utilisateurId: null }, ctx)).status, 403);
  assert.equal((await traiterTestContact({ contactId: U, utilisateurId: 'u2' }, ctx)).status, 404, 'contact d\'une autre pharmacie');
  const ok1 = await traiterTestContact({ contactId: U, utilisateurId: 'u1' }, ctx);
  assert.equal(ok1.status, 202);
  const ligne = t.outbox().find((l) => l.modele === 'test_envoi');
  assert.equal(ligne.contact_id, U); assert.equal(ligne.type_destinataire, 'pharmacy'); assert.equal(await dechiffrer(t.cle, depuisBytea(ligne.adresse_chiffree)), '111');
  assert.equal((await traiterTestContact({ contactId: U, utilisateurId: 'u1' }, ctx)).status, 429);
  t.h.avancer(61000);
  assert.equal((await traiterTestContact({ contactId: U, utilisateurId: 'u1' }, ctx)).status, 202);
  t.etat.contacts.find((c) => c.id === U).desabonne_le = '2026-10-04';
  t.h.avancer(61000);
  assert.equal((await traiterTestContact({ contactId: U, utilisateurId: 'u1' }, ctx)).status, 409);
  const NV = '00000000-0000-4000-8000-0000000000c2';
  t.etat.contacts.push({ ...contact(NV, 'p1', 'en_attente:x', { verifie_le: null }) });
  assert.equal((await traiterTestContact({ contactId: NV, utilisateurId: 'u1' }, ctx)).corps.erreur, 'telegram_non_active');
});
