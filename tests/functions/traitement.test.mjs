import { test } from 'node:test';
import assert from 'node:assert/strict';
import { traiterOutbox, lireParametres } from '../../supabase/functions/_shared/traitement.js';
import { creerFournisseurMock } from '../../supabase/functions/_shared/fournisseur-mock.js';
import { creerFournisseurs } from '../../supabase/functions/_shared/fournisseurs.js';
import { enfiler, cleIdempotence } from '../../supabase/functions/_shared/file-sortie.js';
import { ErreurFournisseur } from '../../supabase/functions/_shared/erreurs.js';
import { dechiffrer, depuisBytea } from '../../supabase/functions/_shared/chiffrement.js';
import { cleTest, horloge, ligneOutbox, magasinMemoire } from './aide.mjs';

const contactsPharmacie = (extra = []) => [
  { id: 'c-tg', pharmacie_id: 'ph1', canal: 'telegram', adresse: '123456', verifie_le: '2026-10-01', desabonne_le: null, bloque_le: null, est_contact_demo: true },
  { id: 'c-sms', pharmacie_id: 'ph1', canal: 'sms', adresse: '+237600000001', verifie_le: null, desabonne_le: null, bloque_le: null, est_contact_demo: true },
  { id: 'c-mail', pharmacie_id: 'ph1', canal: 'email', adresse: 'pharma@example.test', verifie_le: null, desabonne_le: null, bloque_le: null, est_contact_demo: false },
  ...extra,
];

async function monter({ lignes = [], contacts = contactsPharmacie(), config = {}, payants = 0, comportements = {} } = {}) {
  const cle = await cleTest();
  const h = horloge();
  const journal = [];
  const fournisseurs = {
    telegram: creerFournisseurMock('telegram', { comportement: comportements.telegram }),
    sms: creerFournisseurMock('sms', { comportement: comportements.sms }),
    email: creerFournisseurMock('email', { comportement: comportements.email }),
  };
  const lignesPretes = await Promise.all(lignes.map((l) => (typeof l === 'function' ? l(cle) : l)));
  const magasin = magasinMemoire({ config, lignes: lignesPretes, contacts, payants, horloge: h });
  const lancer = (opts = {}) => traiterOutbox({ magasin, fournisseurs, cle, maintenant: h.maintenant, dormir: h.dormir,
    journal: (e) => journal.push(e), ...opts });
  return { cle, h, journal, fournisseurs, magasin, lancer, etat: magasin.etat };
}
const ligne = (s) => (cle) => ligneOutbox(cle, s);

test('envoi nominal Telegram : adresse déchiffrée pour le fournisseur, ligne « sent », journal sans donnée personnelle', async () => {
  const t = await monter({ lignes: [ligne({ id: 'o1', adresse: '987654321' })] });
  const r = await t.lancer();
  assert.equal(r.envoyes, 1);
  assert.equal(t.etat.lignes[0].statut, 'sent');
  assert.equal(t.fournisseurs.telegram.envoyes[0].adresse, '987654321');
  assert.match(t.fournisseurs.telegram.envoyes[0].texte, /Ibuprofène/);
  assert.equal(t.etat.lignes[0].id_discussion_fournisseur, '987654321');
  const tout = JSON.stringify(t.journal);
  assert.doesNotMatch(tout, /987654321|Ibuprofène|Centre-Ville|ABC123/);
});

test('mode démo : destinataire hors liste blanche -> suppressed_demo SANS appel au fournisseur ; liste blanche -> envoyé', async () => {
  const t = await monter({ config: { mode_application: 'demo' },
    lignes: [ligne({ id: 'hors', est_destinataire_demo: false }), ligne({ id: 'blanc', est_destinataire_demo: true, adresse: '555' })] });
  const r = await t.lancer();
  assert.equal(r.supprimes_demo, 1);
  assert.equal(t.etat.lignes.find((l) => l.id === 'hors').statut, 'suppressed_demo');
  assert.equal(t.etat.lignes.find((l) => l.id === 'blanc').statut, 'sent');
  assert.equal(t.fournisseurs.telegram.envoyes.length, 1);
  assert.equal(t.fournisseurs.telegram.envoyes[0].adresse, '555');
});

