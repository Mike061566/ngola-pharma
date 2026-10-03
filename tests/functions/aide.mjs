// Aides de test : magasin en mémoire (mêmes méthodes que magasin-supabase.js), horloge contrôlée, clé de test.
import { cleDepuisBase64, chiffrer, versBytea } from '../../supabase/functions/_shared/chiffrement.js';

export async function cleTest() {
  return cleDepuisBase64(Buffer.from(new Uint8Array(32).fill(7)).toString('base64'));
}

export function horloge(debut = '2026-10-05T10:00:00Z') {
  let t = new Date(debut).getTime();
  return { maintenant: () => new Date(t), avancer: (ms) => { t += ms; }, dormir: async (ms) => { t += ms; } };
}

export async function ligneOutbox(cle, surcharge = {}) {
  const adresse = surcharge.adresse ?? '123456';
  const base = {
    id: surcharge.id ?? `o${Math.random().toString(36).slice(2, 8)}`,
    cle_idempotence: surcharge.cle_idempotence ?? `k${Math.random().toString(36).slice(2, 8)}`,
    type_destinataire: 'pharmacy', destinataire_ref: 'ph1', canal: 'telegram', modele: 'alerte_demande',
    variables: { drug: 'Ibuprofène', form: 'comprimé', quartier: 'Centre-Ville', heure: '10:00', code: 'ABC123', envoi_court: 'e1' },
    statut: 'queued', tentatives: 0, prochaine_tentative_le: '2026-10-05T09:00:00Z', derniere_erreur: null,
    contact_id: null, cle_base: 'envoi1', canaux_tentes: [], est_destinataire_demo: true, exempte_budget: false,
    ...surcharge,
  };
  delete base.adresse;
  if (surcharge.adresse_chiffree === undefined) base.adresse_chiffree = versBytea(await chiffrer(cle, adresse));
  return base;
}

export function magasinMemoire({ config = {}, lignes = [], contacts = [], payants = 0, horloge: h }) {
  const etat = { lignes: [...lignes], contacts: [...contacts], payants, config: { mode_application: 'production', ...config } };
  const m = {
    etat,
    async lireConfig() { return etat.config; },
    async reclamer(limite, bailS) {
      const now = h.maintenant().getTime();
      const dues = etat.lignes.filter((l) => l.statut === 'queued' && new Date(l.prochaine_tentative_le).getTime() <= now)
        .sort((a, b) => new Date(a.prochaine_tentative_le) - new Date(b.prochaine_tentative_le)).slice(0, limite);
      for (const l of dues) { l.prochaine_tentative_le = new Date(now + bailS * 1000).toISOString(); l.tentatives += 1; }
      return dues.map((l) => ({ ...l }));
    },
    async compterPayantsDuJour() { return etat.payants; },
    async lireContact(id) { return etat.contacts.find((c) => c.id === id) ?? null; },
    async lireContactsPharmacie(ref) { return etat.contacts.filter((c) => c.pharmacie_id === ref); },
    async marquerEnvoye(id, { idMessage, idDiscussion }) {
      const l = etat.lignes.find((x) => x.id === id);
      Object.assign(l, { statut: 'sent', id_message_fournisseur: idMessage, id_discussion_fournisseur: idDiscussion, derniere_erreur: null });
    },
    async marquer(id, statut, erreur) { Object.assign(etat.lignes.find((x) => x.id === id), { statut, derniere_erreur: erreur ?? null }); },
    async reporter(id, quand, { erreur = null, tentatives } = {}) {
      const l = etat.lignes.find((x) => x.id === id);
      Object.assign(l, { statut: 'queued', prochaine_tentative_le: quand.toISOString(), derniere_erreur: erreur });
      if (tentatives !== undefined) l.tentatives = tentatives;
    },
    async bloquerContact(id) { etat.contacts.find((c) => c.id === id).bloque_le = h.maintenant().toISOString(); },
    async enfiler(ligne) {
      if (etat.lignes.some((l) => l.cle_idempotence === ligne.cle_idempotence)) return false;
      etat.lignes.push({ id: `f${etat.lignes.length}`, statut: 'queued', tentatives: 0, prochaine_tentative_le: h.maintenant().toISOString(), derniere_erreur: null, ...ligne });
      return true;
    },
  };
  return m;
}

