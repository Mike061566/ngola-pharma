// Moteur de routage des alertes (SPEC 2 §4) : FONCTION PURE.
//   planDispatch(alerte, pharmacies, config, now) -> plan
// Aucun accès réseau, base, horloge ni aléa : tout vient des arguments, les entrées ne sont jamais modifiées, et le
// même jeu de données donne toujours le même plan (départages compris). Le plan est une liste d'ACTIONS que le
// planificateur (PR 4) exécute ; ce module ne fait rien lui-même.
//
// Entrées
//  alerte : { id, statut, urgence, quartier_id, lat, lng, quartiers_adjacents?: [id], vague (vagues déjà envoyées),
//             cree_le, debut_routage_le?, expire_le?, premiere_reponse_positive_le?, deja_sollicitees?: [pharmacie_id],
//             medicament: null | { restreint, classification_validee_le, est_demo, statut_catalogue, ordonnance } }
//  pharmacies : [{ id, statut, est_publiee, est_demo?, quartier_id, latitude, longitude, horaires, est_de_garde,
//             garde_jusqu_a, contacts_actifs (nombre), envois_derniere_heure, derniere_sollicitation,
//             taux_reponse_30j (null = nouvelle pharmacie), stock: null | { statut_stock, confirme_le } }]
//             `stock` concerne le médicament de l'alerte, dans cette pharmacie.
//  config : contenu de config_routage ({ cle: valeur }) ; les clés absentes ou invalides prennent leur défaut.
//  now : Date.
const MIN = 60000;
const JOUR = 86400000;
const JOURS = ['dim', 'lun', 'mar', 'mer', 'jeu', 'ven', 'sam'];
const STATUTS_TERMINAUX = ['fulfilled', 'expired', 'cancelled'];

export const DEFAUTS = Object.freeze({
  vague1_taille: 3, vague2_taille: 5, vague2_delai_min: 10, escalade_min: 30, expiration_min: 120,
  max_envois_par_heure: 6, rupture_recente_jours: 3, facteur_delai_urgent: 0.5, facteur_temps_demo: 1,
  mode_application: 'demo',
  stock_frais_jours: 3, stock_tolere_jours: 7, rayon_adjacent_km: 3, equite_seuil_par_heure: 3,
  taux_reponse_defaut: 0.5, decalage_horaire_min: 60,            // Cameroun : UTC+1, sans heure d'été
  score_poids: Object.freeze({
    stock_confirme_3j: 40, stock_confirme_7j: 30, aucun_enregistrement: 15, stock_perime: 10,
    meme_quartier: 30, quartier_adjacent: 15, autre_quartier: 5, taux_reponse_max: 20,
    garde_hors_horaires: 10, penalite_par_demande_au_dela_de_3: -5,
  }),
});

const nombre = (v, defaut, { min = 0 } = {}) => (typeof v === 'number' && Number.isFinite(v) && v >= min ? v : defaut);

/** Normalise config_routage : jamais d'exception, valeurs invalides remplacées par les défauts. */
export function parametresRoutage(config = {}) {
  const c = config || {};
  const poidsSrc = c.score_poids && typeof c.score_poids === 'object' ? c.score_poids : {};
  const poids = {};
  for (const [k, def] of Object.entries(DEFAUTS.score_poids)) poids[k] = typeof poidsSrc[k] === 'number' && Number.isFinite(poidsSrc[k]) ? poidsSrc[k] : def;
  return {
    vague1_taille: Math.floor(nombre(c.vague1_taille, DEFAUTS.vague1_taille)),
    vague2_taille: Math.floor(nombre(c.vague2_taille, DEFAUTS.vague2_taille)),
    vague2_delai_min: nombre(c.vague2_delai_min, DEFAUTS.vague2_delai_min),
    escalade_min: nombre(c.escalade_min, DEFAUTS.escalade_min),
    expiration_min: nombre(c.expiration_min, DEFAUTS.expiration_min),
    max_envois_par_heure: nombre(c.max_envois_par_heure, DEFAUTS.max_envois_par_heure),
    rupture_recente_jours: nombre(c.rupture_recente_jours, DEFAUTS.rupture_recente_jours),
    facteur_delai_urgent: nombre(c.facteur_delai_urgent, DEFAUTS.facteur_delai_urgent, { min: 0.0001 }),
    facteur_temps_demo: nombre(c.facteur_temps_demo, DEFAUTS.facteur_temps_demo, { min: 1 }),
    mode_application: c.mode_application === 'production' ? 'production' : 'demo',   // inconnu = démo (sûr)
    stock_frais_jours: nombre(c.stock_frais_jours, DEFAUTS.stock_frais_jours),
    stock_tolere_jours: nombre(c.stock_tolere_jours, DEFAUTS.stock_tolere_jours),
    rayon_adjacent_km: nombre(c.rayon_adjacent_km, DEFAUTS.rayon_adjacent_km),
    equite_seuil_par_heure: nombre(c.equite_seuil_par_heure, DEFAUTS.equite_seuil_par_heure),
    taux_reponse_defaut: Math.min(1, nombre(c.taux_reponse_defaut, DEFAUTS.taux_reponse_defaut)),
    decalage_horaire_min: typeof c.decalage_horaire_min === 'number' && Number.isFinite(c.decalage_horaire_min) ? c.decalage_horaire_min : DEFAUTS.decalage_horaire_min,
    poids,
  };
}