test('mode inconnu ou absent = démo (comportement sûr)', async () => {
  assert.equal(lireParametres({}).mode, 'demo');
  assert.equal(lireParametres({ mode_application: 'prod' }).mode, 'demo');
  assert.equal(lireParametres({ mode_application: 'production' }).mode, 'production');
  const t = await monter({ config: { mode_application: undefined }, lignes: [ligne({ est_destinataire_demo: false })] });
  await t.lancer();
  assert.equal(t.etat.lignes[0].statut, 'suppressed_demo');
});

test('échec transitoire : relances à +30 s, +2 min, +5 min, puis échec et repli SMS', async () => {
  let appels = 0;
  const t = await monter({ lignes: [ligne({ id: 'o1', contact_id: 'c-tg' })],
    comportements: { telegram: () => { appels += 1; throw new ErreurFournisseur('réseau', { type: 'transitoire' }); } } });
  const l = t.etat.lignes[0];
  let r = await t.lancer();
  assert.equal(r.reessais, 1); assert.equal(l.tentatives, 1);
  assert.equal(new Date(l.prochaine_tentative_le).getTime() - t.h.maintenant().getTime(), 30000);
  r = await t.lancer(); assert.equal(r.traites, 0, 'pas encore dû');
  t.h.avancer(30000); r = await t.lancer();
  assert.equal(new Date(l.prochaine_tentative_le).getTime() - t.h.maintenant().getTime(), 120000);
  t.h.avancer(120000); await t.lancer();
  assert.equal(new Date(l.prochaine_tentative_le).getTime() - t.h.maintenant().getTime(), 300000);
  t.h.avancer(300000); r = await t.lancer();
  assert.equal(appels, 4, '1 envoi + 3 relances');
  assert.equal(l.statut, 'failed');
  assert.equal(r.replis, 1);
  const sms = t.etat.lignes.find((x) => x.canal === 'sms');
  assert.equal(sms.modele, 'alerte_demande_sms');
  assert.equal(sms.statut, 'sent', 'le repli est traité dans la même passe');
  assert.deepEqual(sms.canaux_tentes, ['telegram']);
});

test('Telegram bloqué (403) : contact marqué bloqué, repli immédiat sur SMS (clé d\'idempotence dérivée)', async () => {
  const t = await monter({ lignes: [ligne({ id: 'o1', contact_id: 'c-tg', adresse: 'mock-bloque-1' })] });
  const r = await t.lancer();
  assert.equal(t.etat.lignes[0].statut, 'failed');
  assert.equal(t.etat.lignes[0].derniere_erreur, 'contact_bloque');
  assert.ok(t.etat.contacts.find((c) => c.id === 'c-tg').bloque_le);
  assert.equal(r.reessais, 0);
  const sms = t.etat.lignes.find((x) => x.canal === 'sms');
  assert.equal(sms.cle_idempotence, cleIdempotence('envoi1', 'sms', 'alerte_demande_sms', 'c-sms'));
  assert.equal(sms.est_destinataire_demo, true);
  assert.equal(await dechiffrer(t.cle, depuisBytea(sms.adresse_chiffree)), '+237600000001');
});

test('chaîne de repli complète : telegram -> sms -> email -> fin ; email non listé en démo = supprimé', async () => {
  const t = await monter({ config: { mode_application: 'demo' },
    lignes: [ligne({ id: 'o1', contact_id: 'c-tg', adresse: 'mock-echec-permanent' })],
    comportements: { sms: () => { throw new ErreurFournisseur('rejet', { type: 'permanente' }); } },
    contacts: contactsPharmacie() });
  const r = await t.lancer();           // telegram échoue -> sms échoue -> email, tout dans la même passe
  const email = t.etat.lignes.find((x) => x.canal === 'email');
  assert.deepEqual(email.canaux_tentes.sort(), ['sms', 'telegram']);
  assert.equal(email.est_destinataire_demo, false);
  assert.equal(r.supprimes_demo, 1);
  assert.equal(email.statut, 'suppressed_demo');
  assert.equal(t.fournisseurs.email.envoyes.length, 0);
  assert.equal(t.etat.lignes.length, 3, 'pas de 4e canal');
});

