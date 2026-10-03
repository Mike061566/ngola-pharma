import { test } from 'node:test';
import assert from 'node:assert/strict';
import { planDispatch, parametresRoutage, raisonNonRoutable, estOuverte, estDeGarde, distanceKm,
  verifierDemarrageRoutage } from '../../supabase/functions/_shared/routage.js';
import { rendre } from '../../supabase/functions/_shared/modeles.js';

const NOW = new Date('2026-10-05T10:00:00Z');             // lundi 11:00 au Cameroun (UTC+1)
const NUIT = new Date('2026-10-05T22:30:00Z');            // lundi 23:30 au Cameroun
const JOUR = 86400000;
const iso = (d) => new Date(d).toISOString();
const ilYa = (jours, base = NOW) => iso(base.getTime() - jours * JOUR);

const SEMAINE = Object.fromEntries(['lun', 'mar', 'mer', 'jeu', 'ven', 'sam'].map((j) => [j, { ouv: '08:00', fer: '20:00' }]));
const profond = (o) => { Object.values(o).forEach((v) => { if (v && typeof v === 'object') profond(v); }); return Object.freeze(o); };

const medDemo = { restreint: false, classification_validee_le: null, est_demo: true, statut_catalogue: 'actif', ordonnance: false };
const medValide = { restreint: false, classification_validee_le: '2026-09-01T00:00:00Z', est_demo: false, statut_catalogue: 'actif', ordonnance: false };
const alerte = (s = {}) => ({ id: 'a1', statut: 'new', urgence: 'normal', quartier_id: 'q1', lat: 3.866, lng: 11.516, vague: 0,
  cree_le: iso(NOW), medicament: medDemo, ...s });
const pharma = (id, s = {}) => ({ id, statut: 'verifie', est_publiee: true, est_demo: true, quartier_id: 'q1', latitude: 3.866, longitude: 11.516,
  horaires: SEMAINE, est_de_garde: false, garde_jusqu_a: null, contacts_actifs: 1, envois_derniere_heure: 0, derniere_sollicitation: null,
  taux_reponse_30j: null, stock: null, ...s });
const CONFIG = { mode_application: 'demo' };
const vague = (plan) => plan.actions.find((a) => a.type === 'envoyer_vague');
const ids = (plan) => vague(plan).pharmacies.map((p) => p.pharmacie_id);
const exclusDe = (plan, id) => plan.audit.exclus.find((e) => e.pharmacie_id === id)?.raisons;

// ── Garde-fou réglementaire (§4.0 / §4.0bis) ──
test('un médicament restreint n\'est jamais routé automatiquement (démo comme production)', () => {
  for (const mode of ['demo', 'production']) {
    const p = planDispatch(alerte({ medicament: { ...medValide, restreint: true } }), [pharma('p1')], { mode_application: mode }, NOW);
    assert.deepEqual(p.actions, [{ type: 'needs_review', raison: 'restreint' }]);
  }
  const demo = planDispatch(alerte({ medicament: { ...medDemo, restreint: true } }), [pharma('p1')], CONFIG, NOW);
  assert.equal(demo.actions[0].raison, 'restreint');
});

test('classification absente = restreint (défaut sûr) ; classification non validée : needs_review en production', () => {
  assert.equal(raisonNonRoutable({ ...medValide, restreint: undefined }, 'production'), 'restreint');
  assert.equal(raisonNonRoutable({ ...medValide, restreint: null }, 'demo'), 'restreint');
  assert.equal(raisonNonRoutable({ ...medValide, classification_validee_le: null, est_demo: false }, 'production'), 'classification_non_validee');
  assert.equal(raisonNonRoutable({ ...medValide, classification_validee_le: null, est_demo: false }, 'demo'), 'classification_non_validee');
  const p = planDispatch(alerte({ medicament: { ...medValide, classification_validee_le: null, est_demo: false } }), [pharma('p1')], { mode_application: 'production' }, NOW);
  assert.equal(p.actions[0].type, 'needs_review');
});

