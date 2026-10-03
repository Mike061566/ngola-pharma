import { test } from 'node:test';
import assert from 'node:assert/strict';
import { planifierAlertes, heureLocale } from '../../supabase/functions/_shared/planificateur.js';
import { traiterOutbox } from '../../supabase/functions/_shared/traitement.js';
import { creerFournisseurMock } from '../../supabase/functions/_shared/fournisseur-mock.js';
import { chiffrer, dechiffrer, depuisBytea, versBytea } from '../../supabase/functions/_shared/chiffrement.js';
import { cleTest, horloge, magasinAlertesMemoire } from './aide.mjs';

const T0 = '2026-10-05T10:00:00Z';                       // lundi 11:00 au Cameroun
const SEMAINE = Object.fromEntries(['lun', 'mar', 'mer', 'jeu', 'ven', 'sam'].map((j) => [j, { ouv: '08:00', fer: '20:00' }]));
const MED = { id: 'm1', nom: 'Ibuprofène', dosage: '400mg', forme: 'comprimé', restreint: false, classification_validee_le: null, est_demo: true, statut_catalogue: 'actif', ordonnance: false };
const ENV = { ALERT_AUTO_ROUTING: 'true', APP_BASE_URL: 'https://ngola.test', ADMIN_ALERT_EMAIL: 'admin@example.test' };

const pharma = (id, s = {}) => ({ id, nom: `Pharmacie ${id}`, telephone: `222 00 00 ${id.slice(-2)}`, quartier_nom: 'Centre-Ville', statut: 'verifie', est_publiee: true, est_demo: true,
  quartier_id: 'q1', latitude: 3.866, longitude: 11.516, horaires: SEMAINE, est_de_garde: false, garde_jusqu_a: null, contacts_actifs: 1,
  envois_derniere_heure: 0, derniere_sollicitation: null, taux_reponse_30j: null, stock: null, ...s });
const contact = (ph, canal, adresse, s = {}) => ({ id: `c-${ph}-${canal}-${adresse}`, pharmacie_id: ph, canal, adresse, est_principal: false,
  verifie_le: canal === 'telegram' ? '2026-10-01' : null, desabonne_le: null, bloque_le: null, est_contact_demo: true, ...s });
const alerteBase = (s = {}) => ({ id: 'a1', id_public: 'NG-ABCDEFGH', statut: 'new', urgence: 'normal', quartier_id: 'q1', quartier_nom: 'Centre-Ville',
  lat: 3.866, lng: 11.516, vague: 0, cree_le: T0, debut_routage_le: null, expire_le: '2026-10-05T12:00:00Z', premiere_reponse_positive_le: null,
  escalade_le: null, patient_notifie_le: null, second_message_le: null, canal_patient: 'none', contact_patient_chiffre: null, raison_revue: null,
  medicament: MED, ...s });

async function monter({ alertes = [alerteBase()], pharmacies = ['p01', 'p02', 'p03', 'p04', 'p05', 'p06'].map((i) => pharma(i)), contacts, reponses = [], config = {}, env = ENV, demoAdresses = [] } = {}) {
  const h = horloge(T0); const cle = await cleTest(); const journal = [];
  const contactsParDefaut = pharmacies.map((p) => contact(p.id, 'telegram', `tg-${p.id}`));
  const magasin = magasinAlertesMemoire({ config: { mode_application: 'demo', ...config }, alertes, pharmacies, contacts: contacts ?? contactsParDefaut, reponses, demoAdresses, horloge: h });
  const lancer = (e = env) => planifierAlertes({ magasin, cle, env: e, maintenant: h.maintenant, journal: (x) => journal.push(x) });
  const outbox = () => magasin.etat.lignes;
  return { h, cle, magasin, etat: magasin.etat, lancer, outbox, journal };
}
const minutes = (t, m) => t.h.avancer(m * 60000);
const alerte = (t, id = 'a1') => t.etat.alertes.find((a) => a.id === id);

