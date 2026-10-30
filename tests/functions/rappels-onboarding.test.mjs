import test from 'node:test';
import assert from 'node:assert/strict';
import { planifierRappels, executerRappels, libelleEtape } from '../../supabase/functions/_shared/rappels-onboarding.js';
import { rendre } from '../../supabase/functions/_shared/modeles.js';
import { cleTest, horloge, magasinMemoire } from './aide.mjs';

const cand = (s = {}) => ({ pharmacie_id: 'ph1', demande_id: 'd1', nom: 'Pharmacie Test', email: 'titulaire@exemple.test', jours: 1, deja: [], compte_actif: true, etape: 'telegram', est_demo: true, ...s });

test('planification : un rappel à J+1, J+3, J+7, jamais deux fois', () => {
  assert.deepEqual(planifierRappels([cand({ jours: 0 })]).rappels, []);
  for (const [jours, jalon] of [[1, 1], [2, 1], [3, 3], [6, 3], [7, 7], [29, 7]]) {
    const r = planifierRappels([cand({ jours })]).rappels;
    assert.equal(r.length, 1, `J+${jours}`);
    assert.equal(r[0].jalon, jalon, `J+${jours}`);
  }
  assert.deepEqual(planifierRappels([cand({ jours: 3, deja: [1, 3] })]).rappels, [], 'jalon déjà envoyé');
  assert.equal(planifierRappels([cand({ jours: 4, deja: [1] })]).rappels[0].jalon, 3);
});

test('exécution tardive : seul le dernier jalon échu est envoyé, les précédents sont sautés', () => {
  const [r] = planifierRappels([cand({ jours: 8, deja: [] })]).rappels;
  assert.equal(r.jalon, 7);
  assert.deepEqual(r.sauter, [1, 3]);
});

test('à partir de J+30 : plus de rappel, une seule alerte dormante', () => {
  let p = planifierRappels([cand({ jours: 30, deja: [1, 3, 7] })]);
  assert.deepEqual(p.rappels, []);
  assert.equal(p.dormantes.length, 1);
  p = planifierRappels([cand({ jours: 45, deja: [1, 3, 7, 30] })]);
  assert.deepEqual([p.rappels.length, p.dormantes.length], [0, 0]);
  p = planifierRappels([cand({ jours: 31, deja: [] })]);
  assert.deepEqual([p.rappels.length, p.dormantes.length], [0, 1], 'même sans rappel antérieur : pas de rappel tardif, seulement l\'alerte');
});

// ── Exécution ──
function montage({ candidats, contacts = [] }) {
  const h = horloge();
  const base = magasinMemoire({ horloge: h });
  const enregistres = [], jetons = [];
  const magasin = { ...base, async candidatsRappels() { return candidats; }, async contactsPharmacies() { return contacts; },
    async enregistrerRappel(ph, jalon, canaux) { enregistres.push({ ph, jalon, canaux }); return true; },
    async creerJetonActivation(demande, hash, heures) { jetons.push({ demande, hash, heures }); } };
  return { magasin, base, enregistres, jetons };
}
const env = { APP_BASE_URL: 'https://app.test', ADMIN_ALERT_EMAIL: 'admin@exemple.test' };
const tg = (s = {}) => ({ id: 'c1', pharmacie_id: 'ph1', canal: 'telegram', adresse: '555', verifie_le: '2026-10-01', desabonne_le: null, bloque_le: null, est_contact_demo: false, ...s });

test('rappel : email au titulaire + Telegram aux contacts activés, lien vers l\'étape, jalon enregistré', async () => {
  const m = montage({ candidats: [cand({ jours: 1 })], contacts: [tg(), tg({ id: 'c2', adresse: '556', bloque_le: '2026-10-02' }), tg({ id: 'c3', adresse: '557', verifie_le: null }),
    tg({ id: 'c4', adresse: '558', desabonne_le: '2026-10-02' }), tg({ id: 'c5', pharmacie_id: 'autre' }), tg({ id: 'c6', canal: 'sms', adresse: '+237699' })] });
  const r = await executerRappels({ magasin: m.magasin, env, cle: await cleTest() });
  assert.deepEqual(r, { rappels: 1, sautes: 0, dormantes: 0, emails: 1, telegram: 1, erreurs: 0 });
  const lignes = m.base.etat.lignes;
  assert.equal(lignes.length, 2);
  const email = lignes.find((l) => l.canal === 'email'), telegram = lignes.find((l) => l.canal === 'telegram');
  assert.equal(email.modele, 'onboarding_rappel'); assert.equal(email.type_destinataire, 'pharmacy'); assert.equal(email.est_destinataire_demo, false);
  assert.equal(email.variables.lien, 'https://app.test/pro.html?etape=telegram');
  assert.equal(email.variables.etape_libelle, 'activer Telegram');
  assert.equal(telegram.contact_id, 'c1');
  assert.deepEqual(m.enregistres, [{ ph: 'ph1', jalon: 1, canaux: ['email', 'telegram'] }]);
  assert.equal(m.jetons.length, 0, 'compte actif : pas de jeton d\'activation');
});