test('mode démo : une fiche de test non restreinte est routée sans validation ; en production la même fiche ne l\'est pas', () => {
  assert.equal(raisonNonRoutable(medDemo, 'demo'), null);
  assert.equal(raisonNonRoutable(medDemo, 'production'), 'classification_non_validee');
  assert.equal(vague(planDispatch(alerte(), [pharma('p1')], CONFIG, NOW)).vague, 1);
});

test('médicament non reconnu ou archivé : needs_review ; validé non restreint : routé', () => {
  assert.equal(planDispatch(alerte({ medicament: null }), [pharma('p1')], CONFIG, NOW).actions[0].raison, 'non_reconnu');
  assert.equal(raisonNonRoutable({ ...medValide, statut_catalogue: 'archive' }, 'production'), 'fiche_archivee');
  assert.equal(raisonNonRoutable(medValide, 'production'), null);
});

test('ordonnance : médicament sur ordonnance et non restreint est routé ; la mention figure dans les messages pharmacie et patient', () => {
  const p = planDispatch(alerte({ medicament: { ...medDemo, ordonnance: true } }), [pharma('p1')], CONFIG, NOW);
  assert.equal(p.sur_ordonnance, true);
  assert.equal(vague(p).vague, 1);
  const msgPharma = rendre('alerte_demande', 'telegram', { drug: 'X', quartier: 'Q', heure: '11:00', code: 'C', envoi_court: 'e', sur_ordonnance: p.sur_ordonnance });
  const msgPatient = rendre('reponse_patient', 'telegram', { drug: 'X', heure: '11:00', sur_ordonnance: p.sur_ordonnance, pharmacies: [{ nom: 'P', prix: 1000, quartier: 'Q', tel: '1' }] });
  assert.match(msgPharma.texte, /ordonnance/);
  assert.match(msgPatient.texte, /ordonnance/);
  assert.equal(planDispatch(alerte(), [pharma('p1')], CONFIG, NOW).sur_ordonnance, false);
});

test('verrou de démarrage : ALERT_AUTO_ROUTING + production sans validation pharmacien = refus', () => {
  assert.deepEqual(verifierDemarrageRoutage({ mode: 'production', routageAuto: true, nbValidationsPharmacien: 0 }),
    { ok: false, actif: false, raison: 'validation_pharmacien_requise' });
  assert.equal(verifierDemarrageRoutage({ mode: 'production', routageAuto: true, nbValidationsPharmacien: 1 }).actif, true);
  assert.equal(verifierDemarrageRoutage({ mode: 'demo', routageAuto: true, nbValidationsPharmacien: 0 }).actif, true);
  assert.equal(verifierDemarrageRoutage({ mode: 'production', routageAuto: false, nbValidationsPharmacien: 0 }).actif, false);
  assert.equal(verifierDemarrageRoutage({ mode: 'production', routageAuto: undefined, nbValidationsPharmacien: 5 }).actif, false);
});

// ── Filtres éliminatoires (§4.1) ──
test('statut : seule une pharmacie vérifiée ET publiée, avec un contact actif, est candidate', () => {
  const p = planDispatch(alerte(), [pharma('ok'), pharma('np', { statut: 'non_verifie' }), pharma('pa', { statut: 'partenaire' }),
    pharma('su', { statut: 'suspendu' }), pharma('nopub', { est_publiee: false }), pharma('sc', { contacts_actifs: 0 })], CONFIG, NOW);
  assert.deepEqual(ids(p), ['ok']);
  assert.deepEqual(exclusDe(p, 'np'), ['non_verifiee']);
  assert.deepEqual(exclusDe(p, 'pa'), ['non_verifiee']);
  assert.deepEqual(exclusDe(p, 'su'), ['non_verifiee']);
  assert.deepEqual(exclusDe(p, 'nopub'), ['non_publiee']);
  assert.deepEqual(exclusDe(p, 'sc'), ['aucun_contact_actif']);
});

test('une pharmacie fermée et non de garde est exclue ; de garde à 23 h, elle est incluse', () => {
  const ferme = pharma('f'), garde = pharma('g', { est_de_garde: true });
  const aNuit = alerte({ cree_le: iso(NUIT) });
  assert.equal(vague(planDispatch(aNuit, [ferme], CONFIG, NUIT)), undefined);
  assert.deepEqual(exclusDe(planDispatch(aNuit, [ferme], CONFIG, NUIT), 'f'), ['fermee']);
  assert.deepEqual(ids(planDispatch(alerte({ cree_le: iso(NUIT) }), [ferme, garde], CONFIG, NUIT)), ['g']);
});