test('vague 1 : 3 pharmacies, une ligne envois_alerte chacune, un message Telegram par contact, alerte en routing', async () => {
  const t = await monter();
  const r = await t.lancer();
  assert.equal(r.vagues, 1); assert.equal(r.envois, 3);
  assert.equal(t.etat.envois.length, 3);
  assert.equal(new Set(t.etat.envois.map((e) => e.code_reponse)).size, 3);
  assert.ok(t.etat.envois.every((e) => /^[0-9A-HJKMNP-TV-Z]{10}$/.test(e.code_reponse) && e.vague === 1));
  assert.equal(t.outbox().length, 3);
  assert.ok(t.outbox().every((l) => l.canal === 'telegram' && l.modele === 'alerte_demande' && l.type_destinataire === 'pharmacy'));
  assert.equal(alerte(t).statut, 'routing'); assert.equal(alerte(t).vague, 1); assert.equal(alerte(t).debut_routage_le, new Date(T0).toISOString());
  const l = t.outbox()[0];
  assert.equal(l.variables.drug, 'Ibuprofène 400mg'); assert.equal(l.variables.quartier, 'Centre-Ville'); assert.equal(l.variables.heure, '11:00');
  assert.equal(l.variables.sur_ordonnance, false);
  assert.equal(l.est_destinataire_demo, true);
});

test('une pharmacie ne reçoit jamais de donnée patient : ni contact, ni empreinte, ni position, ni identifiant interne de l\'alerte', async () => {
  const cle = await cleTest();
  const t = await monter({ alertes: [alerteBase({ canal_patient: 'sms', contact_patient_chiffre: versBytea(await chiffrer(cle, '+237699123456')), empreinte_patient: 'hash-secret', requete_brute: 'texte libre' })] });
  await t.lancer();
  const pharma = t.outbox().filter((l) => l.type_destinataire === 'pharmacy');
  assert.equal(pharma.length, 3);
  const tout = JSON.stringify(pharma.map((l) => ({ variables: l.variables, ref: l.destinataire_ref, base: l.cle_base })));
  assert.doesNotMatch(tout, /699123456|hash-secret|texte libre|3\.866|11\.516|NG-ABCDEFGH|"a1"/);
  assert.deepEqual(Object.keys(pharma[0].variables).sort(), ['base_url', 'code', 'drug', 'envoi_court', 'form', 'heure', 'quartier', 'sur_ordonnance']);
  assert.match(pharma[0].variables.envoi_court, /^[0-9a-z]{8}$/);
});

test('mention d\'ordonnance dans le message pharmacie', async () => {
  const t = await monter({ alertes: [alerteBase({ medicament: { ...MED, ordonnance: true } })] });
  await t.lancer();
  assert.ok(t.outbox().every((l) => l.variables.sur_ordonnance === true));
});

test('canal initial : Telegram vérifié (3 contacts au plus), sinon SMS, sinon email ; contacts bloqués ou désabonnés ignorés', async () => {
  const ph = [pharma('p01'), pharma('p02'), pharma('p03')];
  const contacts = [
    ...['a', 'b', 'c', 'd'].map((x) => contact('p01', 'telegram', `tg-${x}`)), contact('p01', 'sms', '+237600000001'),
    contact('p02', 'telegram', 'tg-nonverifie', { verifie_le: null }), contact('p02', 'telegram', 'tg-bloque', { bloque_le: '2026-10-02' }), contact('p02', 'sms', '+237600000002'),
    contact('p03', 'sms', '+237600000003', { desabonne_le: '2026-10-02' }), contact('p03', 'email', 'p3@example.test'),
  ];
  const t = await monter({ pharmacies: ph, contacts });
  await t.lancer();
  const de = (id) => t.outbox().filter((l) => l.destinataire_ref === id);
  assert.deepEqual([de('p01').length, de('p01')[0].canal], [3, 'telegram']);
  assert.deepEqual(de('p02').map((l) => [l.canal, l.modele]), [['sms', 'alerte_demande_sms']]);
  assert.deepEqual(de('p03').map((l) => [l.canal, l.modele]), [['email', 'alerte_demande_email']]);
});

