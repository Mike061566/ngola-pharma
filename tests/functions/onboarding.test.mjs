import test from 'node:test';
import assert from 'node:assert/strict';
import { validerChamps, validerHoraires, detecterTypeFichier, validerDocuments, traiterDemande } from '../../supabase/functions/_shared/demande.js';
import { deciderDemande } from '../../supabase/functions/_shared/decision-demande.js';
import { activerCompte, deposerComplements } from '../../supabase/functions/_shared/activation-compte.js';
import { rendre } from '../../supabase/functions/_shared/modeles.js';
import { sha256Hex } from '../../supabase/functions/_shared/securite.js';
import { cleTest, horloge, magasinMemoire } from './aide.mjs';

const QUARTIER = '00000000-0000-0000-0000-00000000f001';
const PDF = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34, 0x0a]);
const JPG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0x10]);
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0]);
const champs = (s = {}) => ({
  nom_pharmacie: 'Pharmacie Test', quartier_id: QUARTIER, adresse: 'Rue 1.234, Centre', telephone_fixe: '222 23 45 67',
  nom_titulaire: 'Dr Jeanne Test', numero_ordre: 'ORD-0042', email_titulaire: 'Jeanne@Exemple.TEST', telephone_mobile: '6 99 12 34 56',
  horaires: { lun: { ouv: '08:00', fer: '20:00' }, dim: null }, participe_garde: true,
  consentement_conditions: true, consentement_messages: true, captcha: 'mock-ok', ...s });
const fichiersOk = () => [{ nature: 'ordre_attestation', octets: PDF }, { nature: 'autorisation_exploitation', octets: JPG }];

test('validerChamps : normalise téléphones, email, texte ; refuse champ inconnu et ordonnance', () => {
  const r = validerChamps(champs());
  assert.equal(r.ok, true);
  assert.equal(r.valeur.telephone_mobile, '+237699123456');
  assert.equal(r.valeur.telephone_fixe, '+237222234567');
  assert.equal(r.valeur.email_titulaire, 'jeanne@exemple.test');
  assert.equal(validerChamps(champs({ extra: 1 })).erreur, 'champ_inconnu');
  assert.equal(validerChamps(champs({ ordonnance_photo: 'x' })).erreur, 'ordonnance_interdite');
});

test('validerChamps : erreurs par champ', () => {
  const cas = [
    [{ nom_pharmacie: 'x' }, 'nom_invalide'], [{ quartier_id: 'abc' }, 'quartier_invalide'], [{ adresse: '' }, 'adresse_invalide'],
    [{ telephone_fixe: '12' }, 'telephone_fixe_invalide'], [{ telephone_mobile: '222 23 45 67' }, 'telephone_mobile_invalide'],
    [{ nom_titulaire: '' }, 'titulaire_invalide'], [{ numero_ordre: '' }, 'ordre_invalide'], [{ email_titulaire: 'pas-un-email' }, 'email_invalide'],
    [{ latitude: 3.8 }, 'position_invalide'], [{ latitude: 99, longitude: 11 }, 'position_invalide'], [{ horaires: {} }, 'horaires_invalides'],
    [{ consentement_messages: false }, 'consentement_requis'], [{ consentement_conditions: undefined }, 'consentement_requis'], [{ captcha: 5 }, 'captcha_invalide'],
  ];
  for (const [surcharge, erreur] of cas) assert.equal(validerChamps(champs(surcharge)).erreur, erreur, JSON.stringify(surcharge));
});

test('validerHoraires : au moins un jour, HH:MM, ouverture avant fermeture, jours connus', () => {
  assert.ok(validerHoraires({ lun: { ouv: '08:00', fer: '20:00' } }));
  assert.equal(validerHoraires({ lun: { ouv: '20:00', fer: '08:00' } }), null);
  assert.equal(validerHoraires({ lun: { ouv: '8h', fer: '20:00' } }), null);
  assert.equal(validerHoraires({ xyz: { ouv: '08:00', fer: '20:00' } }), null);
  assert.equal(validerHoraires({ lun: null }), null);
});

