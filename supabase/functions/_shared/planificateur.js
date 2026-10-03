// Planificateur des alertes (SPEC 2 §4.3, §4.4, §6.1) : exécuté chaque minute par l'Edge Function `planifier-alertes`.
// Pour chaque alerte active : planDispatch (fonction pure, PR 3) décide, ce module EXÉCUTE (envois, statuts, outbox).
// Aucun envoi direct : tout passe par l'outbox (file-sortie.js) ; le worker (PR 2) applique démo, budget et repli.
//
// Règles d'exécution
//  - needs_review : le patient reçoit `restricted_attente` si le médicament est restreint ; passé `expire_le`, l'alerte expire.
//  - vague 1 / 2 : une ligne `envois_alerte` par pharmacie sélectionnée + un message par contact actif (Telegram vérifié
//    d'abord, sinon SMS, sinon email). Le repli en cas d'échec est le travail du worker.
//  - escalade : message d'attente au patient (une fois) + email admin (ADMIN_ALERT_EMAIL) ; expiration : message au patient
//    seulement si personne n'a répondu positivement.
//  - agrégation (§4.4) : à la 1re réponse positive on ouvre une fenêtre `fenetre_agregation_s` ; à sa fermeture, UN message au
//    patient avec jusqu'à 3 pharmacies (prix croissant, puis distance) ; un 2e message court au plus pour les réponses tardives.
//  - relance SMS (§6.1) : alerte `urgent` sans réponse après `relance_sms_apres_min` -> SMS à la même pharmacie ; jamais pour `normal`.
// Le contact du patient n'est jamais envoyé aux pharmacies ni journalisé.
import { planDispatch, parametresRoutage, verifierDemarrageRoutage, DEFAUTS, distanceKm } from './routage.js';
import { enfiler } from './file-sortie.js';
import { dechiffrer, depuisBytea } from './chiffrement.js';
import { aleatoireBase32 } from './securite.js';

const MIN = 60000;
const nom = (m) => (m ? `${m.nom}${m.dosage ? ' ' + m.dosage : ''}` : '');

/** Heure locale « HH:MM » (Cameroun par défaut : UTC+1). */
export function heureLocale(date, decalageMin = DEFAUTS.decalage_horaire_min) {
  const d = new Date(date.getTime() + decalageMin * MIN);
  return `${String(d.getUTCHours()).padStart(2, '0')}:${String(d.getUTCMinutes()).padStart(2, '0')}`;
}