// ── Verrou de démarrage (SPEC 2 §4.0, « verrou de production ») ──
/** Le routage automatique refuse de démarrer en production sans validation pharmacien. */
export function verifierDemarrageRoutage({ mode, routageAuto, nbValidationsPharmacien }) {
  if (routageAuto !== true) return { ok: true, actif: false, raison: 'routage_auto_desactive' };
  if (mode === 'production' && !(nbValidationsPharmacien > 0)) {
    return { ok: false, actif: false, raison: 'validation_pharmacien_requise' };
  }
  return { ok: true, actif: true, raison: null };
}

// ── Garde-fou réglementaire (§4.0, §4.0bis) ──
/** null si routable automatiquement, sinon le code de la raison (l'alerte passe en `needs_review`). */
export function raisonNonRoutable(medicament, mode) {
  if (!medicament) return 'non_reconnu';
  if (medicament.statut_catalogue && medicament.statut_catalogue !== 'actif') return 'fiche_archivee';
  if (medicament.restreint !== false) return 'restreint';          // absent ou true : restreint (défaut sûr)
  if (medicament.classification_validee_le) return null;
  if (mode === 'demo' && medicament.est_demo === true) return null; // exception encadrée du mode démo
  return 'classification_non_validee';
}

// ── Horaires ──
const enMinutes = (hhmm) => {
  const m = /^(\d{1,2}):(\d{2})/.exec(String(hhmm || ''));
  if (!m) return null;
  const h = Number(m[1]), mi = Number(m[2]);
  return h <= 24 && mi < 60 ? h * 60 + mi : null;
};

/** true / false, ou null si les horaires ne sont pas renseignés (inconnu : jamais traité comme « ouvert »). */
export function estOuverte(horaires, now, decalageMin = DEFAUTS.decalage_horaire_min) {
  let h = horaires;
  if (typeof h === 'string') { try { h = JSON.parse(h); } catch { return null; } }
  if (!h || typeof h !== 'object' || Array.isArray(h)) return null;
  const jours = JOURS.map((j) => {
    const d = h[j];
    const o = d ? enMinutes(d.ouv) : null, f = d ? enMinutes(d.fer) : null;
    return o !== null && f !== null && o !== f ? { o, f } : null;   // ouv = fer : fermé
  });
  if (jours.every((j) => j === null)) return null;
  const local = new Date(now.getTime() + decalageMin * MIN);
  const jour = local.getUTCDay();
  const m = local.getUTCHours() * 60 + local.getUTCMinutes();
  const auj = jours[jour], hier = jours[(jour + 6) % 7];
  if (auj) { if (auj.f > auj.o ? m >= auj.o && m < auj.f : m >= auj.o) return true; }
  if (hier && hier.f < hier.o && m < hier.f) return true;           // horaire de la veille qui passe minuit
  return false;
}

export function estDeGarde(ph, now) {
  if (ph.est_de_garde !== true) return false;
  if (!ph.garde_jusqu_a) return true;
  return new Date(ph.garde_jusqu_a).getTime() > now.getTime();
}

