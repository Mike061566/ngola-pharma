/**
 * Fonctions pures de la page patient « Alerte de disponibilité » (alerte.html) : validation du formulaire, normalisation
 * du numéro, messages d'erreur, lecture de l'identifiant dans l'URL. Sans réseau ni DOM, testées avec Jest
 * (tests/alerte-utils.test.js). Chargées dans le navigateur sous `window.AlerteUtils`.
 * Aucune ordonnance n'est demandée, collectée ni envoyée (CLAUDE.md règle 5).
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AlerteUtils = factory();
}(typeof self !== 'undefined' ? self : this, function () {
  var MESSAGES = {
    ordonnance_interdite: 'Aucune ordonnance ne doit être envoyée : elle se présente à la pharmacie, lors de l\'achat ou du retrait.',
    medicament_ou_requete: 'Choisissez un médicament dans la liste.',
    quartier_invalide: 'Choisissez un quartier.',
    telephone_invalide: 'Numéro de téléphone invalide (ex. 6XX XX XX XX).',
    consentement_requis: 'Votre consentement est nécessaire pour recevoir un SMS.',
    captcha_invalide: 'Vérification anti-robot échouée. Réessayez.',
    captcha_indisponible: 'Vérification anti-robot indisponible. Réessayez dans un instant.',
    routage_desactive: 'La recherche automatique n\'est pas disponible pour le moment. Contactez une pharmacie de garde.',
    limite_quotidienne: 'Trop de demandes aujourd\'hui. Réessayez demain ou rendez-vous dans une pharmacie de garde.',
    refuse: 'Demande refusée.'
  };
  var LIBELLES = {
    new: 'Demande enregistrée', routing: 'Recherche en cours auprès des pharmacies',
    escalated: 'Recherche en cours, notre équipe suit votre demande', answered: 'Une pharmacie a confirmé la disponibilité',
    needs_review: 'Votre demande sera examinée par notre équipe avant toute transmission', fulfilled: 'Demande clôturée',
    expired: 'Aucune pharmacie n\'a confirmé pour le moment', cancelled: 'Demande annulée'
  };
  var FINAUX = ['fulfilled', 'expired', 'cancelled'];

  function messageErreur(code) {
    return MESSAGES[code] || 'Une erreur est survenue. Réessayez.';
  }

  function libelleStatut(statut) { return LIBELLES[statut] || ''; }

  /** Un suivi continue tant que l'alerte n'est pas dans un état final. */
  function suiviTermine(statut) { return FINAUX.indexOf(statut) !== -1; }

  /** Numéro camerounais -> +237XXXXXXXXX, ou null (même règle que le serveur, pour un retour immédiat). */
  function normaliserTelephone(brut) {
    if (typeof brut !== 'string') return null;
    var t = brut.replace(/[\s.\-()]/g, '');
    if (t.indexOf('+237') === 0) t = t.slice(4);
    else if (t.indexOf('00237') === 0) t = t.slice(5);
    else if (t.indexOf('237') === 0 && t.length === 12) t = t.slice(3);
    return /^[2368]\d{8}$/.test(t) ? '+237' + t : null;
  }

  /** v : { medicament_id, quartier_id, urgence, canal, telephone, consentement }. Renvoie { ok, erreurs: {champ: message} }. */
  function validerFormulaire(v) {
    var e = {};
    if (!v.medicament_id) e.medicament = MESSAGES.medicament_ou_requete;
    if (!v.quartier_id) e.quartier = MESSAGES.quartier_invalide;
    if (v.canal === 'sms') {
      if (!normaliserTelephone(v.telephone)) e.telephone = MESSAGES.telephone_invalide;
      if (v.consentement !== true) e.consentement = MESSAGES.consentement_requis;
    }
    return { ok: Object.keys(e).length === 0, erreurs: e };
  }

  /** Corps envoyé à `creer-alerte` : liste blanche de champs, le numéro seulement pour le canal SMS. */
  function construireCorps(v, captcha) {
    var corps = { medicament_id: v.medicament_id, quartier_id: v.quartier_id, urgence: v.urgence === 'urgent' ? 'urgent' : 'normal',
      canal: v.canal === 'sms' || v.canal === 'telegram' ? v.canal : 'none', captcha: captcha };
    if (corps.canal === 'sms') { corps.telephone = v.telephone; corps.consentement = v.consentement === true; }
    return corps;
  }

  /** /alerte/NG-XXXXXXXX -> « NG-XXXXXXXX » (ou null si l'identifiant n'a pas le bon format). */
  function idDepuisChemin(chemin) {
    var m = /^\/alerte\/(NG-[0-9A-HJKMNP-TV-Z]{8})\/?$/.exec(String(chemin || ''));
    return m ? m[1] : null;
  }

  /** Échappement pour insertion dans du HTML (toute donnée serveur affichée passe par ici). */
  function echapper(s) {
    return String(s === null || s === undefined ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', '\'': '&#39;' }[c];
    });
  }

  /** Terme de recherche pour `ilike` : caractères joker et séparateurs retirés (jamais interprétés comme syntaxe). */
  function termeRecherche(s) {
    return String(s || '').replace(/[%_*,()\\]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 60);
  }

  return { messageErreur: messageErreur, libelleStatut: libelleStatut, suiviTermine: suiviTermine, normaliserTelephone: normaliserTelephone,
    validerFormulaire: validerFormulaire, construireCorps: construireCorps, idDepuisChemin: idDepuisChemin, echapper: echapper,
    termeRecherche: termeRecherche };
}));