test('compte non activé : nouveau lien d\'activation (72 h) par email uniquement ; jamais sur Telegram', async () => {
  const m = montage({ candidats: [cand({ jours: 3, compte_actif: false })], contacts: [tg()] });
  await executerRappels({ magasin: m.magasin, env, cle: await cleTest() });
  assert.equal(m.jetons.length, 1);
  assert.equal(m.jetons[0].heures, 72);
  const email = m.base.etat.lignes.find((l) => l.canal === 'email');
  assert.match(email.variables.lien, /^https:\/\/app\.test\/activer\.html#t=[A-Za-z0-9_-]{20,}$/);
  assert.equal(email.variables.etape_libelle, 'activer votre compte');
  assert.equal(m.base.etat.lignes.filter((l) => l.canal === 'telegram').length, 0, 'le lien d\'activation ne part jamais sur Telegram');
});

test('idempotence : relancer l\'exécution ne recrée aucun message ; contact de démonstration marqué', async () => {
  const m = montage({ candidats: [cand({ jours: 1 })], contacts: [tg({ est_contact_demo: true })] });
  const cle = await cleTest();
  await executerRappels({ magasin: m.magasin, env, cle });
  const r2 = await executerRappels({ magasin: m.magasin, env, cle });
  assert.equal(m.base.etat.lignes.length, 2, 'clés d\'idempotence : pas de doublon');
  assert.equal(r2.emails + r2.telegram, 0);
  assert.equal(m.base.etat.lignes.find((l) => l.canal === 'telegram').est_destinataire_demo, true);
});

test('exécution tardive : un seul message, jalons précédents enregistrés comme sautés', async () => {
  const m = montage({ candidats: [cand({ jours: 8 })] });
  const r = await executerRappels({ magasin: m.magasin, env, cle: await cleTest() });
  assert.equal(m.base.etat.lignes.length, 1);
  assert.equal(r.sautes, 2);
  assert.deepEqual(m.enregistres.map((e) => [e.jalon, e.canaux]), [[7, ['email']], [1, []], [3, []]]);
});

test('dormante : alerte email à l\'admin une seule fois ; sans adresse admin, rien n\'est enregistré', async () => {
  let m = montage({ candidats: [cand({ jours: 31, deja: [1, 3, 7] })] });
  const r = await executerRappels({ magasin: m.magasin, env, cle: await cleTest() });
  assert.equal(r.dormantes, 1);
  const l = m.base.etat.lignes[0];
  assert.deepEqual([l.type_destinataire, l.canal, l.modele], ['admin', 'email', 'onboarding_dormante_admin']);
  assert.deepEqual(m.enregistres, [{ ph: 'ph1', jalon: 30, canaux: ['email'] }]);
  m = montage({ candidats: [cand({ jours: 31, deja: [1, 3, 7] })] });
  await executerRappels({ magasin: m.magasin, env: { APP_BASE_URL: 'https://app.test' }, cle: await cleTest() });
  assert.equal(m.base.etat.lignes.length, 0);
  assert.equal(m.enregistres.length, 0, 'retentera quand ADMIN_ALERT_EMAIL sera configurée');
});

test('une erreur sur une pharmacie n\'empêche pas les autres ; le journal ne contient ni adresse ni contenu', async () => {
  const m = montage({ candidats: [cand({ pharmacie_id: 'ph1', email: '   ' }), cand({ pharmacie_id: 'ph2', demande_id: 'd2', nom: 'Autre' })] });
  const evts = [];
  const r = await executerRappels({ magasin: m.magasin, env, cle: await cleTest(), journal: (e) => evts.push(e) });
  assert.equal(r.erreurs, 1);
  assert.equal(r.rappels, 1);
  assert.doesNotMatch(JSON.stringify(evts), /titulaire@|exemple\.test|Pharmacie Test/);
});

test('modèles de rappel : email et Telegram, étape et lien obligatoires', () => {
  const v = { nom_officine: 'Pharmacie <Test>', etape_libelle: libelleEtape('import'), lien: 'https://app.test/pro.html?etape=import' };
  const e = rendre('onboarding_rappel', 'email', v);
  assert.match(e.sujet, /mise en route/); assert.ok(e.texte.includes(v.lien));
  const t = rendre('onboarding_rappel', 'telegram', v);
  assert.equal(t.format, 'html'); assert.ok(t.texte.includes('&lt;Test&gt;'), 'HTML échappé'); assert.equal(t.boutons[0][0].url, v.lien);
  assert.throws(() => rendre('onboarding_rappel', 'email', { nom_officine: 'x' }), /Variables manquantes/);
  assert.throws(() => rendre('onboarding_rappel', 'sms', v), /n'existe pas pour le canal/);
  assert.match(rendre('onboarding_dormante_admin', 'email', { nom_officine: 'X', jours: '31' }).texte, /31 jours/);
  assert.equal(libelleEtape('inconnue'), libelleEtape('seuil'));
});