test('de garde : valable jusqu\'à garde_jusqu_a ; expirée, la pharmacie fermée est exclue', () => {
  assert.equal(estDeGarde(pharma('g', { est_de_garde: true, garde_jusqu_a: iso(NUIT.getTime() + 3600000) }), NUIT), true);
  assert.equal(estDeGarde(pharma('g', { est_de_garde: true, garde_jusqu_a: iso(NUIT.getTime() - 1) }), NUIT), false);
  assert.equal(estDeGarde(pharma('g', { est_de_garde: false }), NUIT), false);
  const p = planDispatch(alerte({ cree_le: iso(NUIT) }), [pharma('g', { est_de_garde: true, garde_jusqu_a: iso(NUIT.getTime() - 1) })], CONFIG, NUIT);
  assert.deepEqual(exclusDe(p, 'g'), ['fermee']);
});

test('horaires : bornes, fuseau UTC+1, passage de minuit, horaires inconnus jamais « ouverts »', () => {
  const h = (ouv, fer) => ({ lun: { ouv, fer } });
  const t = (hhmmLocal) => { const [hh, mm] = hhmmLocal.split(':').map(Number); return new Date(Date.UTC(2026, 9, 5, hh - 1, mm)); };   // lundi
  assert.equal(estOuverte(h('08:00', '20:00'), t('08:00')), true, 'ouverture incluse');
  assert.equal(estOuverte(h('08:00', '20:00'), t('07:59')), false);
  assert.equal(estOuverte(h('08:00', '20:00'), t('19:59')), true);
  assert.equal(estOuverte(h('08:00', '20:00'), t('20:00')), false, 'fermeture exclue');
  assert.equal(estOuverte(h('08:00', '20:00'), new Date(Date.UTC(2026, 9, 5, 7, 30))), true, '07:30Z = 08:30 local');
  assert.equal(estOuverte(h('20:00', '02:00'), t('23:00')), true, 'nuit : avant minuit');
  assert.equal(estOuverte({ ...h('20:00', '02:00') }, new Date(Date.UTC(2026, 9, 6, 0, 30)), 60), true, 'nuit : après minuit (horaire de la veille)');
  assert.equal(estOuverte(h('20:00', '02:00'), new Date(Date.UTC(2026, 9, 6, 1, 30)), 60), false, '02:30 local : fermé');
  assert.equal(estOuverte({}, t('10:00')), null);
  assert.equal(estOuverte('{}', t('10:00')), null);
  assert.equal(estOuverte(null, t('10:00')), null);
  assert.equal(estOuverte('pas du json', t('10:00')), null);
  assert.equal(estOuverte(JSON.stringify(h('08:00', '20:00')), t('10:00')), true, 'horaires en texte JSON');
  assert.equal(estOuverte({ mar: { ouv: '08:00', fer: '20:00' } }, t('10:00')), false, 'lundi non listé = fermé');
  assert.equal(estOuverte({ lun: { ouv: '08:00', fer: '08:00' }, mar: { ouv: '08:00', fer: '20:00' } }, t('08:00')), false, 'ouv = fer : fermé ce jour-là');
  assert.equal(estOuverte(h('08:00', '08:00'), t('08:00')), null, 'aucun horaire exploitable : inconnu');
  const inconnu = planDispatch(alerte(), [pharma('i', { horaires: {} })], CONFIG, NOW);
  assert.deepEqual(exclusDe(inconnu, 'i'), ['horaires_inconnus']);
});

test('cooldown : à max_envois_par_heure demandes dans l\'heure, la pharmacie est exclue ; à 5 elle reste candidate', () => {
  const p = planDispatch(alerte(), [pharma('c5', { envois_derniere_heure: 5 }), pharma('c6', { envois_derniere_heure: 6 }), pharma('c9', { envois_derniere_heure: 9 })], CONFIG, NOW);
  assert.deepEqual(ids(p), ['c5']);
  assert.deepEqual(exclusDe(p, 'c6'), ['cooldown']);
  const p2 = planDispatch(alerte(), [pharma('c6', { envois_derniere_heure: 6 })], { ...CONFIG, max_envois_par_heure: 10 }, NOW);
  assert.deepEqual(ids(p2), ['c6']);
});