test('idempotence : relancer le planificateur ne duplique ni envois ni messages', async () => {
  const t = await monter();
  await t.lancer(); await t.lancer(); await t.lancer();
  assert.equal(t.etat.envois.length, 3); assert.equal(t.outbox().length, 3);
});

test('vague 2 à T+10 min : 5 autres pharmacies, aucune déjà sollicitée ; pas avant', async () => {
  const t = await monter({ pharmacies: Array.from({ length: 12 }, (_, i) => pharma(`p${String(i + 1).padStart(2, '0')}`)) });
  await t.lancer();
  const v1 = new Set(t.etat.envois.map((e) => e.pharmacie_id));
  minutes(t, 9); await t.lancer();
  assert.equal(t.etat.envois.length, 3, 'pas de vague 2 à T+9');
  minutes(t, 1); const r = await t.lancer();
  assert.equal(r.vagues, 1); assert.equal(t.etat.envois.length, 8);
  assert.equal(t.etat.envois.filter((e) => e.vague === 2).filter((e) => v1.has(e.pharmacie_id)).length, 0);
  assert.equal(alerte(t).vague, 2);
});

test('escalade à T+30 : message d\'attente au patient + email admin, une seule fois ; expiration à T+2 h avec message', async () => {
  const cle = await cleTest();
  const t = await monter({ alertes: [alerteBase({ canal_patient: 'sms', contact_patient_chiffre: versBytea(await chiffrer(cle, '+237699123456')) })] });
  await t.lancer(); minutes(t, 10); await t.lancer(); minutes(t, 20);
  const r = await t.lancer();
  assert.equal(r.escalades, 1); assert.equal(alerte(t).statut, 'escalated'); assert.ok(alerte(t).escalade_le);
  const attente = t.outbox().filter((l) => l.modele === 'attente_patient');
  assert.equal(attente.length, 1); assert.equal(attente[0].canal, 'sms'); assert.equal(attente[0].type_destinataire, 'patient');
  const admin = t.outbox().filter((l) => l.type_destinataire === 'admin');
  assert.equal(admin.length, 1); assert.equal(admin[0].modele, 'escalade_admin'); assert.equal(admin[0].variables.n, '6');
  assert.equal(admin[0].est_destinataire_demo, false);
  minutes(t, 5); await t.lancer();
  assert.equal(t.outbox().filter((l) => l.modele === 'attente_patient').length, 1, 'une seule fois');
  minutes(t, 85);
  const fin = await t.lancer();
  assert.equal(fin.expirees, 1); assert.equal(alerte(t).statut, 'expired');
  assert.ok(t.etat.envois.every((e) => e.statut === 'expired'));
  const expi = t.outbox().filter((l) => l.modele === 'expiration_patient');
  assert.equal(expi.length, 1);
  assert.equal(await dechiffrer(cle, depuisBytea(expi[0].adresse_chiffree)), '+237699123456');
  minutes(t, 10); await t.lancer();
  assert.equal(t.outbox().filter((l) => l.modele === 'expiration_patient').length, 1);
});

test('escalade sans ADMIN_ALERT_EMAIL : pas d\'email admin, pas d\'erreur', async () => {
  const t = await monter({ env: { ...ENV, ADMIN_ALERT_EMAIL: undefined } });
  await t.lancer(); minutes(t, 30); const r = await t.lancer(env_sans_admin());
  assert.equal(r.escalades, 1); assert.equal(t.outbox().filter((l) => l.type_destinataire === 'admin').length, 0);
});
const env_sans_admin = () => ({ ...ENV, ADMIN_ALERT_EMAIL: undefined });

