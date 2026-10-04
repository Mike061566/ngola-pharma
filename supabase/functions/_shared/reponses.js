// Réponses des pharmacies (SPEC 2 §5) : webhook Telegram (boutons, /start, /stop, /aide, fichiers) et lien de réponse /r/<code>.
// Toute réponse passe par `magasin.enregistrerReponse` (fonction SQL atomique et idempotente : une réponse par envoi, stock mis à jour).
// Sécurité d'un clic Telegram : (a) en-tête secret vérifié par l'adaptateur HTTP, (b) le chat doit être un contact VÉRIFIÉ, actif,
// d'une pharmacie, (c) callback_data r:<8 hex>:a|u résolu DANS la pharmacie de ce contact seulement. Sinon : ignoré et journalisé.
// Aucun contenu de message, identifiant de chat ni jeton n'est journalisé ; aucun fichier reçu n'est conservé.
import { sha256Hex, hmacHex } from './securite.js';
import { chiffrer, versBytea } from './chiffrement.js';
import { enfiler } from './file-sortie.js';
import { heureLocale } from './planificateur.js';

const JETON = /^[A-Za-z0-9_-]{16,128}$/;
const DONNEES = /^r:([0-9a-f]{8}):(a|u)$/;
const CODE_REPONSE = /^[0-9A-HJKMNP-TV-Z]{10}$/;
const LIBELLE = { available: 'Disponible', unavailable: 'Indisponible' };
const MEDIAS_REFUSES = ['photo', 'document'];

/** Analyse un « update » Telegram : renvoie { type, chatId, ... } ou { type: 'ignore', raison }. Fonction pure. */
export function analyserMiseAJour(u) {
  if (!u || typeof u !== 'object') return { type: 'ignore', raison: 'invalide' };
  if (u.callback_query) {
    const c = u.callback_query, m = c.message;
    if (!m || !m.chat || m.chat.type !== 'private' || !c.from || String(c.from.id) !== String(m.chat.id)) return { type: 'ignore', raison: 'chat_non_prive' };
    return { type: 'callback', chatId: String(m.chat.id), idCallback: String(c.id || ''), messageId: m.message_id, donnees: typeof c.data === 'string' ? c.data : '' };
  }
  const m = u.message;
  if (!m || !m.chat || m.chat.type !== 'private') return { type: 'ignore', raison: 'chat_non_prive' };   // chats privés uniquement
  const chatId = String(m.chat.id);
  const nom = m.from && typeof m.from.first_name === 'string' ? m.from.first_name.slice(0, 40) : '';
  if (MEDIAS_REFUSES.some((k) => m[k])) return { type: 'media', chatId };
  if (typeof m.text === 'string') {
    const mt = /^\/(start|stop|aide|help)(?:@\w+)?(?:\s+(\S+))?\s*$/i.exec(m.text.trim());
    if (mt) {
      const cmd = mt[1].toLowerCase();
      if (cmd === 'start') return { type: 'start', chatId, nom, jeton: mt[2] && JETON.test(mt[2]) ? mt[2] : null };
      if (cmd === 'stop') return { type: 'stop', chatId };
      return { type: 'aide', chatId };
    }
  }
  return { type: 'texte', chatId };
}

export function texteConfirmation(reponse, heure) { return `✅ Réponse enregistrée à ${heure} : ${LIBELLE[reponse]}. Merci !`; }
export function texteCollegue(heure) { return `ℹ️ Déjà traitée par un collègue à ${heure}.`; }

/** Met à jour (editMessageText, sans boutons) les messages Telegram d'un envoi. `sauf` : discussion déjà traitée. Erreurs non bloquantes. */
async function mettreAJourMessages({ magasin, fournisseur, journal }, envoiId, texteFn, sauf = null) {
  let n = 0;
  for (const m of await magasin.messagesTelegramEnvoi(envoiId)) {
    if (sauf && String(m.id_discussion_fournisseur) === String(sauf)) continue;
    try {
      await fournisseur.modifierMessage({ idDiscussion: m.id_discussion_fournisseur, idMessage: m.id_message_fournisseur, texte: texteFn(m), boutons: [] });
      n += 1;
    } catch (e) { journal({ evt: 'edition_echouee', erreur: e?.name || 'inconnue' }); }
  }
  return n;
}

/**
 * Après une réponse reçue par le lien ou l'Espace Pro : les messages Telegram de la pharmacie perdent leurs boutons.
 * (Une réponse donnée par Telegram est traitée dans `traiterMiseAJour`.)
 */
