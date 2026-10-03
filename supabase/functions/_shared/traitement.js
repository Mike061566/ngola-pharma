// Worker de l'outbox (SPEC 2 §6) : prélève par lots, applique les règles, envoie via le fournisseur du canal,
// réessaie (30 s / 2 min / 5 min), bascule sur le canal suivant, respecte les limites de débit et le budget.
//
// Règles (dans l'ordre, pour chaque ligne) :
//  1. trop de tentatives (worker planté en boucle)         -> échec définitif + repli
//  2. mode démo et destinataire hors liste blanche          -> suppressed_demo, AUCUN appel au fournisseur
//  3. contact désabonné                                      -> annulé ; contact bloqué -> repli
//  4. SMS au-delà du budget quotidien (hors exemption)       -> annulé
//  5. modèle invalide                                        -> échec définitif, sans repli
//  6. débit (1 msg/s par discussion Telegram, plafond global) -> reporté, sans compter une tentative
//  7. envoi ; erreur transitoire -> réessai ; permanente -> repli ; 429 -> reporté après retry_after
// Journal : identifiants, canal, modèle, codes d'erreur. Jamais d'adresse, de texte de message ni de variables.
import { CANAUX, CANAUX_PAYANTS, modeleDeRepli } from './canaux.js';
import { rendre } from './modeles.js';
import { chiffrer, dechiffrer, depuisBytea, versBytea } from './chiffrement.js';
import { creerLimiteur } from './limiteur.js';
import { ErreurFournisseur, ErreurModele } from './erreurs.js';
import { cleIdempotence } from './file-sortie.js';

const nombre = (v, defaut) => (typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : defaut);

export function lireParametres(config = {}) {
  const delais = Array.isArray(config.retry_delais_s) && config.retry_delais_s.every((x) => Number.isFinite(x) && x >= 0)
    ? config.retry_delais_s : [30, 120, 300];
  return {
    mode: config.mode_application === 'production' ? 'production' : 'demo',   // inconnu = démo (comportement sûr)
    delaisS: delais,
    maxTentatives: delais.length + 1,                                          // 1re tentative + relances
    lot: Math.max(1, nombre(config.worker_lot_taille, 20)),
    bailS: Math.max(1, nombre(config.worker_bail_s, 120)),
    debitGlobal: nombre(config.debit_global_par_s, 20),
    debitDiscussionMs: nombre(config.debit_par_discussion_ms, 1000),
    budget: nombre(config.budget_messages_jour, 50),
  };
}