test('aucun candidat : escalade immédiate vers l\'admin, aucune pharmacie sollicitée', async () => {
  const t = await monter({ pharmacies: [pharma('p01', { statut: 'non_verifie' })] });
  const r = await t.lancer();
  assert.equal(r.envois, 0); assert.equal(r.escalades, 1); assert.equal(alerte(t).statut, 'escalated');
  assert.equal(t.outbox().filter((l) => l.type_destinataire === 'admin').length, 1);
});

test('needs_review : médicament restreint -> message au patient une seule fois, jamais routé ; non reconnu -> pas de message', async () => {
  const cle = await cleTest();
  const patient = { canal_patient: 'sms', contact_patient_chiffre: versBytea(await chiffrer(cle, '+237699123456')) };
  const t = await monter({ alertes: [
    alerteBase({ id: 'r1', statut: 'needs_review', raison_revue: 'restreint', medicament: { ...MED, restreint: true }, ...patient }),
    alerteBase({ id: 'r2', id_public: 'NG-ZZZZZZZZ', statut: 'needs_review', raison_revue: 'non_reconnu', medicament: null, ...patient }),
  ] });
  await t.lancer(); await t.lancer(); minutes(t, 5); await t.lancer();
  assert.equal(t.etat.envois.length, 0);
  const msgs = t.outbox();
  assert.equal(msgs.length, 1); assert.equal(msgs[0].modele, 'restricted_attente'); assert.equal(msgs[0].cle_base, 'alerte:r1:restricted_attente');
});

test('alerte « new » sur un médicament restreint : le garde-fou du planificateur la passe en needs_review (jamais de vague)', async () => {
  const t = await monter({ alertes: [alerteBase({ medicament: { ...MED, restreint: true } })] });
  const r = await t.lancer();
  assert.equal(r.needs_review, 1); assert.equal(t.etat.envois.length, 0);
  assert.equal(alerte(t).statut, 'needs_review'); assert.equal(alerte(t).raison_revue, 'restreint');
});

test('needs_review non traitée : expire à expire_le, avec message au patient', async () => {
  const cle = await cleTest();
  const t = await monter({ alertes: [alerteBase({ statut: 'needs_review', raison_revue: 'non_reconnu', medicament: null, canal_patient: 'sms',
    contact_patient_chiffre: versBytea(await chiffrer(cle, '+237699123456')) })] });
  minutes(t, 121); const r = await t.lancer();
  assert.equal(r.expirees, 1); assert.equal(alerte(t).statut, 'expired');
});

// ── Agrégation ──
const rep = (ph, prix, ilYaS = 0, base = T0) => ({ alerte_id: 'a1', pharmacie_id: ph, prix_fcfa: prix, repondu_le: new Date(new Date(base).getTime() + ilYaS * 1000).toISOString() });

test('deux réponses positives dans la fenêtre de 120 s : UN seul message patient avec les deux pharmacies, prix croissant', async () => {
  const cle = await cleTest();
  const t = await monter({ alertes: [alerteBase({ vague: 1, statut: 'routing', canal_patient: 'sms', contact_patient_chiffre: versBytea(await chiffrer(cle, '+237699123456')) })] });
  t.etat.envois.push(...['p01', 'p02'].map((p, i) => ({ id: `e${i}`, alerte_id: 'a1', pharmacie_id: p, statut: 'sent', envoye_le: T0, relance_sms_le: null })));
  t.etat.reponses.push(rep('p01', 2000, 0), rep('p02', 1500, 60));
  minutes(t, 1); await t.lancer();
  assert.equal(alerte(t).statut, 'answered'); assert.equal(alerte(t).premiere_reponse_positive_le, new Date(T0).toISOString());
  assert.equal(t.outbox().filter((l) => l.modele.startsWith('reponse_patient')).length, 0, 'fenêtre encore ouverte');
  minutes(t, 1); await t.lancer();
  const msg = t.outbox().filter((l) => l.modele.startsWith('reponse_patient'));
  assert.equal(msg.length, 1);
  assert.equal(msg[0].modele, 'reponse_patient_sms');
  assert.equal(msg[0].variables.pharmacie, 'Pharmacie p02'); assert.equal(msg[0].variables.prix, 1500);
  assert.ok(alerte(t).patient_notifie_le);
  await t.lancer(); await t.lancer();
  assert.equal(t.outbox().filter((l) => l.modele.startsWith('reponse_patient')).length, 1, 'aucun doublon');
});