test('repli : contacts désabonnés, bloqués, ou Telegram non vérifié sont ignorés ; plusieurs contacts = plusieurs lignes', async () => {
  const contacts = [
    { id: 'tg', pharmacie_id: 'ph1', canal: 'telegram', adresse: '1', verifie_le: '2026-10-01', desabonne_le: null, bloque_le: null, est_contact_demo: true },
    { id: 's1', pharmacie_id: 'ph1', canal: 'sms', adresse: '+237600000001', verifie_le: null, desabonne_le: '2026-10-02', bloque_le: null, est_contact_demo: true },
    { id: 's2', pharmacie_id: 'ph1', canal: 'sms', adresse: '+237600000002', verifie_le: null, desabonne_le: null, bloque_le: '2026-10-02', est_contact_demo: true },
    { id: 'e1', pharmacie_id: 'ph1', canal: 'email', adresse: 'a@example.test', verifie_le: null, desabonne_le: null, bloque_le: null, est_contact_demo: true },
    { id: 'e2', pharmacie_id: 'ph1', canal: 'email', adresse: 'b@example.test', verifie_le: null, desabonne_le: null, bloque_le: null, est_contact_demo: true },
  ];
  const t = await monter({ contacts, lignes: [ligne({ id: 'o1', contact_id: 'tg', adresse: 'mock-echec-permanent' })] });
  await t.lancer();
  const filles = t.etat.lignes.filter((l) => l.id !== 'o1');
  assert.deepEqual(filles.map((l) => l.canal), ['email', 'email']);
  assert.equal(new Set(filles.map((l) => l.cle_idempotence)).size, 2);
});

test('pas de repli pour un patient ; aucune relance pour un échec permanent', async () => {
  const t = await monter({ lignes: [ligne({ id: 'p1', type_destinataire: 'patient', destinataire_ref: null, modele: 'attente_patient', canal: 'telegram',
    variables: { drug: 'X' }, adresse: 'mock-echec-permanent' })] });
  const r = await t.lancer();
  assert.equal(t.etat.lignes.length, 1);
  assert.equal(t.etat.lignes[0].statut, 'failed');
  assert.equal(r.replis, 0);
});

test('429 : reporté après retry_after, sans consommer de tentative', async () => {
  const t = await monter({ lignes: [ligne({ id: 'o1', adresse: 'mock-limite' })] });
  const r = await t.lancer();
  assert.equal(r.reportes, 1);
  assert.equal(t.etat.lignes[0].tentatives, 0);
  assert.equal(t.etat.lignes[0].statut, 'queued');
  assert.equal(new Date(t.etat.lignes[0].prochaine_tentative_le).getTime() - t.h.maintenant().getTime(), 2000);
});

test('1 message/s par discussion Telegram : le second est reporté d\'1 s sans compter de tentative, puis envoyé', async () => {
  const t = await monter({ lignes: [ligne({ id: 'a', adresse: '42' }), ligne({ id: 'b', adresse: '42' })] });
  let r = await t.lancer();
  assert.equal(r.envoyes, 1); assert.equal(r.reportes, 1);
  const b = t.etat.lignes.find((l) => l.id === 'b');
  assert.equal(b.tentatives, 0);
  t.h.avancer(1000); r = await t.lancer();
  assert.equal(b.statut, 'sent');
});

test('plafond global : 20 messages/s (espacement de 50 ms entre envois)', async () => {
  const lignes = Array.from({ length: 5 }, (_, i) => ligne({ id: `m${i}`, adresse: `${100 + i}` }));
  const t = await monter({ lignes });
  const avant = t.h.maintenant().getTime();
  await t.lancer();
  assert.equal(t.etat.lignes.every((l) => l.statut === 'sent'), true);
  assert.ok(t.h.maintenant().getTime() - avant >= 4 * 50);
});