test('type de fichier détecté sur les octets, taille et pièces obligatoires', () => {
  assert.equal(detecterTypeFichier(PDF).mime, 'application/pdf');
  assert.equal(detecterTypeFichier(JPG).ext, 'jpg');
  assert.equal(detecterTypeFichier(PNG).ext, 'png');
  assert.equal(detecterTypeFichier(new TextEncoder().encode('<script>alert(1)</script>')), null);
  assert.equal(validerDocuments([{ nature: 'ordre_attestation', octets: PDF }]).erreur, 'document_manquant');
  assert.equal(validerDocuments([{ nature: 'ordre_attestation', octets: new Uint8Array(5 * 1024 * 1024 + 1).fill(0x25) }, { nature: 'autorisation_exploitation', octets: PDF }]).erreur, 'document_invalide');
  assert.equal(validerDocuments([{ nature: 'ordre_attestation', octets: new TextEncoder().encode('MZ exe') }, { nature: 'autorisation_exploitation', octets: PDF }]).erreur, 'document_invalide');
  assert.equal(validerDocuments([{ nature: 'ordonnance', octets: PDF }]).erreur, 'document_invalide');
  assert.equal(validerDocuments(fichiersOk()).ok, true);
  assert.equal(validerDocuments([], { complements: true }).ok, true);
});

// ── Magasin en mémoire de l'onboarding ──
function magasinOnb({ mode = 'demo', admin = 'adm', refus = null } = {}) {
  const h = horloge();
  const base = magasinMemoire({ horloge: h });
  const e = { demandes: [], depots: [], supprimes: [], soumissions: [], jetonsActivation: [], complements: null, comptes: new Map(), profils: [], liens: [] };
  const m = {
    ...base, e,
    async mode() { return mode; },
    async deposer(chemin, octets, mime) { e.depots.push({ chemin, mime, taille: octets.byteLength }); },
    async supprimer(chemins) { e.supprimes.push(...chemins); },
    async soumettre(payload, empreinteIp) {
      if (refus) return { erreur: refus };
      e.soumissions.push({ payload, empreinteIp }); return { id: 'dem-1', doublon_suspect: false };
    },
    async utilisateurDuJeton(jwt) { return jwt === 'jwt-admin' ? { id: 'adm' } : jwt === 'jwt-pharma' ? { id: 'ph' } : null; },
    async estAdmin(id) { return id === admin; },
    async lireDemande(id) { return e.demandes.find((d) => d.id === id) ?? null; },
    async decider(id, decision, motif) {
      const d = e.demandes.find((x) => x.id === id);
      if (decision === 'approve' && d.checklist < 5) { const err = new Error('x'); err.code = '55000'; err.detail = 'Checklist incomplète'; throw err; }
      if (decision !== 'approve' && !motif) { const err = new Error('x'); err.code = '22023'; throw err; }
      d.statut = decision === 'approve' ? 'approved' : decision === 'reject' ? 'rejected' : 'needs_info';
      return { pharmacie_id: 'ph-1' };
    },
    async creerJetonActivation(id, hash) { e.jetonsActivation.push({ id, hash }); },
    async definirJetonComplements(id, hash, expire) { e.complements = { id, hash, expire }; },
    async marquerInvitation() {},
    async consommerJetonActivation(hash) {
      const j = e.jetonsActivation.find((x) => x.hash === hash && !x.utilise);
      if (!j) return { erreur: 'lien_invalide' };
      j.utilise = true; return { email: 'jeanne@exemple.test', pharmacie_id: 'ph-1', demande_id: j.id };
    },
    async utilisateurParEmail(email) { return e.comptes.get(email) ?? null; },
    async creerUtilisateur(email) { e.comptes.set(email, 'u1'); return 'u1'; },
    async lierProfil(u, ph) { if (e.conflit) return { erreur: 'compte_conflit' }; e.profils.push({ u, ph }); return { ok: true }; },
    async lienConnexion(email, redirect) { e.liens.push(redirect); return 'https://auth.test/lien-court'; },
    async deposerComplements(hash, message, documents) {
      if (!e.complements || e.complements.hash !== hash) return { erreur: 'lien_invalide' };
      e.complementsRecus = { message, documents }; e.complements = null; return { ok: true };
    },
  };
  return m;
}
const ctx = (m, plus = {}) => ({ env: { CAPTCHA_PROVIDER: 'mock', SIGNING_SECRET: 's'.repeat(32), APP_BASE_URL: 'https://app.test' }, ip: '1.2.3.4', magasin: m,
  accuser: async () => {}, ...plus });