// ── Magasin des alertes en mémoire (planificateur, création, suivi) ──
export function magasinAlertesMemoire({ config = {}, alertes = [], pharmacies = [], contacts = [], reponses = [], demoAdresses = [], validations = 0, horloge: h }) {
  const sortie = magasinMemoire({ config: { mode_application: 'demo', ...config }, lignes: [], contacts, horloge: h });
  const etat = sortie.etat;
  Object.assign(etat, { alertes: alertes.map((a) => ({ ...a })), pharmacies, envois: [], reponses: [...reponses], jetons: [], creations: [], validations });
  const trouver = (id) => etat.alertes.find((a) => a.id === id);
  Object.assign(sortie, {
    async compterValidations() { return etat.validations; },
    async alertesActives() {
      return etat.alertes.filter((a) => ['new', 'routing', 'escalated', 'answered', 'needs_review'].includes(a.statut))
        .map((a) => ({ ...a, deja_sollicitees: etat.envois.filter((e) => e.alerte_id === a.id).map((e) => e.pharmacie_id) }));
    },
    async donneesPharmacies() { return etat.pharmacies.map((p) => ({ ...p })); },
    async creerEnvois(alerteId, lignes) {
      for (const l of lignes) if (!etat.envois.some((e) => e.alerte_id === alerteId && e.pharmacie_id === l.pharmacie_id)) {
        etat.envois.push({ id: globalThis.crypto.randomUUID(), statut: 'sent', envoye_le: h.maintenant().toISOString(), relance_sms_le: null, ...l });
      }
      return etat.envois.filter((e) => e.alerte_id === alerteId && lignes.some((l) => l.pharmacie_id === e.pharmacie_id));
    },
    async contactsPharmacies(ids) { return etat.contacts.filter((c) => ids.includes(c.pharmacie_id)); },
    async pharmaciesInfo(ids) { return etat.pharmacies.filter((p) => ids.includes(p.id)); },
    async majAlerte(id, patch) { Object.assign(trouver(id), patch); },
    async expirerEnvois(alerteId) { etat.envois.filter((e) => e.alerte_id === alerteId && e.statut === 'sent').forEach((e) => { e.statut = 'expired'; }); },
    async reponsesPositives(alerteId) {
      return etat.reponses.filter((r) => r.alerte_id === alerteId).map((r) => ({ pharmacie_id: r.pharmacie_id, prix_fcfa: r.prix_fcfa, repondu_le: r.repondu_le }));
    },
    async prixStock() { return new Map(); },
    async envoisARelancer() {
      return etat.envois.filter((e) => e.statut === 'sent' && !e.relance_sms_le && trouver(e.alerte_id)?.urgence === 'urgent');
    },
    async marquerRelance(id) { etat.envois.find((e) => e.id === id).relance_sms_le = h.maintenant().toISOString(); },
    async adresseEstContactDemo(adresse) { return demoAdresses.includes(adresse); },
    async creerAlerte(params) { etat.creations.push(params); return etat.reponseCreation ?? { alerte_id: 'a-new', id_public: params.p_id_public, statut: 'new', raison_revue: null, fusionnee: false, refus: null }; },
    async creerJetonTelegram(l) { etat.jetons.push(l); },
    async lireSuivi(id) { return etat.suivis?.[id] ?? null; },
  });
  return sortie;
}