test('agrégation Telegram : liste de 2 pharmacies classées par prix, heure et mention d\'ordonnance', async () => {
  const t = await monter({ alertes: [alerteBase({ vague: 1, statut: 'routing', canal_patient: 'telegram', medicament: { ...MED, ordonnance: true },
    contact_patient_chiffre: versBytea(await chiffrer(await cleTest(), '98765')) })] });
  t.etat.reponses.push(rep('p01', 3000, 0), rep('p02', 1000, 90));
  minutes(t, 3); await t.lancer();
  const msg = t.outbox().find((l) => l.modele === 'reponse_patient');
  assert.deepEqual(msg.variables.pharmacies.map((p) => p.nom), ['Pharmacie p02', 'Pharmacie p01']);
  assert.equal(msg.variables.sur_ordonnance, true); assert.equal(msg.variables.heure, '11:03');
  assert.equal(msg.canal, 'telegram');
});

test('réponse tardive : un second message court, plafonné à 1', async () => {
  const cle = await cleTest();
  const t = await monter({ alertes: [alerteBase({ vague: 1, statut: 'routing', canal_patient: 'sms', contact_patient_chiffre: versBytea(await chiffrer(cle, '+237699123456')) })] });
  t.etat.reponses.push(rep('p01', 2000, 0));
  minutes(t, 3); await t.lancer();
  minutes(t, 5); t.etat.reponses.push(rep('p03', 1800, 480)); await t.lancer();
  assert.equal(t.outbox().filter((l) => l.cle_base === 'alerte:a1:reponse2').length, 1);
  assert.ok(alerte(t).second_message_le);
  minutes(t, 5); t.etat.reponses.push(rep('p04', 1700, 780)); await t.lancer();
  assert.equal(t.outbox().filter((l) => l.cle_base === 'alerte:a1:reponse2').length, 1, 'plafonné à 1');
  assert.equal(t.outbox().filter((l) => l.cle_base === 'alerte:a1:reponse').length, 1);
});

test('après une réponse positive : plus de vague 2 ni d\'escalade ; expiration sans message « aucune pharmacie »', async () => {
  const cle = await cleTest();
  const t = await monter({ alertes: [alerteBase({ vague: 1, statut: 'routing', canal_patient: 'sms', contact_patient_chiffre: versBytea(await chiffrer(cle, '+237699123456')) })] });
  t.etat.reponses.push(rep('p01', 2000, 0));
  minutes(t, 15); await t.lancer();
  assert.equal(t.etat.envois.length, 0); assert.equal(t.outbox().filter((l) => l.modele === 'attente_patient').length, 0);
  minutes(t, 110); await t.lancer();
  assert.equal(alerte(t).statut, 'expired');
  assert.equal(t.outbox().filter((l) => l.modele === 'expiration_patient').length, 0);
});

test('mode démo accéléré : fenêtre et délais divisés par le facteur', async () => {
  const cle = await cleTest();
  const t = await monter({ config: { facteur_temps_demo: 10 }, alertes: [alerteBase({ vague: 1, statut: 'routing', canal_patient: 'sms', contact_patient_chiffre: versBytea(await chiffrer(cle, '+237699123456')) })] });
  t.etat.reponses.push(rep('p01', 2000, 0));
  t.h.avancer(13000); await t.lancer();                       // 13 s > 120 s / 10
  assert.equal(t.outbox().filter((l) => l.modele.startsWith('reponse_patient')).length, 1);
});

