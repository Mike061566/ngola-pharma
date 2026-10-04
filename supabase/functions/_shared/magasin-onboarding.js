// Accès base / stockage de l'onboarding via un client Supabase SERVICE ROLE injecté (Edge Functions uniquement).
import { creerMagasinAlertes } from './magasin-alertes.js';

const BUCKET = 'documents-demandes';
function ok({ data, error }, contexte) {
  if (error) {
    const e = new Error(`${contexte} : ${error.code || 'erreur'}`);   // le message journalisé ne contient jamais de valeur
    e.code = error.code; e.detail = error.message;                    // `detail` sert à choisir la réponse HTTP, jamais journalisé
    throw e;
  }
  return data;
}

export function creerMagasinOnboarding(sb) {
  return {
    ...creerMagasinAlertes(sb),
    async mode() { return ok(await sb.rpc('mode_application'), 'mode'); },
    async deposer(chemin, octets, mime) {
      const { error } = await sb.storage.from(BUCKET).upload(chemin, octets, { contentType: mime, upsert: false });
      if (error) throw new Error('deposer : erreur');
    },
    async supprimer(chemins) { if (chemins?.length) await sb.storage.from(BUCKET).remove(chemins); },
    async urlSignee(chemin, secondes = 300) {
      const { data, error } = await sb.storage.from(BUCKET).createSignedUrl(chemin, secondes);
      if (error) throw new Error('urlSignee : erreur');
      return data.signedUrl;
    },
    async soumettre(payload, empreinteIp) {
      return ok(await sb.rpc('soumettre_demande_interne', { p: payload, p_empreinte_ip: empreinteIp }), 'soumettre');
    },
    async estAdmin(userId) {
      const r = ok(await sb.from('profils').select('role').eq('id', userId).maybeSingle(), 'estAdmin');
      return r?.role === 'admin';
    },
    async decider(id, decision, motif, adminId) {
      return ok(await sb.rpc('decider_demande_interne', { p_id: id, p_decision: decision, p_motif: motif ?? null, p_admin: adminId }), 'decider');
    },
    async lireDemande(id) {
      return ok(await sb.from('demandes_partenaire').select('id, statut, nom_pharmacie, email_titulaire, est_demo, pharmacie_id').eq('id', id).maybeSingle(), 'lireDemande');
    },
    async creerJetonActivation(demandeId, hash, heures = 72) {
      ok(await sb.rpc('creer_jeton_activation_interne', { p_demande: demandeId, p_hash: hash, p_heures: heures }), 'creerJetonActivation');
    },
    async consommerJetonActivation(hash) { return ok(await sb.rpc('consommer_jeton_activation_interne', { p_hash: hash }), 'consommerJeton'); },
    async definirJetonComplements(id, hash, expire) {
      ok(await sb.rpc('definir_jeton_complements_interne', { p_id: id, p_hash: hash, p_expire: expire }), 'definirJetonComplements');
    },
    async deposerComplements(hash, message, documents) {
      return ok(await sb.rpc('deposer_complements_interne', { p_hash: hash, p_message: message, p_documents: documents }), 'deposerComplements');
    },
    async marquerInvitation(id, compte, invitation) {
      ok(await sb.rpc('marquer_invitation_interne', { p_demande: id, p_compte: compte, p_invitation: invitation }), 'marquerInvitation');
    },
    async candidatsRappels() { return ok(await sb.rpc('candidats_rappels_interne'), 'candidatsRappels') || []; },
    async enregistrerRappel(pharmacieId, jalon, canaux) {
      return ok(await sb.rpc('enregistrer_rappel_interne', { p_pharmacie: pharmacieId, p_jalon: jalon, p_canaux: canaux }), 'enregistrerRappel');
    },
    async utilisateurParEmail(email) { return ok(await sb.rpc('utilisateur_par_email_interne', { p_email: email }), 'utilisateurParEmail'); },
    async creerUtilisateur(email) {
      const { data, error } = await sb.auth.admin.createUser({ email, email_confirm: true });
      if (error) throw new Error('creerUtilisateur : erreur');
      return data.user.id;
    },
    async lierProfil(userId, pharmacieId, nom) {
      return ok(await sb.rpc('lier_profil_pharmacien_interne', { p_user: userId, p_pharmacie: pharmacieId, p_nom: nom }), 'lierProfil');
    },
    async lienConnexion(email, redirectTo) {
      const { data, error } = await sb.auth.admin.generateLink({ type: 'magiclink', email, options: { redirectTo } });
      if (error) throw new Error('lienConnexion : erreur');
      return data.properties.action_link;
    },
    /** Utilisateur authentifié par son jeton d'accès (JWT de la console). */
    async utilisateurDuJeton(jwt) {
      const { data, error } = await sb.auth.getUser(jwt);
      return error ? null : data.user;
    },
  };
}
