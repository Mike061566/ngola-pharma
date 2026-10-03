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