test('patient Telegram sans chat_id (pas encore de /start) : aucun message, pas « notifié » ; le message part dès la liaison', async () => {
  const t = await monter({ alertes: [alerteBase({ vague: 1, statut: 'routing', canal_patient: 'telegram', contact_patient_chiffre: null })] });
  t.etat.reponses.push(rep('p01', 2000, 0));
  minutes(t, 3); const r = await t.lancer();
  assert.equal(r.erreurs, 0); assert.equal(t.outbox().length, 0); assert.equal(alerte(t).patient_notifie_le, null);
  alerte(t).contact_patient_chiffre = versBytea(await chiffrer(t.cle, '98765'));        // le patient fait /start
  await t.lancer();
  const msg = t.outbox().filter((l) => l.modele === 'reponse_patient');
  assert.equal(msg.length, 1); assert.equal(msg[0].canal, 'telegram'); assert.ok(alerte(t).patient_notifie_le);
});

test('mode démo : le patient n\'est joignable en vrai que si son adresse est un contact de la liste blanche', async () => {
  const cle = await cleTest();
  const mk = async (demoAdresses) => {
    const t = await monter({ demoAdresses, alertes: [alerteBase({ statut: 'needs_review', raison_revue: 'restreint', medicament: { ...MED, restreint: true }, canal_patient: 'sms',
      contact_patient_chiffre: versBytea(await chiffrer(cle, '+237699123456')) })] });
    await t.lancer(); return t.outbox()[0].est_destinataire_demo;
  };
  assert.equal(await mk([]), false);
  assert.equal(await mk(['+237699123456']), true);
});

// ── SMS de relance ──
test('alerte urgente sans réponse à 5 min : SMS de relance à la même pharmacie ; alerte normale : jamais', async () => {
  const contacts = ['p01', 'p02', 'p03'].flatMap((p) => [contact(p, 'telegram', `tg-${p}`), contact(p, 'sms', `+23760000000${p.slice(-1)}`)]);
  const u = await monter({ contacts, alertes: [alerteBase({ urgence: 'urgent', expire_le: '2026-10-05T11:00:00Z' })] });
  await u.lancer(); minutes(u, 4); await u.lancer();
  assert.equal(u.outbox().filter((l) => l.canal === 'sms').length, 0, 'pas avant 5 min');
  minutes(u, 1); const r = await u.lancer();
  assert.equal(r.relances_sms, 3);
  const sms = u.outbox().filter((l) => l.canal === 'sms');
  assert.ok(sms.every((l) => l.modele === 'alerte_demande_sms' && l.type_destinataire === 'pharmacy'));
  assert.ok(u.etat.envois.filter((e) => e.vague === 1).every((e) => e.relance_sms_le));
  await u.lancer(); assert.equal(u.outbox().filter((l) => l.canal === 'sms').length, 3, 'une seule relance');

  const n = await monter({ contacts, alertes: [alerteBase({ urgence: 'normal' })] });
  await n.lancer(); minutes(n, 9); await n.lancer();
  assert.equal(n.outbox().filter((l) => l.canal === 'sms').length, 0);
});