test('traiterDemande : captcha, documents déposés, soumission avec empreinte d\'IP (jamais l\'IP)', async () => {
  const m = magasinOnb();
  const r = await traiterDemande({ champs: champs(), fichiers: fichiersOk() }, ctx(m));
  assert.equal(r.status, 201);
  assert.match(r.corps.reference, /^[0-9A-Z-]{1,8}$/);
  assert.equal(m.e.depots.length, 2);
  const s = m.e.soumissions[0];
  assert.equal(s.payload.documents.length, 2);
  assert.ok(s.empreinteIp && !s.empreinteIp.includes('1.2.3.4'));
  assert.equal('captcha' in s.payload, false);
});

test('traiterDemande : captcha invalide, document manquant, limite quotidienne (fichiers nettoyés)', async () => {
  let m = magasinOnb();
  assert.equal((await traiterDemande({ champs: champs({ captcha: 'faux' }), fichiers: fichiersOk() }, ctx(m))).corps.erreur, 'captcha_invalide');
  assert.equal(m.e.depots.length, 0);
  assert.equal((await traiterDemande({ champs: champs(), fichiers: [] }, ctx(m))).corps.erreur, 'document_manquant');
  m = magasinOnb({ refus: 'limite_quotidienne' });
  const r = await traiterDemande({ champs: champs(), fichiers: fichiersOk() }, ctx(m));
  assert.equal(r.status, 429);
  assert.equal(m.e.supprimes.length, 2, 'les justificatifs déposés sont supprimés');
  // en production, le captcha simulé est refusé
  m = magasinOnb({ mode: 'production' });
  assert.equal((await traiterDemande({ champs: champs(), fichiers: fichiersOk() }, ctx(m))).corps.erreur, 'captcha_non_configure');
});

test('traiterDemande : un échec d\'accusé de réception ne perd pas la demande ; erreur de dépôt -> nettoyage', async () => {
  let m = magasinOnb();
  const r = await traiterDemande({ champs: champs(), fichiers: fichiersOk() }, ctx(m, { accuser: async () => { throw new Error('x'); } }));
  assert.equal(r.status, 201);
  m = magasinOnb();
  let n = 0;
  m.deposer = async (chemin) => { n += 1; if (n === 2) throw new Error('boom'); m.e.depots.push({ chemin }); };
  const r2 = await traiterDemande({ champs: champs(), fichiers: fichiersOk() }, ctx(m));
  assert.equal(r2.status, 500);
  assert.equal(m.e.supprimes.length, 1);
  assert.equal(m.e.soumissions.length, 0);
});

// ── Décisions ──
const dem = (s = {}) => ({ id: '11111111-1111-4111-8111-111111111111', statut: 'in_review', nom_pharmacie: 'Pharmacie Test', email_titulaire: 'jeanne@exemple.test', checklist: 5, ...s });
async function decider(m, corps, jwt = 'jwt-admin') {
  return deciderDemande({ jwt, corps: { demande_id: dem().id, ...corps } }, { magasin: m, env: { APP_BASE_URL: 'https://app.test' }, cle: await cleTest() });
}

