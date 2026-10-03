/**
 * Fonctions pures de la console admin des alertes (affichage, actions autorisées, saisie des réglages).
 * Sans réseau ni DOM : testées avec Jest (tests/admin-utils.test.js). Chargées dans le navigateur sous `window.AdminUtils`.
 * L'autorité reste la base de données (les fonctions admin_* refusent ce que l'interface ne propose pas).
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AdminUtils = factory();
}(typeof self !== 'undefined' ? self : this, function () {
  var STATUTS = {
    new: 'Nouvelle', routing: 'En recherche', escalated: 'Escaladée', answered: 'Répondue', needs_review: 'À examiner',
    fulfilled: 'Clôturée', expired: 'Expirée', cancelled: 'Annulée'
  };
  var RAISONS = { restreint: 'Médicament restreint', non_reconnu: 'Médicament non reconnu', classification_non_validee: 'Classification non validée', fiche_archivee: 'Fiche archivée' };
  var REFUS = { non_verifiee: 'non vérifiée', aucun_contact_actif: 'aucun contact actif', deja_sollicitee: 'déjà sollicitée', introuvable: 'introuvable', demo_en_production: 'pharmacie de démonstration' };
  var FINAUX = ['fulfilled', 'expired', 'cancelled'];

  function libelleStatut(s) { return STATUTS[s] || s || ''; }
  function libelleRaison(r) { return RAISONS[r] || r || ''; }
  function libelleRefus(r) { return REFUS[r] || r || ''; }

  /** 330 -> « 5 min 30 s » ; null -> « — ». */
  function formaterDuree(s) {
    if (s === null || s === undefined || !isFinite(Number(s))) return '—';
    s = Math.round(Number(s));
    if (s < 60) return s + ' s';
    var m = Math.floor(s / 60), r = s % 60;
    if (m < 60) return m + ' min' + (r ? ' ' + r + ' s' : '');
    var h = Math.floor(m / 60);
    return h + ' h' + (m % 60 ? ' ' + (m % 60) + ' min' : '');
  }

  /** 0.5 -> « 50 % » ; null -> « — ». */
  function pourcentage(x) {
    if (x === null || x === undefined || !isFinite(Number(x))) return '—';
    return Math.round(Number(x) * 1000) / 10 + ' %';
  }

  /**
   * Actions proposées pour une alerte de la file (miroir des règles SQL ; la base a le dernier mot).
   * a : { statut, routage_manuel, nb_positives, medicament_id? (ou medicament connu) }.
   */
  function actionsPossibles(a) {
    var fini = FINAUX.indexOf(a.statut) !== -1;
    var enRevue = a.statut === 'needs_review';
    return {
      rattacher: enRevue,
      refuser: enRevue,
      transmettre: !fini && a.avec_medicament !== false,
      relancer: (a.statut === 'routing' || a.statut === 'escalated') && !a.routage_manuel && !(a.nb_positives > 0),
      cloturer: a.statut === 'routing' || a.statut === 'escalated' || a.statut === 'answered',
      annuler: !fini,
      bloquer: true
    };
  }

  /** Une ligne de la chronologie, en français. Aucune donnée personnelle : tout vient de la fonction SQL chronologie_alerte. */
  function libelleEvenement(e) {
    switch (e.type) {
      case 'creation': return 'Demande créée' + (e.urgence === 'urgent' ? ' (urgente)' : '');
      case 'envoi': return 'Envoyée à ' + e.pharmacie + ' (vague ' + e.vague + ', score ' + e.score + ')' + (e.detail_score && e.detail_score.manuel ? ' — transmission manuelle' : '');
      case 'relance_sms': return 'SMS de relance à ' + e.pharmacie;
      case 'reponse': return e.pharmacie + ' : ' + (e.reponse === 'available' ? 'Disponible' + (e.prix_fcfa ? ' (' + e.prix_fcfa + ' FCFA)' : '') : 'Indisponible') + ' via ' + e.canal;
      case 'message': return 'Message ' + e.canal + ' (' + e.modele + ') : ' + e.statut + (e.erreur ? ' — ' + e.erreur : '');
      case 'escalade': return 'Escalade vers l\'équipe';
      case 'premiere_reponse_positive': return 'Première réponse positive';
      case 'patient_notifie': return 'Patient informé';
      case 'second_message': return 'Second message au patient';
      case 'action_admin': return 'Action admin : ' + e.action;
      default: return e.type;
    }
  }

  /** Saisie d'un réglage : le texte est du JSON (3, 0.5, true, [30,120], {"a":1}). Contrôle de forme seulement ; la base valide les bornes. */
  function analyserValeurConfig(texte) {
    var t = String(texte === null || texte === undefined ? '' : texte).trim();
    if (t === '') return { ok: false, erreur: 'Valeur vide' };
    try { return { ok: true, valeur: JSON.parse(t) }; } catch (e) { return { ok: false, erreur: 'Valeur invalide (JSON attendu : 3, 0.5, true, [30, 120]…)' }; }
  }

  /** Niveau d'alerte du budget : 'ok' | 'alerte' (≥ 80 %) | 'depasse' (≥ 100 %). */
  function niveauBudget(b) {
    if (!b) return 'ok';
    if (b.depasse) return 'depasse';
    return b.alerte_80 ? 'alerte' : 'ok';
  }

  /** Réglages triés pour l'affichage (clés techniques d'abord regroupées par préfixe) ; `mode_application` exclu (verrou de production). */
  function reglagesAffichables(lignes) {
    return (lignes || []).filter(function (l) { return l.cle !== 'mode_application'; })
      .sort(function (a, b) { return a.cle < b.cle ? -1 : a.cle > b.cle ? 1 : 0; });
  }

  return { libelleStatut: libelleStatut, libelleRaison: libelleRaison, libelleRefus: libelleRefus, formaterDuree: formaterDuree,
    pourcentage: pourcentage, actionsPossibles: actionsPossibles, libelleEvenement: libelleEvenement,
    analyserValeurConfig: analyserValeurConfig, niveauBudget: niveauBudget, reglagesAffichables: reglagesAffichables };
}));