test('rupture confirmée il y a 1 jour : exclue ; il y a 5 jours : incluse « à confirmer » ; seuil exact de 3 jours : inclus', () => {
  const rupt = (jours) => pharma('r', { stock: { statut_stock: 'rupture', confirme_le: ilYa(jours) } });
  const p1 = planDispatch(alerte(), [rupt(1)], CONFIG, NOW);
  assert.deepEqual(exclusDe(p1, 'r'), ['rupture_recente']);
  const p5 = planDispatch(alerte(), [rupt(5)], CONFIG, NOW);
  assert.deepEqual(ids(p5), ['r']);
  assert.equal(vague(p5).pharmacies[0].detail_score.a_confirmer, true);
  assert.deepEqual(ids(planDispatch(alerte(), [rupt(3)], CONFIG, NOW)), ['r']);
  assert.deepEqual(exclusDe(planDispatch(alerte(), [rupt(2.99)], CONFIG, NOW), 'r'), ['rupture_recente']);
  assert.deepEqual(ids(planDispatch(alerte(), [rupt(2.99)], { ...CONFIG, rupture_recente_jours: 2 }, NOW)), ['r']);
  const arch = planDispatch(alerte(), [pharma('x', { stock: { statut_stock: 'archive', confirme_le: ilYa(0.1) } })], CONFIG, NOW);
  assert.deepEqual(ids(arch), ['x'], 'une ligne archivée équivaut à aucun enregistrement');
});

test('en production, une pharmacie de démonstration est exclue ; en démo elle est routable', () => {
  const prod = planDispatch(alerte({ medicament: medValide }), [pharma('d', { est_demo: true }), pharma('r', { est_demo: false })], { mode_application: 'production' }, NOW);
  assert.deepEqual(ids(prod), ['r']);
  assert.deepEqual(exclusDe(prod, 'd'), ['demo_en_production']);
  assert.deepEqual(ids(planDispatch(alerte(), [pharma('d', { est_demo: true })], CONFIG, NOW)), ['d']);
});

test('plusieurs raisons d\'exclusion sont toutes consignées (audit)', () => {
  const p = planDispatch(alerte(), [pharma('ok'), pharma('x', { statut: 'non_verifie', est_publiee: false, contacts_actifs: 0, envois_derniere_heure: 6 })], CONFIG, NOW);
  assert.deepEqual(exclusDe(p, 'x'), ['non_verifiee', 'non_publiee', 'aucun_contact_actif', 'cooldown']);
});

// ── Score (§4.2) ──
const score = (ph, a = alerte(), cfg = CONFIG, now = NOW) => vague(planDispatch(a, [ph], cfg, now)).pharmacies[0];
const points = (s, cle) => s.detail_score.criteres.find((c) => c.cle === cle)?.points;

test('score : grille de stock (40 / 30 / 15 / 10) et bornes de 3 et 7 jours', () => {
  const st = (statut_stock, jours) => pharma('s', { stock: { statut_stock, confirme_le: ilYa(jours) } });
  assert.equal(points(score(st('en_stock', 0)), 'stock_confirme_3j'), 40);
  assert.equal(points(score(st('en_stock', 3)), 'stock_confirme_3j'), 40, '3 jours exactement');
  assert.equal(points(score(st('en_stock', 3.01)), 'stock_confirme_7j'), 30);
  assert.equal(points(score(st('en_stock', 7)), 'stock_confirme_7j'), 30, '7 jours exactement');
  assert.equal(points(score(st('en_stock', 7.01)), 'stock_perime'), 10);
  assert.equal(points(score(st('faible', 1)), 'stock_confirme_3j'), 40, 'stock faible = en stock');
  assert.equal(points(score(pharma('s')), 'aucun_enregistrement'), 15);
  assert.equal(points(score(st('en_stock', -2)), 'stock_confirme_3j'), 40, 'date future : traitée comme à l\'instant');
});

