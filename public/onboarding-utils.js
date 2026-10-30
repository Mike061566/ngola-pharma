/**
 * Fonctions pures de la checklist d'onboarding de l'Espace Pro (SPEC 1 §5, §5.2) : libellés, progression, prochaine tâche,
 * code couleur de fraîcheur des stocks, contrôle du mot de passe. Sans réseau ni DOM, testées avec Jest
 * (tests/onboarding-utils.test.js). Chargées dans le navigateur sous `window.OnboardingUtils`.
 * L'état vient de la fonction SQL `etat_onboarding_mien` : le calcul fait foi côté base, ce fichier n'affiche que.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.OnboardingUtils = factory();
}(typeof self !== 'undefined' ? self : this, function () {
  var TACHES = {
    mot_de_passe: { titre: 'Définir mon mot de passe', aide: 'Pour vous reconnecter sans lien par email.' },
    ma_pharmacie: { titre: 'Compléter « Ma Pharmacie »', aide: 'Vos horaires renseignés et la position de l\'officine confirmée.' },
    telegram: { titre: 'Activer Telegram', aide: 'Recevez les demandes des patients en temps réel. Jusqu\'à 3 agents peuvent activer leur compte.' },
    import: { titre: 'Importer mes stocks', aide: 'Au moins un médicament enregistré (import ou ajout manuel).' },
    confirmation: { titre: 'Confirmer mes stocks', aide: 'Un clic pour dire que la liste est à jour aujourd\'hui.' },
    seuil: { titre: 'Seuil de publication', aide: 'Assez de médicaments confirmés récemment pour apparaître auprès des patients.' }
  };
  var ORDRE = ['mot_de_passe', 'ma_pharmacie', 'telegram', 'import', 'confirmation', 'seuil'];

  /** Tâches de l'état SQL, dans l'ordre de la spec, avec libellés : [{ cle, titre, aide, fait, detail }]. */
  function tachesAffichables(etat) {
    var items = (etat && etat.items) || [];
    return ORDRE.map(function (cle) {
      var it = items.filter(function (i) { return i.cle === cle; })[0] || { cle: cle, fait: false };
      return { cle: cle, titre: TACHES[cle].titre, aide: TACHES[cle].aide, fait: it.fait === true, detail: detail(it, etat) };
    });
  }

  function detail(it, etat) {
    if (it.cle === 'ma_pharmacie') {
      var m = [];
      if (it.horaires === false) m.push('horaires à renseigner');
      if (it.gps_present === false) m.push('position non enregistrée (contactez l\'équipe)');
      else if (it.gps_confirme === false) m.push('position à confirmer');
      return m.join(' · ');
    }
    if (it.cle === 'telegram') return it.telegram_actif ? 'Telegram actif' : it.sans_telegram ? 'Sans Telegram : SMS et Espace Pro seulement (réactivité moindre)' : '';
    if (it.cle === 'import') return it.nb_stocks ? it.nb_stocks + ' médicament(s) enregistré(s)' : '';
    if (it.cle === 'seuil') {
      var jours = etat && etat.fraicheur_jours;
      return (it.items_frais || 0) + ' / ' + (it.min_items_frais || 0) + ' médicaments confirmés' + (jours ? ' depuis moins de ' + jours + ' jours' : '');
    }
    return '';
  }

  /** Part de tâches faites (0–100). */
  function progression(etat) {
    var t = tachesAffichables(etat);
    return Math.round(100 * t.filter(function (x) { return x.fait; }).length / t.length);
  }
  /** Première tâche non faite, ou null. */
  function prochaineTache(etat) {
    var t = tachesAffichables(etat).filter(function (x) { return !x.fait; });
    return t.length ? t[0] : null;
  }
  /** La checklist reste affichée tant que la pharmacie n'est pas publiée. */
  function checklistVisible(etat) { return !!etat && etat.est_publiee !== true; }
  /** Pourquoi la pharmacie n'est pas (encore) publiée alors que tout est fait : seule une pharmacie vérifiée est publiée. */
  function messagePublication(etat) {
    if (!etat) return '';
    if (etat.est_publiee) return 'Votre pharmacie est publiée : elle est visible des patients et éligible aux demandes.';
    if (etat.faits === etat.total && etat.statut !== 'verifie') return 'Checklist complète. Votre pharmacie sera publiée dès que l\'équipe N\'Gola Pharma l\'aura vérifiée.';
    return '';
  }

  /** Code couleur de la colonne « Dernière MAJ » : vert ≤ 3 j, orange ≤ 7 j, rouge au-delà (SPEC 1 §5.2). */
  function couleurFraicheur(confirmeLe, maintenant) {
    if (!confirmeLe) return 'rouge';
    var jours = ((maintenant || Date.now()) - new Date(confirmeLe).getTime()) / 86400000;
    return jours <= 3 ? 'vert' : jours <= 7 ? 'orange' : 'rouge';
  }
  var COULEURS = { vert: '#1b7a3d', orange: '#b26a00', rouge: '#b42318' };
  function couleurCss(cle) { return COULEURS[cle] || COULEURS.rouge; }

  /** Mot de passe : 10 caractères au moins, confirmation identique. Renvoie un message d'erreur ou null. */
  function erreurMotDePasse(mdp, confirmation) {
    if (typeof mdp !== 'string' || mdp.length < 10) return 'Le mot de passe doit contenir au moins 10 caractères.';
    if (mdp !== confirmation) return 'Les deux mots de passe ne sont pas identiques.';
    return null;
  }

  // Étape -> onglet de l'Espace Pro (liens des rappels : /pro.html?etape=telegram)
  var ONGLETS = { mot_de_passe: 'stocks', ma_pharmacie: 'pharmacy', telegram: 'alerts', import: 'import', confirmation: 'stocks', seuil: 'stocks' };
  function ongletPourEtape(cle) { return Object.prototype.hasOwnProperty.call(ONGLETS, cle) ? ONGLETS[cle] : null; }
  /** Étape demandée par l'URL (?etape=...), seulement si elle est connue ; sinon null. */
  function etapeDeLUrl(recherche) {
    var m = /[?&]etape=([a-z_]+)(?:&|$)/.exec(recherche || '');
    return m && ongletPourEtape(m[1]) ? m[1] : null;
  }
  /** Libellé d'une étape bloquante, y compris « activation » (compte pas encore activé). */
  function libelleEtape(cle) { return cle === 'activation' ? 'Activation du compte' : (TACHES[cle] ? TACHES[cle].titre : cle); }

  return { ongletPourEtape: ongletPourEtape, etapeDeLUrl: etapeDeLUrl, libelleEtape: libelleEtape, TACHES: TACHES, ORDRE: ORDRE, tachesAffichables: tachesAffichables, progression: progression, prochaineTache: prochaineTache,
    checklistVisible: checklistVisible, messagePublication: messagePublication, couleurFraicheur: couleurFraicheur, couleurCss: couleurCss,
    erreurMotDePasse: erreurMotDePasse };
}));