export async function traiterOutbox({ magasin, fournisseurs, cle, maintenant = () => new Date(),
  dormir = (ms) => new Promise((r) => setTimeout(r, ms)), journal = () => {}, dureeMaxMs = 50000 }) {
  const params = lireParametres(await magasin.lireConfig());
  const limiteur = creerLimiteur({ parSeconde: params.debitGlobal, parDiscussionMs: params.debitDiscussionMs,
    maintenant: () => maintenant().getTime(), dormir });
  const resume = { traites: 0, envoyes: 0, supprimes_demo: 0, annules: 0, reessais: 0, reportes: 0, replis: 0, echecs: 0 };
  let payants = null;   // messages payants déjà envoyés aujourd'hui (lu une fois, puis tenu à jour localement)
  const debut = maintenant().getTime();

  const note = (evt, ligne, extra = {}) => journal({ evt, id: ligne.id, canal: ligne.canal, modele: ligne.modele, ...extra });

  async function repli(ligne, raison) {
    // Repli de canal pour une pharmacie : telegram -> sms -> email, parmi les contacts actifs de la pharmacie.
    if (ligne.type_destinataire !== 'pharmacy' || !ligne.destinataire_ref) return false;
    const tentes = [...new Set([...(ligne.canaux_tentes || []), ligne.canal])];
    const contacts = await magasin.lireContactsPharmacie(ligne.destinataire_ref);
    for (const canal of CANAUX) {
      if (tentes.includes(canal)) continue;
      const modele = modeleDeRepli(ligne.modele, canal);
      if (!modele) continue;
      const dispo = contacts.filter((c) => c.canal === canal && !c.desabonne_le && !c.bloque_le && (canal !== 'telegram' || c.verifie_le));
      if (dispo.length === 0) continue;
      const base = ligne.cle_base || ligne.id;
      for (const c of dispo) {
        await magasin.enfiler({
          cle_idempotence: cleIdempotence(base, canal, modele, c.id),
          type_destinataire: ligne.type_destinataire,
          destinataire_ref: ligne.destinataire_ref,
          canal, modele,
          adresse_chiffree: versBytea(await chiffrer(cle, c.adresse)),
          variables: ligne.variables || {},
          contact_id: c.id,
          cle_base: base,
          canaux_tentes: tentes,
          est_destinataire_demo: c.est_contact_demo === true,
          exempte_budget: ligne.exempte_budget === true,
        });
      }
      resume.replis += 1;
      note('repli', ligne, { vers: canal, raison });
      return true;
    }
    return false;
  }

  async function echecDefinitif(ligne, raison, { avecRepli = true } = {}) {
    await magasin.marquer(ligne.id, 'failed', raison);
    resume.echecs += 1;
    note('echec', ligne, { raison });
    if (avecRepli) await repli(ligne, raison);
  }

  async function traiterLigne(ligne) {
    resume.traites += 1;
    if (ligne.tentatives > params.maxTentatives) return echecDefinitif(ligne, 'trop_de_tentatives');

    if (params.mode === 'demo' && ligne.est_destinataire_demo !== true) {
      await magasin.marquer(ligne.id, 'suppressed_demo', null);
      resume.supprimes_demo += 1;
      return note('supprime_demo', ligne);
    }

    const contact = ligne.contact_id ? await magasin.lireContact(ligne.contact_id) : null;
    if (contact && contact.desabonne_le) {
      await magasin.marquer(ligne.id, 'cancelled', 'desabonne');
      resume.annules += 1;
      return note('annule', ligne, { raison: 'desabonne' });
    }
    if (contact && contact.bloque_le) return echecDefinitif(ligne, 'contact_bloque');

    if (ligne.canal === 'sms' && ligne.exempte_budget !== true) {
      if (payants === null) payants = await magasin.compterPayantsDuJour();
      if (payants >= params.budget) {
        await magasin.marquer(ligne.id, 'cancelled', 'budget_depasse');
        resume.annules += 1;
        return note('annule', ligne, { raison: 'budget_depasse' });
      }
    }

    const fournisseur = fournisseurs[ligne.canal];
    if (!fournisseur) return echecDefinitif(ligne, 'fournisseur_absent', { avecRepli: true });

    let message, adresse;
    try {
      message = rendre(ligne.modele, ligne.canal, ligne.variables);
      adresse = await dechiffrer(cle, depuisBytea(ligne.adresse_chiffree));
    } catch (e) {
      const raison = e instanceof ErreurModele ? 'modele_invalide' : 'adresse_illisible';
      return echecDefinitif(ligne, raison, { avecRepli: false });
    }

    if (ligne.canal === 'telegram') {
      const attente = limiteur.delaiDiscussion(adresse);
      if (attente > 0) {
        await magasin.reporter(ligne.id, new Date(maintenant().getTime() + attente), { tentatives: ligne.tentatives - 1 });
        resume.reportes += 1;
        return note('reporte', ligne, { raison: 'debit_discussion' });
      }
    }

    let res;
    try {
      await limiteur.attendreGlobal();
      res = await fournisseur.envoyer({ ...message, adresse, cleIdempotence: ligne.cle_idempotence,
        idOutbox: ligne.id, modele: ligne.modele });
    } catch (e) {
      if (e instanceof ErreurFournisseur && e.type === 'limite_debit') {
        const s = e.retryApresS ?? 1;
        await magasin.reporter(ligne.id, new Date(maintenant().getTime() + s * 1000), { tentatives: ligne.tentatives - 1, erreur: 'limite_debit' });
        resume.reportes += 1;
        return note('reporte', ligne, { raison: 'limite_debit', apresS: s });
      }
      if (e instanceof ErreurFournisseur && e.type === 'permanente') {
        if (e.bloque && ligne.contact_id) await magasin.bloquerContact(ligne.contact_id);
        return echecDefinitif(ligne, e.bloque ? 'contact_bloque' : 'echec_permanent');
      }
      // transitoire, ou erreur inattendue du fournisseur (traitée comme transitoire ; seul le nom de l'erreur est journalisé)
      const code = e instanceof ErreurFournisseur ? 'echec_transitoire' : `erreur_${e?.name || 'inconnue'}`;
      if (ligne.tentatives <= params.delaisS.length) {
        const delai = params.delaisS[ligne.tentatives - 1];
        await magasin.reporter(ligne.id, new Date(maintenant().getTime() + delai * 1000), { erreur: code });
        resume.reessais += 1;
        return note('reessai', ligne, { tentative: ligne.tentatives, dansS: delai });
      }
      return echecDefinitif(ligne, code);
    }
    // Message accepté par le fournisseur. Si l'écriture en base échoue ICI, on NE réessaie PAS l'envoi dans ce
    // passage (erreur remontée à la boucle) : le bail expirera et la ligne sera reprise (livraison « au moins une fois »).
    if (ligne.canal === 'telegram') limiteur.marquerEnvoi(adresse);
    await magasin.marquerEnvoye(ligne.id, { idMessage: res?.idMessage ?? null, idDiscussion: res?.idDiscussion ?? null });
    resume.envoyes += 1;
    if (CANAUX_PAYANTS.includes(ligne.canal) && payants !== null) payants += 1;
    note('envoye', ligne);
  }

  while (maintenant().getTime() - debut < dureeMaxMs) {
    const lot = await magasin.reclamer(params.lot, params.bailS);
    if (!lot || lot.length === 0) break;
    for (const ligne of lot) {
      try {
        await traiterLigne(ligne);
      } catch (e) {
        // Erreur d'infrastructure sur UNE ligne (base indisponible...) : le bail expirera et la ligne sera reprise.
        journal({ evt: 'erreur_ligne', id: ligne.id, erreur: e?.name || 'inconnue' });
      }
    }
  }
  return resume;
}