test('score : même quartier +30, quartier adjacent (liste) +15, adjacent par distance ≤ 3 km, autre +5', () => {
  const sans = { stock: null, taux_reponse_30j: null };
  assert.equal(points(score(pharma('a', sans)), 'meme_quartier'), 30);
  assert.equal(points(score(pharma('b', { ...sans, quartier_id: 'q2' }), alerte({ quartiers_adjacents: ['q2'] })), 'quartier_adjacent'), 15);
  assert.equal(points(score(pharma('c', { ...sans, quartier_id: 'q3', latitude: 3.88, longitude: 11.516 })), 'quartier_adjacent'), 15);
  assert.equal(points(score(pharma('d', { ...sans, quartier_id: 'q3', latitude: 3.95, longitude: 11.516 })), 'autre_quartier'), 5);
  assert.equal(points(score(pharma('e', { ...sans, quartier_id: 'q3', latitude: null, longitude: null })), 'autre_quartier'), 5, 'sans GPS : autre');
  assert.equal(points(score(pharma('f', { ...sans, quartier_id: 'q3', latitude: 3.88, longitude: 11.516 }), alerte({ lat: null, lng: null })), 'autre_quartier'), 5);
});

test('score : taux de réponse × 20 (0,5 par défaut pour une nouvelle pharmacie), borné à [0, 1]', () => {
  assert.equal(points(score(pharma('a', { taux_reponse_30j: null })), 'taux_reponse'), 10);
  assert.equal(points(score(pharma('a', { taux_reponse_30j: 1 })), 'taux_reponse'), 20);
  assert.equal(points(score(pharma('a', { taux_reponse_30j: 0 })), 'taux_reponse'), 0);
  assert.equal(points(score(pharma('a', { taux_reponse_30j: 0.35 })), 'taux_reponse'), 7);
  assert.equal(points(score(pharma('a', { taux_reponse_30j: 4 })), 'taux_reponse'), 20);
  assert.equal(points(score(pharma('a', { taux_reponse_30j: -1 })), 'taux_reponse'), 0);
});

test('score : de garde hors horaires +10 (pas si ouverte) ; équité −5 par demande au-delà de 3', () => {
  assert.equal(points(score(pharma('g', { est_de_garde: true }), alerte({ cree_le: iso(NUIT) }), CONFIG, NUIT), 'garde_hors_horaires'), 10);
  assert.equal(points(score(pharma('g', { est_de_garde: true })), 'garde_hors_horaires'), undefined, 'ouverte : pas de bonus de garde');
  assert.equal(points(score(pharma('e', { envois_derniere_heure: 3 })), 'equite'), undefined);
  assert.equal(points(score(pharma('e', { envois_derniere_heure: 4 })), 'equite'), -5);
  assert.equal(points(score(pharma('e', { envois_derniere_heure: 5 })), 'equite'), -10);
});

test('score total : somme des critères, plafonné à 100, jamais négatif ; poids lus dans la configuration', () => {
  const max = score(pharma('m', { stock: { statut_stock: 'en_stock', confirme_le: ilYa(1) }, taux_reponse_30j: 1, est_de_garde: true }));
  assert.equal(max.score, 90, 'ouverte : pas de bonus de garde → 40+30+20');
  assert.equal(max.detail_score.brut, 90);
  const fort = score(pharma('m', { stock: { statut_stock: 'en_stock', confirme_le: ilYa(1) }, taux_reponse_30j: 1 }), alerte(), { ...CONFIG, score_poids: { meme_quartier: 80 } });
  assert.equal(fort.detail_score.brut, 140);
  assert.equal(fort.score, 100, 'plafonné');
  const neg = score(pharma('n', { quartier_id: 'qz', latitude: 4.5, longitude: 12, taux_reponse_30j: 0, envois_derniere_heure: 5 }), alerte(), { ...CONFIG, rupture_recente_jours: 0, score_poids: { autre_quartier: 0, aucun_enregistrement: 0 } });
  assert.equal(neg.score, 0, 'plancher à 0');
  assert.ok(neg.detail_score.brut < 0);
});