export async function planifierAlertes({ magasin, cle, env = {}, maintenant = () => new Date(), journal = () => {} }) {
  const now = maintenant();
  const config = await magasin.lireConfig();
  const p = parametresRoutage(config);
  const resume = { alertes: 0, vagues: 0, envois: 0, needs_review: 0, escalades: 0, expirees: 0, messages_patient: 0, relances_sms: 0, erreurs: 0, inactif: false };

  const nbValidations = p.mode_application === 'production' ? await magasin.compterValidations() : 0;
  const demarrage = verifierDemarrageRoutage({ mode: p.mode_application, routageAuto: env.ALERT_AUTO_ROUTING === 'true', nbValidationsPharmacien: nbValidations });
  if (!demarrage.actif) { resume.inactif = true; resume.raison = demarrage.raison; return resume; }

  const accel = p.mode_application === 'demo' ? p.facteur_temps_demo : 1;
  const heure = heureLocale(now, p.decalage_horaire_min);

  // ── Messages au patient (via l'outbox) ──
  async function messagePatient(a, modeleTelegram, variables, suffixe) {
    if (!['telegram', 'sms'].includes(a.canal_patient) || !a.contact_patient_chiffre) return false;   // Telegram : chat_id connu au /start (PR 5)
    const adresse = await dechiffrer(cle, depuisBytea(a.contact_patient_chiffre));
    const modele = a.canal_patient === 'sms' && modeleTelegram === 'reponse_patient' ? 'reponse_patient_sms' : modeleTelegram;
    const r = await enfiler(magasin, cle, { typeDestinataire: 'patient', destinataireRef: null, canal: a.canal_patient, modele, adresse,
      variables: { ...variables, base_url: env.APP_BASE_URL }, cleBase: `alerte:${a.id}:${suffixe}`,
      estDestinataireDemo: await magasin.adresseEstContactDemo(adresse) });
    if (r.cree) resume.messages_patient += 1;
    return true;
  }

  // ── Envoi d'une vague : lignes envois_alerte + messages aux contacts de chaque pharmacie ──
  async function executerVague(a, action) {
    const lignes = action.pharmacies.map((e) => ({ alerte_id: a.id, pharmacie_id: e.pharmacie_id, vague: e.vague, score: e.score,
      detail_score: e.detail_score, code_reponse: aleatoireBase32(10) }));
    const envois = await magasin.creerEnvois(a.id, lignes);
    const ids = envois.map((e) => e.pharmacie_id);
    const contacts = await magasin.contactsPharmacies(ids);
    const infos = new Map((await magasin.pharmaciesInfo(ids)).map((x) => [x.id, x]));
    const maxTg = Math.max(1, Math.floor(Number(config.max_contacts_telegram_par_pharmacie) || 3));
    for (const envoi of envois) {
      const ph = infos.get(envoi.pharmacie_id) || {};
      const actifs = contacts.filter((c) => c.pharmacie_id === envoi.pharmacie_id && !c.desabonne_le && !c.bloque_le);
      const classe = (canal) => actifs.filter((c) => c.canal === canal && (canal !== 'telegram' || c.verifie_le))
        .sort((x, y) => Number(y.est_principal) - Number(x.est_principal) || (x.id < y.id ? -1 : 1));
      let canal = 'telegram', choisis = classe('telegram').slice(0, maxTg);
      if (choisis.length === 0) { canal = 'sms'; choisis = classe('sms'); }
      if (choisis.length === 0) { canal = 'email'; choisis = classe('email'); }
      const modele = { telegram: 'alerte_demande', sms: 'alerte_demande_sms', email: 'alerte_demande_email' }[canal];
      const garde = ph.est_de_garde === true && (!ph.garde_jusqu_a || new Date(ph.garde_jusqu_a) > now);
      for (const c of choisis) {
        await enfiler(magasin, cle, { typeDestinataire: 'pharmacy', destinataireRef: envoi.pharmacie_id, canal, modele, adresse: c.adresse,
          // Variables : médicament, quartier, heure, lien de réponse. JAMAIS de donnée du patient.
          variables: { drug: nom(a.medicament), form: a.medicament?.forme || '', quartier: a.quartier_nom, heure, code: envoi.code_reponse,
            envoi_court: String(envoi.id).replace(/-/g, '').slice(0, 8), sur_ordonnance: a.medicament?.ordonnance === true, base_url: env.APP_BASE_URL },
          cleBase: envoi.id, contactId: c.id, estDestinataireDemo: c.est_contact_demo === true,
          exempteBudget: a.urgence === 'urgent' && garde });
      }
      resume.envois += 1;
    }
    resume.vagues += 1;
    await magasin.majAlerte(a.id, { statut: a.statut === 'escalated' ? 'escalated' : 'routing', vague: action.vague,
      ...(action.vague === 1 ? { debut_routage_le: now.toISOString() } : {}) });
  }

  async function executer(a, action) {
    if (action.type === 'needs_review') {
      await magasin.majAlerte(a.id, { statut: 'needs_review', raison_revue: action.raison });
      resume.needs_review += 1;
      if (action.raison === 'restreint') await messagePatient(a, 'restricted_attente', {}, 'restricted_attente');
    } else if (action.type === 'expirer') {
      await magasin.majAlerte(a.id, { statut: 'expired' });
      await magasin.expirerEnvois(a.id);
      resume.expirees += 1;
      if (!a.premiere_reponse_positive_le && a.medicament) await messagePatient(a, 'expiration_patient', { drug: nom(a.medicament) }, 'expiration');
    } else if (action.type === 'envoyer_vague') {
      await executerVague(a, action);
    } else if (action.type === 'aucun_candidat') {
      if (action.vague === 1) await magasin.majAlerte(a.id, { statut: 'routing', vague: 1, debut_routage_le: now.toISOString() });
      journal({ evt: 'aucun_candidat', alerte: a.id, vague: action.vague });
    } else if (action.type === 'escalader') {
      await magasin.majAlerte(a.id, { statut: 'escalated', escalade_le: now.toISOString() });
      resume.escalades += 1;
      await messagePatient(a, 'attente_patient', { drug: nom(a.medicament) }, 'attente');
      if (env.ADMIN_ALERT_EMAIL) {
        await enfiler(magasin, cle, { typeDestinataire: 'admin', destinataireRef: null, canal: 'email', modele: 'escalade_admin',
          adresse: env.ADMIN_ALERT_EMAIL, cleBase: `alerte:${a.id}:escalade`,
          variables: { id: a.id_public, drug: nom(a.medicament) || 'médicament non reconnu', quartier: a.quartier_nom,
            n: String(a.deja_sollicitees.length), lien: env.APP_BASE_URL ? `${env.APP_BASE_URL}/pro.html` : '' } });
      }
    }
  }

  // ── Agrégation des réponses positives (§4.4) ──
  async function agreger(a) {
    const positives = await magasin.reponsesPositives(a.id);
    if (positives.length === 0) return;
    const premiere = positives.map((r) => r.repondu_le).sort()[0];
    if (!a.premiere_reponse_positive_le) {
      await magasin.majAlerte(a.id, { premiere_reponse_positive_le: premiere, statut: 'answered' });
      a.premiere_reponse_positive_le = premiere; a.statut = 'answered';
    }
    const fenetreMs = (Number(config.fenetre_agregation_s) >= 0 ? Number(config.fenetre_agregation_s) : 120) * 1000 / accel;
    const fermeture = new Date(premiere).getTime() + fenetreMs;
    const selection = async (liste) => {
      const infos = new Map((await magasin.pharmaciesInfo(liste.map((r) => r.pharmacie_id))).map((x) => [x.id, x]));
      const prixStock = await magasin.prixStock(a.medicament?.id, liste.map((r) => r.pharmacie_id));
      return liste.map((r) => {
        const ph = infos.get(r.pharmacie_id) || {};
        return { nom: ph.nom, prix: r.prix_fcfa ?? prixStock.get(r.pharmacie_id) ?? null, quartier: ph.quartier_nom, tel: ph.telephone,
          distance: distanceKm(a.lat, a.lng, ph.latitude, ph.longitude), id: r.pharmacie_id };
      }).filter((x) => x.nom && x.prix !== null && x.tel)
        .sort((x, y) => x.prix - y.prix || (x.distance ?? Infinity) - (y.distance ?? Infinity) || (x.id < y.id ? -1 : 1));
    };
    const base = { drug: nom(a.medicament), heure, sur_ordonnance: a.medicament?.ordonnance === true };
    // Patient Telegram qui n'a pas encore fait /start : on attend son chat_id (PR 5) sans marquer l'alerte « notifiée »,
    // pour que le message parte dès la liaison. Il voit déjà les pharmacies sur la page de suivi.
    if (a.canal_patient === 'telegram' && !a.contact_patient_chiffre) return;
    if (!a.patient_notifie_le) {
      if (now.getTime() < fermeture) return;                               // fenêtre encore ouverte
      const top = (await selection(positives)).slice(0, 3);
      if (top.length) await messagePatient(a, 'reponse_patient', { ...base, pharmacies: top, ...(a.canal_patient === 'sms' ? { ...top[0], pharmacie: top[0].nom } : {}) }, 'reponse');
      await magasin.majAlerte(a.id, { patient_notifie_le: now.toISOString() });
      a.patient_notifie_le = now.toISOString();
    } else if (!a.second_message_le) {
      const tardives = positives.filter((r) => new Date(r.repondu_le).getTime() > new Date(a.patient_notifie_le).getTime());
      if (tardives.length === 0) return;
      const top = (await selection(tardives)).slice(0, 3);
      if (top.length) await messagePatient(a, 'reponse_patient', { ...base, pharmacies: top, ...(a.canal_patient === 'sms' ? { ...top[0], pharmacie: top[0].nom } : {}) }, 'reponse2');
      await magasin.majAlerte(a.id, { second_message_le: now.toISOString() });   // plafonné à 1
    }
  }

  // ── Boucle principale ──
  const alertes = await magasin.alertesActives();
  for (const a of alertes) {
    resume.alertes += 1;
    try {
      if (a.statut === 'needs_review') {
        if (now.getTime() >= new Date(a.expire_le).getTime()) await executer(a, { type: 'expirer' });
        else if (a.raison_revue === 'restreint') await messagePatient(a, 'restricted_attente', {}, 'restricted_attente');   // idempotent
        continue;
      }
      // Les réponses positives d'abord : le moteur doit voir « répondue » pour ne pas lancer de vague 2 ni d'escalade.
      await agreger(a);
      let plan = planDispatch(a, [], config, now);
      if (plan.actions.some((x) => x.type === 'aucun_candidat')) {          // une vague est due : on charge les pharmacies
        plan = planDispatch(a, await magasin.donneesPharmacies(a.medicament?.id), config, now);
      }
      for (const action of plan.actions) await executer(a, action);
    } catch (e) {
      resume.erreurs += 1;
      journal({ evt: 'erreur_alerte', alerte: a.id, erreur: e?.name || 'inconnue' });   // sans détail (pas de donnée personnelle)
    }
  }

  // ── SMS de relance des alertes urgentes sans réponse (§6.1) ──
  const delaiRelanceMs = (Number(config.relance_sms_apres_min) >= 0 ? Number(config.relance_sms_apres_min) : 5) * MIN / accel;
  for (const e of await magasin.envoisARelancer()) {
    if (now.getTime() < new Date(e.envoye_le).getTime() + delaiRelanceMs) continue;
    try {
      const a = alertes.find((x) => x.id === e.alerte_id);
      if (!a || a.premiere_reponse_positive_le || ['answered', 'expired', 'cancelled', 'fulfilled', 'needs_review'].includes(a.statut)) continue;
      const contacts = (await magasin.contactsPharmacies([e.pharmacie_id])).filter((c) => c.canal === 'sms' && !c.desabonne_le && !c.bloque_le);
      const info = (await magasin.pharmaciesInfo([e.pharmacie_id]))[0] || {};
      const garde = info.est_de_garde === true && (!info.garde_jusqu_a || new Date(info.garde_jusqu_a) > now);
      for (const c of contacts) {
        const r = await enfiler(magasin, cle, { typeDestinataire: 'pharmacy', destinataireRef: e.pharmacie_id, canal: 'sms', modele: 'alerte_demande_sms',
          adresse: c.adresse, cleBase: e.id, contactId: c.id, estDestinataireDemo: c.est_contact_demo === true, exempteBudget: garde,
          variables: { drug: nom(a.medicament), quartier: a.quartier_nom, heure, code: e.code_reponse, envoi_court: String(e.id).replace(/-/g, '').slice(0, 8), base_url: env.APP_BASE_URL } });
        if (r.cree) resume.relances_sms += 1;
      }
      await magasin.marquerRelance(e.id);
    } catch (err) {
      resume.erreurs += 1;
      journal({ evt: 'erreur_relance', erreur: err?.name || 'inconnue' });
    }
  }
  return resume;
}
