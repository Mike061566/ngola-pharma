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
    // ── Réponses des pharmacies (PR 5) ──
    /** Enregistre une réponse (SQL atomique et idempotent) ; renvoie la ligne { resultat, repondu_le, reponse, prix_fcfa, ... }. */
    async enregistrerReponse(envoiId, reponse, prix, canal, utilisateur) {
      const d = ok(await sb.rpc('enregistrer_reponse_alerte', { p_envoi_id: envoiId, p_reponse: reponse, p_prix: prix, p_canal: canal, p_utilisateur: utilisateur }), 'enregistrerReponse');
      return Array.isArray(d) ? d[0] : d;
    },
    async trouverEnvoiCourt(pharmacieId, court) {
      return ok(await sb.rpc('trouver_envoi_court', { p_pharmacie_id: pharmacieId, p_court: court }), 'trouverEnvoiCourt') || null;
    },
    async consommerJeton(hash) {
      const d = ok(await sb.rpc('consommer_jeton_telegram', { p_hash: hash }), 'consommerJeton');
      return (Array.isArray(d) ? d[0] : d) || null;
    },
    async lierContactTelegram(contactId, chatId) {
      const d = ok(await sb.rpc('lier_contact_telegram', { p_contact_id: contactId, p_chat_id: chatId }), 'lierContactTelegram');
      return Array.isArray(d) ? d[0] : d;
    },
    async desabonnerTelegram(chatId) {
      return ok(await sb.rpc('desabonner_telegram', { p_chat_id: chatId }), 'desabonnerTelegram') || 0;
    },
    async contactsParChat(chatId) {
      return ok(await sb.from('contacts_pharmacie').select('id, pharmacie_id, verifie_le, desabonne_le, bloque_le, est_contact_demo')
        .eq('canal', 'telegram').eq('adresse', chatId), 'contactsParChat') || [];
    },
    /** Patient : enregistre le chat (chiffré) et le consentement ; l'empreinte HMAC sert au /stop. */
    async lierPatientTelegram(alerteId, chatChiffre, empreinte) {
      ok(await sb.from('alertes_routage').update({ canal_patient: 'telegram', contact_patient_chiffre: chatChiffre, empreinte_telegram: empreinte }).eq('id', alerteId), 'lierPatientTelegram');
      ok(await sb.from('alertes_routage').update({ consentement_le: new Date().toISOString() }).eq('id', alerteId).is('consentement_le', null), 'consentementPatient');
    },
    async retirerPatientTelegram(empreinte) {
      ok(await sb.from('alertes_routage').update({ contact_patient_chiffre: null, canal_patient: 'none' }).eq('empreinte_telegram', empreinte), 'retirerPatientTelegram');
    },
    /** Messages Telegram déjà envoyés pour un envoi (un par agent de la pharmacie), pour retirer leurs boutons. */
    async messagesTelegramEnvoi(envoiId) {
      return ok(await sb.from('notifications_outbox').select('contact_id, id_discussion_fournisseur, id_message_fournisseur')
        .eq('cle_base', envoiId).eq('canal', 'telegram').eq('modele', 'alerte_demande').in('statut', ['sent', 'delivered', 'read'])
        .not('id_message_fournisseur', 'is', null), 'messagesTelegramEnvoi') || [];
    },
    /** Lien /r/<code> : l'envoi, son alerte (sans donnée patient), la réponse éventuelle et le prix du stock. */
    async envoiParCode(code) {
      const e = ok(await sb.from('envois_alerte').select('id, statut, pharmacie_id, pharmacies(nom), alertes_routage(statut, expire_le, urgence, medicament_id, medicaments(nom, dosage, forme, ordonnance), quartiers(nom)), reponses_alerte(reponse, prix_fcfa, repondu_le)')
        .eq('code_reponse', code).maybeSingle(), 'envoiParCode');
      if (!e) return null;
      const a = e.alertes_routage || {}, r = Array.isArray(e.reponses_alerte) ? e.reponses_alerte[0] : e.reponses_alerte;
      let prix = null;
      if (a.medicament_id) {
        const st = ok(await sb.from('stocks').select('prix_fcfa, statut_stock').eq('pharmacie_id', e.pharmacie_id).eq('medicament_id', a.medicament_id).maybeSingle(), 'prixStockLien');
        if (st && st.statut_stock !== 'rupture' && st.prix_fcfa > 0) prix = st.prix_fcfa;
      }
      return { id: e.id, statut: e.statut, pharmacie_nom: e.pharmacies?.nom ?? '', alerte_statut: a.statut, expire_le: a.expire_le, urgence: a.urgence,
        medicament: a.medicaments ? `${a.medicaments.nom}${a.medicaments.dosage ? ' ' + a.medicaments.dosage : ''}` : null, forme: a.medicaments?.forme ?? null,
        sur_ordonnance: a.medicaments?.ordonnance === true, quartier: a.quartiers?.nom ?? null, prix_stock: prix,
        reponse: r?.reponse ?? null, prix_repondu: r?.prix_fcfa ?? null, repondu_le: r?.repondu_le ?? null };
    },
    // ── Test d'envoi (Espace Pro) ──
    async lireContactPharmacie(id) {
      return ok(await sb.from('contacts_pharmacie').select('id, pharmacie_id, canal, adresse, verifie_le, desabonne_le, bloque_le, est_contact_demo').eq('id', id).maybeSingle(), 'lireContactPharmacie');
    },
    async lireProfil(userId) {
      return ok(await sb.from('profils').select('id, role, pharmacie_id').eq('id', userId).maybeSingle(), 'lireProfil');
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