test('à stock égal, la pharmacie du même quartier passe devant celle d\'un autre quartier', () => {
  const p = planDispatch(alerte(), [pharma('loin', { quartier_id: 'q9', latitude: 4.3, longitude: 12 }), pharma('proche')], CONFIG, NOW);
  assert.deepEqual(ids(p), ['proche', 'loin']);
  assert.equal(p.audit.candidats[0].rang, 1);
});

test('départage : à score égal, la pharmacie la moins récemment sollicitée d\'abord, puis l\'identifiant', () => {
  const p = planDispatch(alerte(), [
    pharma('c', { derniere_sollicitation: ilYa(0.5) }), pharma('b', { derniere_sollicitation: ilYa(2) }),
    pharma('a', { derniere_sollicitation: ilYa(2) }), pharma('z', { derniere_sollicitation: null })], CONFIG, NOW);
  assert.deepEqual(ids(p), ['z', 'a', 'b']);
});

// ── Vagues et échéances (§4.3) ──
const dix = (n) => Array.from({ length: n }, (_, i) => pharma(`p${String(i).padStart(2, '0')}`));

test('vague 1 : les 3 meilleures ; vague 2 à T+10 min : les 5 suivantes, sans doublon avec la vague 1', () => {
  const ph = dix(10);
  const v1 = planDispatch(alerte(), ph, CONFIG, NOW);
  assert.equal(ids(v1).length, 3);
  assert.equal(vague(v1).vague, 1);
  const deja = ids(v1);
  const avant = planDispatch(alerte({ vague: 1, deja_sollicitees: deja }), ph, CONFIG, new Date(NOW.getTime() + 9 * 60000));
  assert.equal(vague(avant), undefined, 'pas de vague 2 avant T+10 min');
  const v2 = planDispatch(alerte({ vague: 1, statut: 'routing', deja_sollicitees: deja }), ph, CONFIG, new Date(NOW.getTime() + 10 * 60000));
  assert.equal(vague(v2).vague, 2);
  assert.equal(ids(v2).length, 5);
  assert.equal(ids(v2).filter((i) => deja.includes(i)).length, 0);
  assert.ok(v2.audit.exclus.every((e) => e.raisons.includes('deja_sollicitee')));
});

test('pas de vague 2 après une réponse positive ; pas de vague 3', () => {
  const t = new Date(NOW.getTime() + 15 * 60000);
  const rep = planDispatch(alerte({ vague: 1, statut: 'answered', premiere_reponse_positive_le: iso(NOW) }), dix(10), CONFIG, t);
  assert.deepEqual(rep.actions, []);
  const rep2 = planDispatch(alerte({ vague: 1, statut: 'routing', premiere_reponse_positive_le: iso(NOW) }), dix(10), CONFIG, t);
  assert.deepEqual(rep2.actions, []);
  assert.deepEqual(planDispatch(alerte({ vague: 2, statut: 'routing' }), dix(10), CONFIG, t).actions, []);
});

test('escalade à T+30 min (une seule fois) ; expiration à T+2 h (prioritaire)', () => {
  const a = (s) => alerte({ vague: 2, statut: 'routing', ...s });
  const min = (m) => new Date(NOW.getTime() + m * 60000);
  assert.deepEqual(planDispatch(a(), dix(3), CONFIG, min(29)).actions, []);
  assert.deepEqual(planDispatch(a(), dix(3), CONFIG, min(30)).actions, [{ type: 'escalader', raison: 'sans_reponse' }]);
  assert.deepEqual(planDispatch(a({ statut: 'escalated' }), dix(3), CONFIG, min(45)).actions, [], 'déjà escaladée');
  assert.deepEqual(planDispatch(a({ statut: 'escalated' }), dix(3), CONFIG, min(120)).actions, [{ type: 'expirer' }]);
  assert.deepEqual(planDispatch(a(), dix(3), CONFIG, min(300)).actions, [{ type: 'expirer' }], 'rattrapage après une panne : expiration seule');
  assert.deepEqual(planDispatch(a({ statut: 'answered', premiere_reponse_positive_le: iso(NOW) }), dix(3), CONFIG, min(120)).actions, [{ type: 'expirer' }]);
  assert.deepEqual(planDispatch(a({ statut: 'answered', premiere_reponse_positive_le: iso(NOW) }), dix(3), CONFIG, min(60)).actions, [], 'répondue : plus d\'escalade');
});