export async function apresReponseHorsTelegram(ctx, envoiId, resultat, decalage) {
  if (resultat.resultat !== 'enregistree' && resultat.resultat !== 'deja_traitee') return;
  const heure = heureLocale(new Date(resultat.repondu_le), decalage);
  await mettreAJourMessages(ctx, envoiId, () => texteConfirmation(resultat.reponse, heure));
}

/**
 * @param update  JSON reçu de Telegram (déjà authentifié par l'en-tête secret)
 * @param ctx     { magasin, cle, fournisseur (Telegram), env: { SIGNING_SECRET }, config, maintenant?, journal? }
 */
export async function traiterMiseAJour(update, ctx) {
  const { magasin, cle, fournisseur, env = {}, config = {}, journal = () => {}, maintenant = () => new Date() } = ctx;
  const a = analyserMiseAJour(update);
  const decalage = Number.isFinite(config.decalage_horaire_min) ? config.decalage_horaire_min : 60;
  const cleUpdate = `tg:${update && update.update_id !== undefined ? update.update_id : maintenant().getTime()}`;

  // Réponse conversationnelle : via l'outbox (liste blanche de la démo, idempotence par update_id).
  const repondre = async (modele, variables = {}, { type = 'pharmacy', ref = null, contactId = null, demo = null } = {}) => {
    const estDemo = demo !== null ? demo : await magasin.adresseEstContactDemo(a.chatId);
    await enfiler(magasin, cle, { typeDestinataire: type, destinataireRef: ref, canal: 'telegram', modele, adresse: a.chatId, variables,
      cleBase: `${cleUpdate}:${modele}`, contactId, estDestinataireDemo: estDemo });
  };

  if (a.type === 'ignore') { journal({ evt: 'ignore', raison: a.raison }); return { type: 'ignore' }; }

  if (a.type === 'media') { await repondre('ordonnance_refus'); return { type: 'media' }; }          // fichier ignoré, jamais conservé
  if (a.type === 'aide' || a.type === 'texte') { await repondre('aide_bot'); return { type: a.type }; }

  if (a.type === 'stop') {
    const n = await magasin.desabonnerTelegram(a.chatId);                                             // contacts de pharmacie
    await magasin.retirerPatientTelegram(await hmacHex(env.SIGNING_SECRET, `tg:${a.chatId}`));        // alertes de patient
    await repondre('desabonnement_ok');
    return { type: 'stop', contacts: n };
  }

  if (a.type === 'start') {
    if (!a.jeton) { await repondre('lien_invalide'); journal({ evt: 'start_sans_jeton' }); return { type: 'start', resultat: 'invalide' }; }
    const j = await magasin.consommerJeton(await sha256Hex(a.jeton));          // usage unique, non expiré (SQL atomique)
    if (!j) { await repondre('lien_invalide'); journal({ evt: 'jeton_refuse' }); return { type: 'start', resultat: 'refuse' }; }
    if (j.objet === 'pharmacy_contact') {
      const r = await magasin.lierContactTelegram(j.ref_id, a.chatId);
      if (r.resultat === 'active') {
        await repondre('telegram_activation', { nom: a.nom || 'Pharmacien', pharmacie: r.pharmacie_nom }, { ref: r.pharmacie_id, contactId: r.contact_id, demo: r.est_contact_demo === true });
        return { type: 'start', resultat: 'active' };
      }
      await repondre(r.resultat === 'limite_contacts' ? 'limite_contacts' : 'lien_invalide');
      return { type: 'start', resultat: r.resultat };
    }
    if (j.objet === 'patient_alert') {
      await magasin.lierPatientTelegram(j.ref_id, versBytea(await chiffrer(cle, a.chatId)), await hmacHex(env.SIGNING_SECRET, `tg:${a.chatId}`));
      await repondre('patient_lie', {}, { type: 'patient' });
      return { type: 'start', resultat: 'patient' };
    }
    await repondre('lien_invalide');
    return { type: 'start', resultat: 'invalide' };
  }

  // ── callback : bouton « Disponible » / « Indisponible » ──
  const m = DONNEES.exec(a.donnees);
  const contacts = (await magasin.contactsParChat(a.chatId)).filter((c) => c.verifie_le && !c.desabonne_le && !c.bloque_le);
  if (!m || contacts.length === 0) {
    journal({ evt: 'callback_ignore', raison: !m ? 'donnees_invalides' : 'chat_inconnu' });         // aucun identifiant de chat journalisé
    return { type: 'callback', resultat: 'ignore' };
  }
  const acquitter = async (texte) => { try { await fournisseur.repondreCallback({ idCallback: a.idCallback, texte }); } catch (e) { journal({ evt: 'acquittement_echoue', erreur: e?.name || 'inconnue' }); } };
  const modifierPropre = async (texte) => { try { await fournisseur.modifierMessage({ idDiscussion: a.chatId, idMessage: a.messageId, texte, boutons: [] }); } catch (e) { journal({ evt: 'edition_echouee', erreur: e?.name || 'inconnue' }); } };

  let envoiId = null;
  for (const c of contacts) { envoiId = await magasin.trouverEnvoiCourt(c.pharmacie_id, m[1]); if (envoiId) break; }
  if (!envoiId) { await acquitter('Demande introuvable ou expirée.'); journal({ evt: 'envoi_introuvable' }); return { type: 'callback', resultat: 'introuvable' }; }

  const reponse = m[2] === 'a' ? 'available' : 'unavailable';
  const r = await magasin.enregistrerReponse(envoiId, reponse, null, 'telegram', null);
  if (r.resultat === 'enregistree') {
    const heure = heureLocale(new Date(r.repondu_le), decalage);
    await modifierPropre(texteConfirmation(reponse, heure));
    await mettreAJourMessages(ctx, envoiId, () => texteCollegue(heure), a.chatId);                   // les collègues : « déjà traitée »
    await acquitter('Réponse enregistrée');
  } else if (r.resultat === 'deja_traitee') {
    await modifierPropre(texteCollegue(heureLocale(new Date(r.repondu_le), decalage)));
    await acquitter('Déjà traitée');
  } else {
    await modifierPropre('⌛ Cette demande a expiré.');
    await acquitter('Demande expirée');
  }
  return { type: 'callback', resultat: r.resultat };
}