export function distanceKm(lat1, lng1, lat2, lng2) {
  const nums = [lat1, lng1, lat2, lng2];
  if (nums.some((x) => typeof x !== 'number' || !Number.isFinite(x))) return null;
  const rad = (d) => (d * Math.PI) / 180;
  const a = Math.sin(rad(lat2 - lat1) / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(rad(lng2 - lng1) / 2) ** 2;
  return 6371 * 2 * Math.asin(Math.min(1, Math.sqrt(a)));
}

const arrondi = (x) => Math.round(x * 100) / 100;

// ── Évaluation d'une pharmacie : exclusions (§4.1) puis score (§4.2) ──
function evaluer(ph, alerte, p, now) {
  const raisons = [];
  if (ph.statut !== 'verifie') raisons.push('non_verifiee');
  if (ph.est_publiee !== true) raisons.push('non_publiee');
  if (p.mode_application === 'production' && ph.est_demo === true) raisons.push('demo_en_production');
  if (!(ph.contacts_actifs >= 1)) raisons.push('aucun_contact_actif');
  if ((alerte.deja_sollicitees || []).includes(ph.id)) raisons.push('deja_sollicitee');

  const ouverte = estOuverte(ph.horaires, now, p.decalage_horaire_min);
  const garde = estDeGarde(ph, now);
  if (!garde && ouverte !== true) raisons.push(ouverte === null ? 'horaires_inconnus' : 'fermee');

  if (nombre(ph.envois_derniere_heure, 0) >= p.max_envois_par_heure) raisons.push('cooldown');

  const st = ph.stock && ph.stock.statut_stock !== 'archive' ? ph.stock : null;   // archivé = pas d'enregistrement
  const age = st ? Math.max(0, (now.getTime() - new Date(st.confirme_le).getTime()) / JOUR) : null;
  if (st && st.statut_stock === 'rupture' && age < p.rupture_recente_jours) raisons.push('rupture_recente');
  if (raisons.length) return { exclu: raisons };

  const w = p.poids;
  const criteres = [];
  const ajouter = (cle, points) => criteres.push({ cle, points });
  let aConfirmer = false;

  if (!st) ajouter('aucun_enregistrement', w.aucun_enregistrement);
  else if (st.statut_stock === 'rupture') { ajouter('stock_perime', w.stock_perime); aConfirmer = true; }   // « out » ancien : à confirmer
  else if (age <= p.stock_frais_jours) ajouter('stock_confirme_3j', w.stock_confirme_3j);
  else if (age <= p.stock_tolere_jours) ajouter('stock_confirme_7j', w.stock_confirme_7j);
  else ajouter('stock_perime', w.stock_perime);

  if (ph.quartier_id && ph.quartier_id === alerte.quartier_id) ajouter('meme_quartier', w.meme_quartier);
  else {
    const d = distanceKm(alerte.lat, alerte.lng, ph.latitude, ph.longitude);
    const adjacent = (alerte.quartiers_adjacents || []).includes(ph.quartier_id) || (d !== null && d <= p.rayon_adjacent_km);
    ajouter(adjacent ? 'quartier_adjacent' : 'autre_quartier', adjacent ? w.quartier_adjacent : w.autre_quartier);
  }

  const taux = ph.taux_reponse_30j === null || ph.taux_reponse_30j === undefined ? p.taux_reponse_defaut
    : Math.min(1, Math.max(0, ph.taux_reponse_30j));
  ajouter('taux_reponse', arrondi(taux * w.taux_reponse_max));
  if (garde && ouverte !== true) ajouter('garde_hors_horaires', w.garde_hors_horaires);
  const exces = Math.max(0, nombre(ph.envois_derniere_heure, 0) - p.equite_seuil_par_heure);
  if (exces > 0) ajouter('equite', exces * w.penalite_par_demande_au_dela_de_3);

  const brut = arrondi(criteres.reduce((s, c) => s + c.points, 0));
  return { score: arrondi(Math.min(100, Math.max(0, brut))), brut, criteres, a_confirmer: aConfirmer };
}

/** Classement : score décroissant, puis pharmacie la moins récemment sollicitée, puis id (déterminisme). */
function classer(candidats, pharmaciesParId) {
  const t = (id) => { const d = pharmaciesParId.get(id).derniere_sollicitation; return d ? new Date(d).getTime() : -Infinity; };
  return [...candidats].sort((a, b) => b.score - a.score || t(a.pharmacie_id) - t(b.pharmacie_id) || (a.pharmacie_id < b.pharmacie_id ? -1 : a.pharmacie_id > b.pharmacie_id ? 1 : 0));
}

// ── Échéances (§4.3) ──
function echeances(alerte, p) {
  const facteurUrgence = alerte.urgence === 'urgent' ? p.facteur_delai_urgent : 1;
  const accel = p.mode_application === 'demo' ? p.facteur_temps_demo : 1;       // accélération de démonstration seulement en démo
  const d = (min) => (min * facteurUrgence * MIN) / accel;
  const t0 = new Date(alerte.debut_routage_le || alerte.cree_le).getTime();
  const expire = alerte.expire_le ? new Date(alerte.expire_le).getTime() : t0 + d(p.expiration_min);
  return { vague2: t0 + d(p.vague2_delai_min), escalade: t0 + d(p.escalade_min), expiration: expire };
}

/**
 * @returns {{ version, alerte_id, mode, sur_ordonnance, actions: Array, prochaine_echeance: string|null, audit: object|null }}
 * Actions : needs_review{raison} | expirer | envoyer_vague{vague, pharmacies:[{pharmacie_id, vague, score, detail_score}]}
 *           | aucun_candidat{vague} | escalader{raison}
 */
export function planDispatch(alerte, pharmacies, config, now) {
  const p = parametresRoutage(config);
  const t = now.getTime();
  const plan = { version: 1, alerte_id: alerte.id, mode: p.mode_application,
    sur_ordonnance: alerte.medicament ? alerte.medicament.ordonnance === true : false,
    actions: [], prochaine_echeance: null, audit: null };

  if (STATUTS_TERMINAUX.includes(alerte.statut) || alerte.statut === 'needs_review') return plan;   // revue admin : rien d'automatique

  const ech = echeances(alerte, p);
  if (alerte.statut === 'new') {
    const raison = raisonNonRoutable(alerte.medicament, p.mode_application);
    if (raison) { plan.actions.push({ type: 'needs_review', raison }); return plan; }
  }
  if (t >= ech.expiration) { plan.actions.push({ type: 'expirer' }); return plan; }

  const positive = Boolean(alerte.premiere_reponse_positive_le) || alerte.statut === 'answered';
  const vague = alerte.vague || 0;
  let vagueAEnvoyer = null;
  if (!positive) {
    if (vague === 0) vagueAEnvoyer = 1;
    else if (vague === 1 && t >= ech.vague2) vagueAEnvoyer = 2;
  }

  let escaladeDejaFaite = alerte.statut === 'escalated';
  if (vagueAEnvoyer) {
    const parId = new Map(pharmacies.map((ph) => [ph.id, ph]));
    const candidats = [], exclus = [];
    for (const ph of pharmacies) {
      const r = evaluer(ph, alerte, p, now);
      if (r.exclu) exclus.push({ pharmacie_id: ph.id, raisons: r.exclu });
      else candidats.push({ pharmacie_id: ph.id, score: r.score, brut: r.brut, criteres: r.criteres, a_confirmer: r.a_confirmer });
    }
    const classes = classer(candidats, parId).map((c, i) => ({ ...c, rang: i + 1 }));
    exclus.sort((a, b) => (a.pharmacie_id < b.pharmacie_id ? -1 : 1));
    const taille = vagueAEnvoyer === 1 ? p.vague1_taille : p.vague2_taille;
    const choisies = classes.slice(0, taille);
    plan.audit = { candidats: classes, exclus, taille_vague: taille };
    if (choisies.length === 0) {
      plan.actions.push({ type: 'aucun_candidat', vague: vagueAEnvoyer });
      if (vagueAEnvoyer === 1 && !escaladeDejaFaite) { plan.actions.push({ type: 'escalader', raison: 'aucun_candidat' }); escaladeDejaFaite = true; }
    } else {
      plan.actions.push({ type: 'envoyer_vague', vague: vagueAEnvoyer, pharmacies: choisies.map((c) => ({
        pharmacie_id: c.pharmacie_id, vague: vagueAEnvoyer, score: c.score,
        detail_score: { criteres: c.criteres, brut: c.brut, rang: c.rang, a_confirmer: c.a_confirmer,
          candidats: classes.length, exclus: exclus.length } })) });
    }
  }
  if (!positive && !escaladeDejaFaite && t >= ech.escalade) plan.actions.push({ type: 'escalader', raison: 'sans_reponse' });

  const vagueEffective = vagueAEnvoyer || vague;
  const escaladeFaite = escaladeDejaFaite || plan.actions.some((a) => a.type === 'escalader');
  const futures = [];
  if (!positive && vagueEffective === 1 && ech.vague2 > t) futures.push(ech.vague2);
  if (!positive && !escaladeFaite && ech.escalade > t) futures.push(ech.escalade);
  futures.push(ech.expiration);
  plan.prochaine_echeance = new Date(Math.min(...futures.filter((x) => x > t))).toISOString();
  return plan;
}