test('urgence : tous les délais sont divisés par deux (vague 2 à 5 min, escalade à 15 min, expiration à 1 h)', () => {
  const u = (s) => alerte({ urgence: 'urgent', vague: 1, statut: 'routing', ...s });
  const min = (m) => new Date(NOW.getTime() + m * 60000);
  assert.equal(vague(planDispatch(u(), dix(10), CONFIG, min(4.9))), undefined);
  assert.equal(vague(planDispatch(u(), dix(10), CONFIG, min(5))).vague, 2);
  assert.ok(planDispatch(u({ vague: 2 }), dix(3), CONFIG, min(15)).actions.some((a) => a.type === 'escalader'));
  assert.deepEqual(planDispatch(u({ vague: 2 }), dix(3), CONFIG, min(60)).actions, [{ type: 'expirer' }]);
});

test('facteur de temps de démonstration : accélère les délais en démo seulement', () => {
  const a = alerte({ vague: 1, statut: 'routing' });
  const t1 = new Date(NOW.getTime() + 60000);             // T+1 min = T+10 min ÷ 10
  assert.equal(vague(planDispatch(a, dix(10), { ...CONFIG, facteur_temps_demo: 10 }, t1)).vague, 2);
  assert.equal(vague(planDispatch(a, dix(10), { ...CONFIG, facteur_temps_demo: 1 }, t1)), undefined);
  const prod = planDispatch({ ...a, medicament: medValide }, dix(10), { mode_application: 'production', facteur_temps_demo: 10 }, t1);
  assert.equal(vague(prod), undefined, 'ignoré en production');
});

test('expire_le persisté fait foi ; sinon calculé depuis le début du routage', () => {
  const a = alerte({ vague: 2, statut: 'routing', expire_le: iso(NOW.getTime() + 50 * 60000) });
  assert.deepEqual(planDispatch(a, [], CONFIG, new Date(NOW.getTime() + 50 * 60000)).actions, [{ type: 'expirer' }]);
  const b = alerte({ vague: 2, statut: 'routing', debut_routage_le: iso(NOW.getTime() - 100 * 60000), cree_le: iso(NOW.getTime() - 200 * 60000) });
  assert.equal(planDispatch(b, [], CONFIG, new Date(NOW.getTime() + 20 * 60000)).actions[0].type, 'expirer');
});

test('aucun candidat : action aucun_candidat et escalade immédiate (vague 1) ; rien d\'envoyé', () => {
  const p = planDispatch(alerte(), [pharma('x', { statut: 'non_verifie' })], CONFIG, NOW);
  assert.deepEqual(p.actions, [{ type: 'aucun_candidat', vague: 1 }, { type: 'escalader', raison: 'aucun_candidat' }]);
  assert.deepEqual(planDispatch(alerte(), [], CONFIG, NOW).actions.map((a) => a.type), ['aucun_candidat', 'escalader']);
  const v2 = planDispatch(alerte({ vague: 1, statut: 'escalated' }), [], CONFIG, new Date(NOW.getTime() + 11 * 60000));
  assert.deepEqual(v2.actions, [{ type: 'aucun_candidat', vague: 2 }]);
});

test('états terminaux ou en revue admin : aucune action automatique', () => {
  for (const statut of ['fulfilled', 'expired', 'cancelled', 'needs_review']) {
    assert.deepEqual(planDispatch(alerte({ statut }), dix(3), CONFIG, NOW).actions, [], statut);
  }
});

test('prochaine échéance : vague 2, puis escalade, puis expiration', () => {
  const v1 = planDispatch(alerte(), dix(5), CONFIG, NOW);
  assert.equal(v1.prochaine_echeance, iso(NOW.getTime() + 10 * 60000));
  const apres2 = planDispatch(alerte({ vague: 2, statut: 'routing' }), dix(5), CONFIG, new Date(NOW.getTime() + 11 * 60000));
  assert.equal(apres2.prochaine_echeance, iso(NOW.getTime() + 30 * 60000));
  const esc = planDispatch(alerte({ vague: 2, statut: 'escalated' }), dix(5), CONFIG, new Date(NOW.getTime() + 31 * 60000));
  assert.equal(esc.prochaine_echeance, iso(NOW.getTime() + 120 * 60000));
});

