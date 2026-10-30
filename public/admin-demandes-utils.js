/**
 * Fonctions pures de l'onglet admin « Demandes » (SPEC 1 §4) : libellés, règle d'approbation, SLA, raisons de doublon.
 * Sans réseau ni DOM, testées avec Jest (tests/admin-demandes-utils.test.js). Chargées sous `window.AdminDemandesUtils`.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AdminDemandesUtils = factory();
}(typeof self !== 'undefined' ? self : this, function () {
  var STATUTS = { submitted: 'Soumise', in_review: 'En revue', needs_info: 'Compléments demandés', rejected: 'Refusée', approved: 'Approuvée' };
  var ELEMENTS = [
    ['ordre_ok', 'Numéro d\'Ordre cohérent avec le nom du titulaire et l\'attestation'],
    ['autorisation_ok', 'Autorisation d\'exploitation lisible et valide'],
    ['rappel_tel_ok', 'Rappel téléphonique au numéro fixe de l\'officine (le numéro répond et confirme le nom)'],
    ['adresse_gps_ok', 'Adresse et GPS cohérents sur la carte'],
    ['pas_doublon', 'Aucun doublon avec une pharmacie existante']
  ];
  var RAISONS = { telephone: 'Même téléphone', numero_ordre: 'Même numéro d\'Ordre', nom_quartier: 'Même nom dans le même quartier', gps_30m: 'À moins de 30 m d\'une pharmacie existante' };
  var NATURES = { ordre_attestation: 'Attestation d\'Ordre', autorisation_exploitation: 'Autorisation d\'exploitation', id_titulaire: 'Pièce d\'identité', autre: 'Complément' };
  var ERREURS = {
    checklist_incomplete: 'Approbation impossible : les 5 cases de la checklist doivent être cochées.',
    motif_obligatoire: 'Un motif est obligatoire.', etat_invalide: 'La demande n\'est pas dans l\'état attendu.', refuse: 'Action réservée à l\'administrateur.',
    introuvable: 'Demande introuvable.'
  };

  function libelleStatut(s) { return STATUTS[s] || s; }
  function libelleNature(n) { return NATURES[n] || n; }
  function libellesRaisons(r) { return (r || []).map(function (x) { return RAISONS[x] || x; }); }
  function messageErreur(code) { return ERREURS[code] || 'Une erreur est survenue.'; }

  /** Éléments de checklist avec leur état : [{ element, libelle, coche }]. */
  function etatChecklist(cochees) {
    var set = {}; (cochees || []).forEach(function (c) { set[c.element || c] = true; });
    return ELEMENTS.map(function (e) { return { element: e[0], libelle: e[1], coche: !!set[e[0]] }; });
  }
  /** L'approbation exige les 5 cases (la base le refuse aussi). */
  function peutApprouver(statut, cochees) { return statut === 'in_review' && etatChecklist(cochees).every(function (e) { return e.coche; }); }
  /** Actions possibles selon le statut. */
  function actionsPossibles(statut) {
    if (statut === 'submitted' || statut === 'needs_info') return ['demarrer'];
    if (statut === 'in_review') return ['approuver', 'complements', 'refuser'];
    if (statut === 'approved') return ['renvoyer_invitation'];
    return [];
  }
  /** SLA : cible 48 h ; renvoie { texte, retard }. */
  function formaterAge(heures, enRetard) {
    var t = heures < 1 ? '< 1 h' : heures < 48 ? heures + ' h' : Math.floor(heures / 24) + ' j';
    return { texte: t, retard: enRetard === true };
  }

  return { ELEMENTS: ELEMENTS, libelleStatut: libelleStatut, libelleNature: libelleNature, libellesRaisons: libellesRaisons, messageErreur: messageErreur,
    etatChecklist: etatChecklist, peutApprouver: peutApprouver, actionsPossibles: actionsPossibles, formaterAge: formaterAge };
}));