test('décision : seul l\'admin ; jeton absent ou pharmacien refusé', async () => {
  const m = magasinOnb(); m.e.demandes.push(dem());
  assert.equal((await decider(m, { decision: 'approve' }, null)).status, 403);
  assert.equal((await decider(m, { decision: 'approve' }, 'jwt-pharma')).status, 403);
  assert.equal((await decider(m, { decision: 'approve' }, 'jwt-inconnu')).status, 403);
  assert.equal(m.etat.lignes.length, 0);
});

test('approbation : invitation (jeton 72 h haché) + email enfilé ; lien renvoyé à l\'admin en démo seulement', async () => {
  let m = magasinOnb({ mode: 'demo' }); m.e.demandes.push(dem());
  const r = await decider(m, { decision: 'approve' });
  assert.equal(r.status, 200);
  assert.equal(r.corps.pharmacie_id, 'ph-1');
  assert.match(r.corps.lien_activation, /^https:\/\/app\.test\/activer\.html#t=[A-Za-z0-9_-]{20,}$/);
  const jeton = r.corps.lien_activation.split('#t=')[1];
  assert.equal(m.e.jetonsActivation[0].hash, await sha256Hex(jeton), 'seul le hachage est stocké');
  assert.equal(m.etat.lignes.length, 1);
  assert.equal(m.etat.lignes[0].modele, 'onboarding_approuve');
  assert.equal(m.etat.lignes[0].canal, 'email');
  assert.equal(m.etat.lignes[0].est_destinataire_demo, false);
  m = magasinOnb({ mode: 'production' }); m.e.demandes.push(dem());
  const p = await decider(m, { decision: 'approve' });
  assert.equal(p.corps.lien_activation, undefined, 'jamais le lien à l\'admin en production');
});

test('approbation refusée si la checklist est incomplète (409), motif obligatoire (400)', async () => {
  const m = magasinOnb(); m.e.demandes.push(dem({ checklist: 4 }));
  const r = await decider(m, { decision: 'approve' });
  assert.deepEqual([r.status, r.corps.erreur], [409, 'checklist_incomplete']);
  assert.equal(m.etat.lignes.length, 0, 'aucun email si la décision a échoué');
  const r2 = await decider(m, { decision: 'reject' });
  assert.deepEqual([r2.status, r2.corps.erreur], [400, 'motif_obligatoire']);
});

test('refus et compléments : emails avec motif ; lien de compléments haché', async () => {
  let m = magasinOnb(); m.e.demandes.push(dem());
  assert.equal((await decider(m, { decision: 'reject', motif: 'Hors périmètre' })).status, 200);
  assert.equal(m.etat.lignes[0].modele, 'onboarding_refuse');
  m = magasinOnb(); m.e.demandes.push(dem());
  const r = await decider(m, { decision: 'request_info', motif: 'Attestation illisible' });
  assert.equal(r.status, 200);
  const jeton = r.corps.lien_complements.split('#t=')[1];
  assert.equal(m.e.complements.hash, await sha256Hex(jeton));
  assert.ok(new Date(m.e.complements.expire) > new Date());
  assert.equal(m.etat.lignes[0].modele, 'onboarding_complements');
});

test('renvoi d\'invitation : seulement pour une demande approuvée, nouveau jeton, nouvel email', async () => {
  const m = magasinOnb(); m.e.demandes.push(dem({ statut: 'in_review' }));
  assert.equal((await decider(m, { decision: 'resend_invite' })).status, 409);
  m.e.demandes[0].statut = 'approved';
  assert.equal((await decider(m, { decision: 'resend_invite' })).status, 200);
  assert.equal((await decider(m, { decision: 'resend_invite' })).status, 200);
  assert.equal(m.etat.lignes.length, 2, 'un email par jeton (clé d\'idempotence distincte)');
  assert.notEqual(m.e.jetonsActivation[0].hash, m.e.jetonsActivation[1].hash);
});

test('requête invalide : décision inconnue, identifiant mal formé, demande introuvable', async () => {
  const m = magasinOnb();
  assert.equal((await decider(m, { decision: 'supprimer' })).status, 400);
  assert.equal((await deciderDemande({ jwt: 'jwt-admin', corps: { demande_id: 'x', decision: 'approve' } }, { magasin: m, env: {}, cle: await cleTest() })).status, 400);
  assert.equal((await decider(m, { decision: 'approve' })).status, 404);
});

// ── Activation et compléments ──
test('activation : jeton à usage unique, compte créé, profil lié, lien de connexion', async () => {
  const m = magasinOnb(); m.e.demandes.push(dem({ statut: 'approved' }));
  const r = await decider(m, { decision: 'resend_invite' });
  const jeton = r.corps.lien_activation.split('#t=')[1];
  const a = await activerCompte({ jeton }, { magasin: m, env: { APP_BASE_URL: 'https://app.test' } });
  assert.equal(a.status, 200);
  assert.equal(a.corps.lien_connexion, 'https://auth.test/lien-court');
  assert.deepEqual(m.e.profils, [{ u: 'u1', ph: 'ph-1' }]);
  assert.deepEqual(m.e.liens, ['https://app.test/pro.html']);
  assert.equal((await activerCompte({ jeton }, { magasin: m, env: {} })).status, 410, 'deuxième usage refusé');
  assert.equal((await activerCompte({ jeton: 'court' }, { magasin: m, env: {} })).status, 400);
});

test('activation : conflit de compte (admin ou autre pharmacie) refusé sans connexion', async () => {
  const m = magasinOnb(); m.e.demandes.push(dem({ statut: 'approved' })); m.e.conflit = true;
  const jeton = (await decider(m, { decision: 'resend_invite' })).corps.lien_activation.split('#t=')[1];
  const a = await activerCompte({ jeton }, { magasin: m, env: {} });
  assert.deepEqual([a.status, a.corps.erreur], [409, 'compte_conflit']);
  assert.equal(m.e.liens.length, 0);
});

test('compléments : message et justificatifs, jeton à usage unique, fichiers invalides refusés', async () => {
  const m = magasinOnb(); m.e.demandes.push(dem());
  const jeton = (await decider(m, { decision: 'request_info', motif: 'Attestation illisible' })).corps.lien_complements.split('#t=')[1];
  assert.equal((await deposerComplements({ jeton, message: '', fichiers: [] }, { magasin: m })).corps.erreur, 'reponse_vide');
  assert.equal((await deposerComplements({ jeton, message: 'x', fichiers: [{ octets: new TextEncoder().encode('exe') }] }, { magasin: m })).corps.erreur, 'document_invalide');
  const ok = await deposerComplements({ jeton, message: 'Voici la bonne attestation', fichiers: [{ octets: PNG }] }, { magasin: m });
  assert.equal(ok.status, 200);
  assert.equal(m.e.complementsRecus.documents.length, 1);
  assert.equal((await deposerComplements({ jeton, message: 'encore', fichiers: [] }, { magasin: m })).status, 410);
});

test('modèles d\'onboarding : email seulement, sans donnée personnelle hors nom d\'officine ; variables obligatoires', () => {
  const nom = 'Pharmacie Test';
  for (const [modele, vars] of [['onboarding_recu', {}], ['onboarding_complements', { motif: 'Attestation illisible', lien: 'https://x.test/c#t=abc' }],
    ['onboarding_approuve', { lien: 'https://x.test/a#t=abc' }], ['onboarding_refuse', { motif: 'Hors périmètre' }]]) {
    const r = rendre(modele, 'email', { nom_officine: nom, ...vars });
    assert.ok(r.sujet && r.texte.includes(nom), modele);
    assert.throws(() => rendre(modele, 'sms', { nom_officine: nom, ...vars }), /n'existe pas pour le canal/);
    assert.throws(() => rendre(modele, 'email', {}), /Variables manquantes/);
  }
  assert.match(rendre('onboarding_approuve', 'email', { nom_officine: nom, lien: 'https://x.test/a' }).texte, /72 h/);
});
