// Activation du compte d'une officine approuvée (SPEC 1 §5) et dépôt de compléments (SPEC 1 §4).
// Le lien d'activation (72 h, usage unique) est NOTRE jeton ; Supabase émet ensuite un lien de connexion court (le délai du
// lien Supabase est limité). Le jeton voyage dans le fragment (#t=) : absent des journaux serveur et des en-têtes Referer.
import { sha256Hex } from './securite.js';
import { baseUrl } from './decision-demande.js';
import { validerDocuments, reponseErreur } from './demande.js';

const FORMAT_JETON = /^[A-Za-z0-9_-]{16,128}$/;

export async function activerCompte({ jeton }, { magasin, env, journal }) {
  if (typeof jeton !== 'string' || !FORMAT_JETON.test(jeton)) return { status: 400, corps: { erreur: 'lien_invalide' } };
  try {
    const r = await magasin.consommerJetonActivation(await sha256Hex(jeton));
    if (r.erreur) return { status: 410, corps: { erreur: 'lien_invalide', message: 'Ce lien n\'est plus valide. Demandez un nouveau lien à l\'équipe N\'Gola Pharma.' } };
    let userId = await magasin.utilisateurParEmail(r.email);
    if (!userId) userId = await magasin.creerUtilisateur(r.email);
    const lien = await magasin.lierProfil(userId, r.pharmacie_id, null);
    if (lien.erreur) return { status: 409, corps: { erreur: 'compte_conflit', message: 'Cette adresse email est déjà utilisée pour un autre compte. Contactez l\'équipe N\'Gola Pharma.' } };
    if (r.demande_id) await magasin.marquerInvitation(r.demande_id, true, false);   // pharmacie invitée sans demande : rien à marquer
    const action = await magasin.lienConnexion(r.email, `${baseUrl(env)}/pro.html`);
    journal?.({ evt: 'compte_active', demande: r.demande_id });
    return { status: 200, corps: { ok: true, lien_connexion: action } };
  } catch (e) {
    journal?.({ evt: 'erreur_activation', erreur: e?.name || 'inconnue' });
    return { status: 500, corps: { erreur: 'erreur_interne' } };
  }
}

/** Réponse à une demande de compléments (lien signé, sans compte) : message libre + justificatifs facultatifs. */
export async function deposerComplements({ jeton, message, fichiers }, { magasin, journal }) {
  if (typeof jeton !== 'string' || !FORMAT_JETON.test(jeton)) return { status: 400, corps: { erreur: 'lien_invalide' } };
  const texte = typeof message === 'string' ? message.trim().slice(0, 1000) : '';
  const d = validerDocuments((fichiers || []).map((f) => ({ ...f, nature: 'autre' })), { complements: true });
  if (!d.ok) return reponseErreur(d.erreur);
  if (!texte && d.documents.length === 0) return { status: 400, corps: { erreur: 'reponse_vide', message: 'Écrivez un message ou joignez un document.' } };
  const chemins = [];
  try {
    const documents = [];
    const dossier = (await sha256Hex(jeton)).slice(0, 16);
    for (const doc of d.documents) {
      const chemin = `complements/${dossier}/${crypto.randomUUID()}.${doc.ext}`;
      await magasin.deposer(chemin, doc.octets, doc.mime);
      chemins.push(chemin);
      documents.push({ chemin_stockage: chemin, type_mime: doc.mime, taille_octets: doc.octets.byteLength });
    }
    const r = await magasin.deposerComplements(await sha256Hex(jeton), texte, documents);
    if (r.erreur) { await magasin.supprimer(chemins); return { status: 410, corps: { erreur: 'lien_invalide', message: 'Ce lien n\'est plus valide.' } }; }
    journal?.({ evt: 'complements_recus' });
    return { status: 200, corps: { ok: true, message: 'Merci, votre réponse a été transmise.' } };
  } catch (e) {
    if (chemins.length) { try { await magasin.supprimer(chemins); } catch { /* nettoyage au mieux */ } }
    journal?.({ evt: 'erreur_complements', erreur: e?.name || 'inconnue' });
    return { status: 500, corps: { erreur: 'erreur_interne' } };
  }
}
