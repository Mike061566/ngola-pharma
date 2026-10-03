// Accès base de données des alertes (création, planificateur) via un client Supabase SERVICE ROLE injecté.
// Complète le magasin de l'outbox (magasin-supabase.js) : même objet, mêmes méthodes `enfiler`, `lireConfig`...
import { creerMagasinSupabase } from './magasin-supabase.js';

function ok({ data, error }, contexte) {
  if (error) throw new Error(`${contexte} : ${error.code || 'erreur'}`);   // jamais le message (peut contenir des valeurs)
  return data;
}
const STATUTS_ACTIFS = ['new', 'routing', 'escalated', 'answered', 'needs_review'];
const SELECTION_ALERTE = 'id, id_public, statut, urgence, quartier_id, lat, lng, vague, cree_le, debut_routage_le, expire_le, ' +
  'premiere_reponse_positive_le, escalade_le, patient_notifie_le, second_message_le, canal_patient, contact_patient_chiffre, raison_revue, ' +
  'quartiers(nom), medicaments(id, nom, dosage, forme, restreint, classification_validee_le, est_demo, statut_catalogue, ordonnance), ' +
  'envois_alerte(pharmacie_id)';

export function creerMagasinAlertes(sb) {
  return {
    ...creerMagasinSupabase(sb),

    // ── Création publique ──
    async compterValidations() {
      const { count, error } = await sb.from('validations_classification').select('id', { count: 'exact', head: true });
      if (error) throw new Error(`compterValidations : ${error.code || 'erreur'}`);
      return count || 0;
    },
    async creerAlerte(params) {
      const data = ok(await sb.rpc('creer_alerte_routage', params), 'creerAlerte');
      return Array.isArray(data) ? data[0] : data;
    },
    async creerJetonTelegram(ligne) {
      ok(await sb.from('jetons_telegram').insert(ligne), 'creerJetonTelegram');
    },
    /** Vue publique d'une alerte (suivi) : aucune donnée patient. */
    async lireSuivi(idPublic) {
      const a = ok(await sb.from('alertes_routage').select('id, id_public, statut, urgence, cree_le, expire_le, patient_notifie_le, medicaments(nom, dosage, forme, ordonnance), quartiers(nom)')
        .eq('id_public', idPublic).maybeSingle(), 'lireSuivi');
      return a;
    },

    // ── Planificateur ──
    async alertesActives() {
      const lignes = ok(await sb.from('alertes_routage').select(SELECTION_ALERTE).in('statut', STATUTS_ACTIFS).order('cree_le').limit(500), 'alertesActives');
      return (lignes || []).map(({ quartiers, medicaments, envois_alerte, ...a }) => ({
        ...a, quartier_nom: quartiers?.nom ?? '', medicament: medicaments ?? null,
        deja_sollicitees: (envois_alerte || []).map((e) => e.pharmacie_id) }));
    },
    async donneesPharmacies(medicamentId) {
      return ok(await sb.rpc('donnees_routage_pharmacies', { p_medicament_id: medicamentId }), 'donneesPharmacies') || [];
    },
    async creerEnvois(alerteId, lignes) {
      ok(await sb.from('envois_alerte').upsert(lignes, { onConflict: 'alerte_id,pharmacie_id', ignoreDuplicates: true }), 'creerEnvois');
      return ok(await sb.from('envois_alerte').select('id, pharmacie_id, code_reponse').eq('alerte_id', alerteId)
        .in('pharmacie_id', lignes.map((l) => l.pharmacie_id)), 'lireEnvois') || [];
    },
    async contactsPharmacies(ids) {
      if (!ids.length) return [];
      return ok(await sb.from('contacts_pharmacie').select('id, pharmacie_id, canal, adresse, est_principal, verifie_le, desabonne_le, bloque_le, est_contact_demo')
        .in('pharmacie_id', ids), 'contactsPharmacies') || [];
    },
    async pharmaciesInfo(ids) {
      if (!ids.length) return [];
      const l = ok(await sb.from('pharmacies').select('id, nom, telephone, latitude, longitude, est_de_garde, garde_jusqu_a, quartiers(nom)').in('id', ids), 'pharmaciesInfo') || [];
      return l.map(({ quartiers, ...p }) => ({ ...p, quartier_nom: quartiers?.nom ?? '' }));
    },
    async majAlerte(id, patch) {
      ok(await sb.from('alertes_routage').update(patch).eq('id', id), 'majAlerte');
    },
    async expirerEnvois(alerteId) {
      ok(await sb.from('envois_alerte').update({ statut: 'expired' }).eq('alerte_id', alerteId).eq('statut', 'sent'), 'expirerEnvois');
    },
    async reponsesPositives(alerteId) {
      const l = ok(await sb.from('reponses_alerte').select('prix_fcfa, repondu_le, envois_alerte!inner(alerte_id, pharmacie_id)')
        .eq('reponse', 'available').eq('envois_alerte.alerte_id', alerteId), 'reponsesPositives') || [];
      return l.map((r) => ({ pharmacie_id: r.envois_alerte.pharmacie_id, prix_fcfa: r.prix_fcfa, repondu_le: r.repondu_le }));
    },
    async prixStock(medicamentId, pharmacieIds) {
      if (!medicamentId || !pharmacieIds.length) return new Map();
      const l = ok(await sb.from('stocks').select('pharmacie_id, prix_fcfa').eq('medicament_id', medicamentId).in('pharmacie_id', pharmacieIds), 'prixStock') || [];
      return new Map(l.map((s) => [s.pharmacie_id, s.prix_fcfa]));
    },
    async envoisARelancer() {
      return ok(await sb.from('envois_alerte').select('id, alerte_id, pharmacie_id, envoye_le, code_reponse, alertes_routage!inner(urgence)')
        .eq('statut', 'sent').is('relance_sms_le', null).eq('alertes_routage.urgence', 'urgent').limit(500), 'envoisARelancer') || [];
    },
    async marquerRelance(envoiId) {
      ok(await sb.from('envois_alerte').update({ relance_sms_le: new Date().toISOString() }).eq('id', envoiId), 'marquerRelance');
    },
    /** Pharmacies ayant répondu « disponible » (affichage public du suivi) : nom, prix, quartier, téléphone. */
    async pharmaciesDisponibles(alerteId) {
      const pos = await this.reponsesPositives(alerteId);
      const infos = new Map((await this.pharmaciesInfo(pos.map((r) => r.pharmacie_id))).map((x) => [x.id, x]));
      return pos.filter((r) => r.prix_fcfa).sort((a, b) => a.prix_fcfa - b.prix_fcfa).slice(0, 3)
        .map((r) => ({ nom: infos.get(r.pharmacie_id)?.nom, prix_fcfa: r.prix_fcfa, quartier: infos.get(r.pharmacie_id)?.quartier_nom, telephone: infos.get(r.pharmacie_id)?.telephone }));
    },
    /** Mode démo : l'adresse du patient est-elle celle d'un contact de la liste blanche (compte de test) ? */
    async adresseEstContactDemo(adresse) {
      const l = ok(await sb.from('contacts_pharmacie').select('id').eq('adresse', adresse).eq('est_contact_demo', true).limit(1), 'adresseEstContactDemo');
      return Array.isArray(l) && l.length > 0;
    },
  };
}
