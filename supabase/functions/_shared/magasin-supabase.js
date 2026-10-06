// Accès base de données du worker, via un client Supabase SERVICE ROLE injecté (`sb`). Seul ce fichier connaît
// les noms de tables : le reste du worker travaille sur l'interface « magasin » (remplacée par une version en
// mémoire dans les tests).
function ok({ data, error }, contexte) {
  if (error) throw new Error(`${contexte} : ${error.code || error.message}`);
  return data;
}

export function creerMagasinSupabase(sb) {
  return {
    /** Configuration du routage sous forme { cle: valeur }. */
    async lireConfig() {
      const lignes = ok(await sb.from('config_routage').select('cle, valeur'), 'lireConfig');
      return Object.fromEntries((lignes || []).map((l) => [l.cle, l.valeur]));
    },
    /** Prélève un lot et pose un bail (fonction SQL, SKIP LOCKED). */
    async reclamer(limite, bailS) {
      return ok(await sb.rpc('reclamer_notifications', { p_limite: limite, p_bail_s: bailS }), 'reclamer');
    },
    async compterPayantsDuJour() {
      return ok(await sb.rpc('compter_messages_payants_du_jour'), 'compterPayants');
    },
    async lireContact(id) {
      return ok(await sb.from('contacts_pharmacie').select('id, desabonne_le, bloque_le').eq('id', id).maybeSingle(), 'lireContact');
    },
    async lireContactsPharmacie(pharmacieId) {
      return ok(await sb.from('contacts_pharmacie')
        .select('id, canal, adresse, verifie_le, desabonne_le, bloque_le, est_contact_demo')
        .eq('pharmacie_id', pharmacieId), 'lireContactsPharmacie');
    },
    async marquerEnvoye(id, { idMessage, idDiscussion }) {
      ok(await sb.from('notifications_outbox').update({
        statut: 'sent', id_message_fournisseur: idMessage, id_discussion_fournisseur: idDiscussion, derniere_erreur: null,
      }).eq('id', id), 'marquerEnvoye');
    },
    async marquer(id, statut, erreur) {
      ok(await sb.from('notifications_outbox').update({ statut, derniere_erreur: erreur ?? null }).eq('id', id), 'marquer');
    },
    /** Remet la ligne en file pour `quand`. `tentatives` : valeur à restaurer quand l'essai ne doit pas compter. */
    async reporter(id, quand, { erreur = null, tentatives = undefined } = {}) {
      const maj = { statut: 'queued', prochaine_tentative_le: quand.toISOString(), derniere_erreur: erreur };
      if (tentatives !== undefined) maj.tentatives = tentatives;
      ok(await sb.from('notifications_outbox').update(maj).eq('id', id), 'reporter');
    },
    async bloquerContact(id) {
      ok(await sb.from('contacts_pharmacie').update({ bloque_le: new Date().toISOString() }).eq('id', id), 'bloquerContact');
    },
    /** Insère une ligne ; un doublon de cle_idempotence est ignoré. Renvoie true si la ligne a été créée. */
    async enfiler(ligne) {
      const data = ok(await sb.from('notifications_outbox')
        .upsert(ligne, { onConflict: 'cle_idempotence', ignoreDuplicates: true }).select('id'), 'enfiler');
      return Array.isArray(data) && data.length > 0;
    },
  };
}