test('budget quotidien : SMS annulé au-delà du plafond sauf exemption ; email et Telegram non bloqués', async () => {
  const sms = { type_destinataire: 'pharmacy', canal: 'sms', modele: 'alerte_demande_sms', adresse: '+237600000001' };
  const t = await monter({ payants: 50, config: { budget_messages_jour: 50 }, lignes: [
    ligne({ id: 's1', ...sms }), ligne({ id: 's2', ...sms, exempte_budget: true }),
    ligne({ id: 'e1', canal: 'email', modele: 'alerte_demande_email', adresse: 'a@example.test' }),
    ligne({ id: 't1', adresse: '77' }),
  ] });
  const r = await t.lancer();
  const statut = (id) => t.etat.lignes.find((l) => l.id === id);
  assert.equal(statut('s1').statut, 'cancelled'); assert.equal(statut('s1').derniere_erreur, 'budget_depasse');
  assert.equal(statut('s2').statut, 'sent');
  assert.equal(statut('e1').statut, 'sent');
  assert.equal(statut('t1').statut, 'sent');
  assert.equal(r.annules, 1);
});

test('budget : le compteur local tient compte des envois payants du lot en cours', async () => {
  const sms = { canal: 'sms', modele: 'alerte_demande_sms', adresse: '+237600000001' };
  const t = await monter({ payants: 1, config: { budget_messages_jour: 2 }, lignes: [ligne({ id: 'a', ...sms }), ligne({ id: 'b', ...sms })] });
  await t.lancer();
  assert.deepEqual(t.etat.lignes.map((l) => l.statut).sort(), ['cancelled', 'sent']);
});

test('contact désabonné entre-temps : annulé ; contact bloqué : repli', async () => {
  const contacts = contactsPharmacie();
  contacts.find((c) => c.id === 'c-tg').desabonne_le = '2026-10-04';
  const t = await monter({ contacts, lignes: [ligne({ id: 'o1', contact_id: 'c-tg' })] });
  const r = await t.lancer();
  assert.equal(t.etat.lignes[0].statut, 'cancelled'); assert.equal(r.annules, 1);
  assert.equal(t.fournisseurs.telegram.envoyes.length, 0);
});

test('modèle invalide : échec définitif sans repli ; adresse illisible aussi', async () => {
  const t = await monter({ lignes: [ligne({ id: 'o1', variables: { drug: 'X' } }), ligne({ id: 'o2', adresse_chiffree: '\\x0011' })] });
  await t.lancer();
  assert.equal(t.etat.lignes.find((l) => l.id === 'o1').derniere_erreur, 'modele_invalide');
  assert.equal(t.etat.lignes.find((l) => l.id === 'o2').derniere_erreur, 'adresse_illisible');
  assert.equal(t.etat.lignes.length, 2);
});

test('message qui fait planter le worker : borné par le nombre de tentatives', async () => {
  const t = await monter({ lignes: [ligne({ id: 'o1', tentatives: 4 })] });   // 5e prélèvement (max = 4)
  await t.lancer();
  assert.equal(t.etat.lignes[0].statut, 'failed');
  assert.equal(t.etat.lignes[0].derniere_erreur, 'trop_de_tentatives');
  assert.equal(t.fournisseurs.telegram.envoyes.length, 0);
});

test('bail : une ligne prélevée n\'est pas reprise tant que le bail court, puis redevient disponible', async () => {
  const t = await monter({ lignes: [ligne({ id: 'o1' })] });
  const premier = await t.magasin.reclamer(10, 120);
  assert.equal(premier.length, 1); assert.equal(premier[0].tentatives, 1);
  assert.equal((await t.magasin.reclamer(10, 120)).length, 0);
  t.h.avancer(121000);
  const reprise = await t.magasin.reclamer(10, 120);
  assert.equal(reprise.length, 1); assert.equal(reprise[0].tentatives, 2);
});