test('relance SMS : pas après une réponse positive ; exemption de budget seulement pour une pharmacie de garde', async () => {
  const contacts = [contact('p01', 'telegram', 'tg1'), contact('p01', 'sms', '+237600000001'), contact('p02', 'telegram', 'tg2'), contact('p02', 'sms', '+237600000002')];
  const t = await monter({ pharmacies: [pharma('p01', { est_de_garde: true }), pharma('p02')], contacts, alertes: [alerteBase({ urgence: 'urgent', expire_le: '2026-10-05T11:00:00Z' })] });
  await t.lancer(); minutes(t, 5); await t.lancer();
  const sms = t.outbox().filter((l) => l.canal === 'sms');
  assert.equal(sms.find((l) => l.destinataire_ref === 'p01').exempte_budget, true);
  assert.equal(sms.find((l) => l.destinataire_ref === 'p02').exempte_budget, false);
  const r = await monter({ pharmacies: [pharma('p01')], contacts: [contact('p01', 'telegram', 'tg1'), contact('p01', 'sms', '+237600000001')], alertes: [alerteBase({ urgence: 'urgent', expire_le: '2026-10-05T11:00:00Z' })],
    reponses: [rep('p01', 1000, 0)] });
  await r.lancer(); minutes(r, 5); await r.lancer();
  assert.equal(r.outbox().filter((l) => l.canal === 'sms').length, 0);
});

test('un échec Telegram suivi d\'une relance SMS ne produit qu\'un SMS par contact (clé d\'idempotence commune avec le repli)', async () => {
  const contacts = [contact('p01', 'telegram', 'mock-bloque-1'), contact('p01', 'sms', '+237600000001')];
  const t = await monter({ pharmacies: [pharma('p01')], contacts, alertes: [alerteBase({ urgence: 'urgent', expire_le: '2026-10-05T11:00:00Z' })] });
  await t.lancer();
  const fournisseurs = { telegram: creerFournisseurMock('telegram'), sms: creerFournisseurMock('sms'), email: creerFournisseurMock('email') };
  await traiterOutbox({ magasin: t.magasin, fournisseurs, cle: t.cle, maintenant: t.h.maintenant, dormir: t.h.dormir });   // repli : SMS créé par le worker
  assert.equal(t.outbox().filter((l) => l.canal === 'sms').length, 1);
  minutes(t, 5); await t.lancer();                                  // relance : même clé -> pas de doublon
  assert.equal(t.outbox().filter((l) => l.canal === 'sms').length, 1);
});

// ── Verrous et robustesse ──
test('verrou : routage désactivé, ou production sans validation pharmacien -> le planificateur ne fait rien', async () => {
  const off = await monter({ env: { ...ENV, ALERT_AUTO_ROUTING: 'false' } });
  const r1 = await off.lancer({ ...ENV, ALERT_AUTO_ROUTING: 'false' });
  assert.equal(r1.inactif, true); assert.equal(off.etat.envois.length, 0); assert.equal(alerte(off).statut, 'new');
  const prod = await monter({ config: { mode_application: 'production' } });
  const r2 = await prod.lancer(); assert.equal(r2.inactif, true); assert.equal(r2.raison, 'validation_pharmacien_requise');
  prod.etat.validations = 1;
  assert.equal((await prod.lancer()).inactif, false);
});

test('robustesse : l\'erreur d\'une alerte n\'empêche pas le traitement des autres ; le journal ne contient aucune donnée', async () => {
  const t = await monter({ alertes: [alerteBase({ id: 'a1' }), alerteBase({ id: 'a2', id_public: 'NG-BBBBBBBB' })] });
  const orig = t.magasin.creerEnvois;
  t.magasin.creerEnvois = async (id, l) => { if (id === 'a1') throw new Error('base indisponible 203.0.113.7 +237699123456'); return orig(id, l); };
  const r = await t.lancer();
  assert.equal(r.erreurs, 1); assert.equal(alerte(t, 'a2').statut, 'routing');
  assert.doesNotMatch(JSON.stringify(t.journal), /203\.0|699123456|NG-/);
});

test('heureLocale : UTC+1 par défaut, passage de minuit', () => {
  assert.equal(heureLocale(new Date('2026-10-05T10:00:00Z')), '11:00');
  assert.equal(heureLocale(new Date('2026-10-05T23:30:00Z')), '00:30');
  assert.equal(heureLocale(new Date('2026-10-05T10:00:00Z'), 0), '10:00');
});