// ── Lien de réponse /r/<code> (SMS, email, bouton « Préciser le prix ») ──
export function codeValide(code) { return typeof code === 'string' && CODE_REPONSE.test(code); }

/**
 * GET : informations affichées sur la page (aucune donnée patient). POST : enregistre la réponse (idempotent).
 * @returns {{status:number, corps:object}}
 */
export async function traiterLien(methode, entree, ctx) {
  const { magasin, config = {} } = ctx;
  if (!codeValide(entree.code)) return { status: 404, corps: { erreur: 'introuvable' } };
  const e = await magasin.envoiParCode(entree.code);
  if (!e) return { status: 404, corps: { erreur: 'introuvable' } };
  const decalage = Number.isFinite(config.decalage_horaire_min) ? config.decalage_horaire_min : 60;

  if (methode === 'GET') {
    const actif = e.statut === 'sent' && !['expired', 'cancelled', 'fulfilled'].includes(e.alerte_statut) && new Date(e.expire_le).getTime() > ctx.maintenant().getTime();
    return { status: 200, corps: {
      pharmacie: e.pharmacie_nom, medicament: e.medicament, forme: e.forme, quartier: e.quartier, sur_ordonnance: e.sur_ordonnance === true,
      urgence: e.urgence, expire_le: e.expire_le, prix_prefill: e.prix_stock ?? null,
      etat: e.reponse ? 'repondu' : actif ? 'ouvert' : 'expire', reponse: e.reponse ?? null, prix: e.prix_repondu ?? null,
      heure_reponse: e.repondu_le ? heureLocale(new Date(e.repondu_le), decalage) : null } };
  }
  const reponse = entree.reponse, prix = entree.prix;
  if (!['available', 'unavailable'].includes(reponse)) return { status: 400, corps: { erreur: 'reponse_invalide' } };
  if (prix !== undefined && prix !== null && !(Number.isInteger(prix))) return { status: 400, corps: { erreur: 'prix_invalide' } };
  const r = await magasin.enregistrerReponse(e.id, reponse, prix ?? null, 'link', null);
  if (r.resultat === 'prix_invalide') return { status: 400, corps: { erreur: 'prix_invalide' } };
  if (r.resultat === 'expiree') return { status: 410, corps: { erreur: 'expiree' } };
  if (r.resultat === 'introuvable') return { status: 404, corps: { erreur: 'introuvable' } };
  await apresReponseHorsTelegram(ctx, e.id, r, decalage);
  return { status: 200, corps: { resultat: r.resultat, deja: r.resultat === 'deja_traitee', reponse: r.reponse, prix: r.prix_fcfa ?? null, heure: heureLocale(new Date(r.repondu_le), decalage) } };
}