// ── Extension : réponses des pharmacies, jetons, contacts Telegram (PR 5) ──
export function ajouterReponsesMemoire(magasin, h) {
  const etat = magasin.etat;
  Object.assign(etat, { jetonsTg: new Map(), reponsesEnvoi: new Map(), appelsReponse: [], liensContact: [], patientsTg: [] });
  const envoiParId = (id) => etat.envois.find((e) => e.id === id);
  Object.assign(magasin, {
    async consommerJeton(hash) {
      const j = etat.jetonsTg.get(hash);
      if (!j || j.utilise || new Date(j.expire_le) <= h.maintenant()) return null;
      j.utilise = true; return { objet: j.objet, ref_id: j.ref_id };
    },
    async lierContactTelegram(contactId, chatId) {
      const c = etat.contacts.find((x) => x.id === contactId);
      if (!c) return { resultat: 'introuvable' };
      const verifies = etat.contacts.filter((x) => x.pharmacie_id === c.pharmacie_id && x.canal === 'telegram' && x.verifie_le && !x.desabonne_le && x.id !== c.id);
      if (verifies.length >= 3) return { resultat: 'limite_contacts', pharmacie_id: c.pharmacie_id };
      Object.assign(c, { adresse: chatId, verifie_le: h.maintenant().toISOString() });
      etat.liensContact.push(contactId);
      return { resultat: 'active', pharmacie_id: c.pharmacie_id, pharmacie_nom: etat.pharmacies.find((p) => p.id === c.pharmacie_id)?.nom ?? 'Pharmacie', contact_id: c.id, est_contact_demo: c.est_contact_demo };
    },
    async desabonnerTelegram(chatId) {
      const l = etat.contacts.filter((c) => c.canal === 'telegram' && c.adresse === chatId && !c.desabonne_le);
      l.forEach((c) => { c.desabonne_le = h.maintenant().toISOString(); }); return l.length;
    },
    async contactsParChat(chatId) { return etat.contacts.filter((c) => c.canal === 'telegram' && c.adresse === chatId); },
    async lierPatientTelegram(alerteId, chiffre, empreinte) {
      const a = etat.alertes.find((x) => x.id === alerteId);
      Object.assign(a, { canal_patient: 'telegram', contact_patient_chiffre: chiffre, empreinte_telegram: empreinte, consentement_le: a.consentement_le ?? h.maintenant().toISOString() });
      etat.patientsTg.push(alerteId);
    },
    async retirerPatientTelegram(empreinte) {
      etat.alertes.filter((a) => a.empreinte_telegram === empreinte).forEach((a) => { a.contact_patient_chiffre = null; a.canal_patient = 'none'; });
    },
    async trouverEnvoiCourt(pharmacieId, court) {
      const l = etat.envois.filter((e) => e.pharmacie_id === pharmacieId && e.id.startsWith(`${court}-`));
      return l.length === 1 ? l[0].id : null;
    },
    async enregistrerReponse(envoiId, reponse, prix, canal, utilisateur) {
      etat.appelsReponse.push({ envoiId, reponse, prix, canal, utilisateur });
      const e = envoiParId(envoiId);
      if (!e) return { resultat: 'introuvable' };
      const deja = etat.reponsesEnvoi.get(envoiId);
      if (deja) return { resultat: 'deja_traitee', ...deja };
      const a = etat.alertes.find((x) => x.id === e.alerte_id);
      if (e.statut !== 'sent' || ['expired', 'cancelled', 'fulfilled'].includes(a?.statut) || new Date(a.expire_le) <= h.maintenant()) return { resultat: 'expiree' };
      if (reponse === 'unavailable') prix = null;
      if (prix !== null && prix !== undefined && (prix <= 0 || prix > 10000000)) return { resultat: 'prix_invalide' };
      const r = { reponse, prix_fcfa: prix ?? null, repondu_le: h.maintenant().toISOString(), canal };
      etat.reponsesEnvoi.set(envoiId, r); e.statut = 'responded';
      return { resultat: 'enregistree', ...r };
    },
    async messagesTelegramEnvoi(envoiId) {
      return etat.lignes.filter((l) => l.cle_base === envoiId && l.canal === 'telegram' && l.id_message_fournisseur)
        .map((l) => ({ contact_id: l.contact_id, id_discussion_fournisseur: l.id_discussion_fournisseur, id_message_fournisseur: l.id_message_fournisseur }));
    },
    async envoiParCode(code) { return etat.liens?.[code] ?? null; },
    async lireContactPharmacie(id) { return etat.contacts.find((c) => c.id === id) ?? null; },
    async lireProfil(id) { return etat.profils?.[id] ?? null; },
  });
  return magasin;
}