// ── Audit (§4.5) ──
test('audit : détail du score par critère, rang, exclus avec raisons ; format compatible envois_alerte', () => {
  const p = planDispatch(alerte(), [pharma('a', { stock: { statut_stock: 'en_stock', confirme_le: ilYa(1) } }), pharma('x', { statut: 'non_verifie' })], CONFIG, NOW);
  const e = vague(p).pharmacies[0];
  assert.deepEqual(Object.keys(e).sort(), ['detail_score', 'pharmacie_id', 'score', 'vague']);
  assert.equal(typeof e.score, 'number');
  assert.ok(Number.isFinite(e.score) && e.score >= 0 && e.score <= 100);
  assert.ok(e.detail_score.criteres.length >= 3);
  assert.equal(e.detail_score.rang, 1);
  assert.deepEqual(p.audit.exclus, [{ pharmacie_id: 'x', raisons: ['non_verifiee'] }]);
  JSON.stringify(p);   // sérialisable (jsonb)
});

// ── Pureté et déterminisme ──
test('déterminisme : même entrée, même plan, quel que soit l\'ordre des pharmacies', () => {
  const ph = [pharma('p1', { taux_reponse_30j: 0.9 }), pharma('p2', { quartier_id: 'q2', latitude: 3.9, longitude: 11.52 }), pharma('p3'),
    pharma('p4', { stock: { statut_stock: 'en_stock', confirme_le: ilYa(5) } }), pharma('p5', { derniere_sollicitation: ilYa(1) }), pharma('p6', { statut: 'non_verifie' })];
  const a = planDispatch(alerte(), ph, CONFIG, NOW);
  const b = planDispatch(alerte(), [...ph].reverse(), CONFIG, NOW);
  const c = planDispatch(alerte(), ph, CONFIG, NOW);
  assert.deepEqual(a, c);
  assert.deepEqual(a, b);
});

test('pureté : les entrées gelées ne sont pas modifiées, aucune lecture d\'horloge', () => {
  const entrees = profond({ a: alerte(), ph: dix(6), cfg: { ...CONFIG, score_poids: { meme_quartier: 31 } } });
  const reel = Date.now; Date.now = () => { throw new Error('Date.now interdit'); };
  const aleatoire = Math.random; Math.random = () => { throw new Error('Math.random interdit'); };
  try { planDispatch(entrees.a, entrees.ph, entrees.cfg, NOW); } finally { Date.now = reel; Math.random = aleatoire; }
});

test('configuration : valeurs absentes, invalides ou de mauvais type -> défauts ; mode inconnu = démo', () => {
  const p = parametresRoutage({ vague1_taille: 'trois', vague2_delai_min: -5, score_poids: { meme_quartier: 'x', autre_quartier: 9 }, mode_application: 'prod', facteur_temps_demo: 0.2 });
  assert.equal(p.vague1_taille, 3); assert.equal(p.vague2_delai_min, 10);
  assert.equal(p.poids.meme_quartier, 30); assert.equal(p.poids.autre_quartier, 9);
  assert.equal(p.mode_application, 'demo'); assert.equal(p.facteur_temps_demo, 1);
  assert.equal(parametresRoutage().vague2_taille, 5);
  assert.equal(parametresRoutage(null).escalade_min, 30);
  const taille = planDispatch(alerte(), dix(10), { ...CONFIG, vague1_taille: 2 }, NOW);
  assert.equal(ids(taille).length, 2);
});

test('distanceKm : formule de haversine ; coordonnées manquantes -> null', () => {
  assert.ok(Math.abs(distanceKm(0, 0, 0, 1) - 111.19) < 0.1);
  assert.equal(distanceKm(3.8, 11.5, 3.8, 11.5), 0);
  assert.equal(distanceKm(null, 11, 3, 11), null);
  assert.equal(distanceKm('3', 11, 3, 11), null);
});