test('erreur d\'infrastructure sur une ligne : journalisée sans casser le lot', async () => {
  const t = await monter({ lignes: [ligne({ id: 'a', adresse: '1' }), ligne({ id: 'b', adresse: '2' })] });
  const orig = t.magasin.marquerEnvoye;
  let n = 0;
  t.magasin.marquerEnvoye = async (...a) => { n += 1; if (n === 1) throw new Error('base indisponible 1.2.3.4'); return orig(...a); };
  await t.lancer();
  assert.ok(t.journal.some((e) => e.evt === 'erreur_ligne'));
  assert.doesNotMatch(JSON.stringify(t.journal), /1\.2\.3\.4/);
  assert.equal(t.etat.lignes.filter((l) => l.statut === 'sent').length, 1);
});

test('durée maximale : le worker rend la main', async () => {
  const lignes = Array.from({ length: 3 }, (_, i) => ligne({ id: `m${i}`, adresse: `${i}` }));
  const t = await monter({ lignes, config: { worker_lot_taille: 1 } });
  const r = await t.lancer({ dureeMaxMs: 40 });   // 20/s : 50 ms par envoi
  assert.ok(r.traites >= 1 && r.traites < 3);
});

// ── Mise en file ──
test('enfiler : adresse chiffrée en base, doublon ignoré, modèle ou variables invalides refusés avant la file', async () => {
  const cle = await cleTest(); const h = horloge();
  const magasin = magasinMemoire({ horloge: h });
  const msg = { typeDestinataire: 'pharmacy', destinataireRef: 'ph1', canal: 'telegram', modele: 'alerte_demande', adresse: '123456', cleBase: 'envoi9',
    contactId: 'c-tg', estDestinataireDemo: true,
    variables: { drug: 'X', quartier: 'Q', heure: '10:00', code: 'C', envoi_court: 'e' } };
  const a = await enfiler(magasin, cle, msg);
  const b = await enfiler(magasin, cle, msg);
  assert.equal(a.cree, true); assert.equal(b.cree, false);
  assert.equal(a.cleIdempotence, 'envoi9:telegram:alerte_demande:c-tg');
  assert.equal(magasin.etat.lignes.length, 1);
  assert.doesNotMatch(magasin.etat.lignes[0].adresse_chiffree, /123456/);
  await assert.rejects(enfiler(magasin, cle, { ...msg, variables: {} }), /Variables manquantes/);
  await assert.rejects(enfiler(magasin, cle, { ...msg, modele: 'nexistepas' }), /Modèle inconnu/);
  await assert.rejects(enfiler(magasin, cle, { ...msg, cleBase: '' }), /cleBase/);
  await assert.rejects(enfiler(magasin, cle, { ...msg, adresse: ' ' }), /adresse/);
  assert.equal(magasin.etat.lignes.length, 1);
});

// ── Fournisseurs ──
test('fournisseurs : mock par défaut ; toute autre valeur refusée (aucun envoi réel avant la PR 7)', () => {
  const f = creerFournisseurs({});
  assert.deepEqual(Object.keys(f), ['telegram', 'sms', 'email']);
  assert.ok(f.telegram.mock && f.sms.mock && f.email.mock);
  assert.throws(() => creerFournisseurs({ TELEGRAM_PROVIDER: 'telegram' }), /indisponible/);
  assert.throws(() => creerFournisseurs({ SMS_PROVIDER: 'twilio' }), /indisponible/);
});

test('mock : n\'écrit ni adresse ni contenu dans le journal ; modifierMessage réservé à Telegram', async () => {
  const lignes = []; const mock = creerFournisseurMock('telegram', { journal: (e) => lignes.push(e) });
  await mock.envoyer({ adresse: '999888777', texte: 'secret médical', idOutbox: 'o1', modele: 'alerte_demande' });
  assert.doesNotMatch(JSON.stringify(lignes), /999888777|secret/);
  await mock.modifierMessage({ idDiscussion: '1', idMessage: 'm', texte: 't' });
  assert.equal(mock.modifies.length, 1);
  await assert.rejects(creerFournisseurMock('sms').modifierMessage({}), ErreurFournisseur);
});
