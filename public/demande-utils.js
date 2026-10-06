/**
 * Fonctions pures des pages d'onboarding (devenir-partenaire.html, activer.html, complements.html) : horaires, validation du
 * formulaire, contrôle des fichiers, messages d'erreur, lecture du jeton dans le fragment d'URL. Sans réseau ni DOM, testées avec Jest
 * (tests/demande-utils.test.js). Chargées dans le navigateur sous `window.DemandeUtils`.
 * Aucune ordonnance n'est demandée ni envoyée (CLAUDE.md règle 5). Le serveur revalide tout : ces contrôles ne sont qu'une aide.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.DemandeUtils = factory();
}(typeof self !== 'undefined' ? self : this, function () {
  var JOURS = [['lun', 'Lundi'], ['mar', 'Mardi'], ['mer', 'Mercredi'], ['jeu', 'Jeudi'], ['ven', 'Vendredi'], ['sam', 'Samedi'], ['dim', 'Dimanche']];
  var TAILLE_MAX = 5 * 1024 * 1024;
  var TYPES = ['application/pdf', 'image/jpeg', 'image/png'];
  var MESSAGES = {
    champ_inconnu: 'Champ non autorisé.', ordonnance_interdite: 'Aucune ordonnance ne doit être envoyée.',
    nom_invalide: 'Indiquez le nom de l\'officine.', quartier_invalide: 'Choisissez un quartier.', adresse_invalide: 'Indiquez l\'adresse de l\'officine.',
    telephone_fixe_invalide: 'Numéro fixe de l\'officine invalide (ex. 222 23 45 67).',
    telephone_mobile_invalide: 'Numéro mobile invalide (ex. 6XX XX XX XX ou +237 6XX XX XX XX).',
    titulaire_invalide: 'Indiquez le nom complet du pharmacien titulaire.', ordre_invalide: 'Indiquez le numéro d\'inscription à l\'Ordre.',
    email_invalide: 'Adresse email invalide.', position_invalide: 'Position invalide.',
    horaires_invalides: 'Horaires invalides : au moins un jour ouvert, ouverture avant fermeture.',
    consentement_requis: 'Les deux consentements sont nécessaires.', captcha_invalide: 'Vérification anti-robot échouée. Réessayez.',
    captcha_indisponible: 'Vérification anti-robot indisponible. Réessayez dans un instant.', captcha_non_configure: 'Service temporairement indisponible.',
    document_manquant: 'Joignez l\'attestation d\'inscription à l\'Ordre et l\'autorisation d\'exploitation.',
    document_invalide: 'Document refusé : PDF, JPG ou PNG, 5 Mo au maximum.', limite_quotidienne: 'Trop de demandes aujourd\'hui depuis cette connexion. Réessayez demain.',
    lien_invalide: 'Ce lien n\'est plus valide. Demandez un nouveau lien à l\'équipe N\'Gola Pharma.', compte_conflit: 'Cette adresse email est déjà utilisée pour un autre compte. Contactez l\'équipe N\'Gola Pharma.',
    reponse_vide: 'Écrivez un message ou joignez un document.', corps_trop_grand: 'Fichiers trop volumineux (5 Mo par fichier).'
  };
  function messageErreur(code) { return MESSAGES[code] || 'Une erreur est survenue. Réessayez.'; }

  /** Téléphone camerounais -> +237XXXXXXXXX, ou null (même règle que le serveur). */
  function normaliserTelephone(brut) {
    if (typeof brut !== 'string') return null;
    var t = brut.replace(/[\s.\-()]/g, '');
    if (t.indexOf('+237') === 0) t = t.slice(4);
    else if (t.indexOf('00237') === 0) t = t.slice(5);
    else if (t.indexOf('237') === 0 && t.length === 12) t = t.slice(3);
    return /^[2368]\d{8}$/.test(t) ? '+237' + t : null;
  }

  /** Grille { lun: { ferme, ouv, fer } } -> objet d'horaires du serveur (jours fermés omis). */
  function construireHoraires(grille) {
    var h = {};
    JOURS.forEach(function (j) {
      var d = grille && grille[j[0]];
      if (d && !d.ferme && d.ouv && d.fer) h[j[0]] = { ouv: d.ouv, fer: d.fer };
    });
    return h;
  }
  /** Préréglage : Lun–Sam 08:00–20:00, dimanche fermé. */
  function horairesParDefaut() {
    var g = {};
    JOURS.forEach(function (j) { g[j[0]] = j[0] === 'dim' ? { ferme: true, ouv: '08:00', fer: '20:00' } : { ferme: false, ouv: '08:00', fer: '20:00' }; });
    return g;
  }

  /** Validation de confort côté navigateur. Renvoie { ok, erreurs: { champ: message } }. */
  function validerFormulaire(v) {
    var e = {};
    var txt = function (s, min) { return typeof s === 'string' && s.trim().length >= min; };
    if (!txt(v.nom_pharmacie, 2)) e.nom_pharmacie = MESSAGES.nom_invalide;
    if (!v.quartier_id) e.quartier_id = MESSAGES.quartier_invalide;
    if (!txt(v.adresse, 3)) e.adresse = MESSAGES.adresse_invalide;
    if (!normaliserTelephone(v.telephone_fixe)) e.telephone_fixe = MESSAGES.telephone_fixe_invalide;
    var mobile = normaliserTelephone(v.telephone_mobile);
    if (!mobile || mobile.indexOf('+2376') !== 0) e.telephone_mobile = MESSAGES.telephone_mobile_invalide;
    if (!txt(v.nom_titulaire, 2)) e.nom_titulaire = MESSAGES.titulaire_invalide;
    if (!txt(v.numero_ordre, 2)) e.numero_ordre = MESSAGES.ordre_invalide;
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test((v.email_titulaire || '').trim())) e.email_titulaire = MESSAGES.email_invalide;
    var h = construireHoraires(v.grille);
    var ok = Object.keys(h).length > 0 && Object.keys(h).every(function (k) { return h[k].ouv < h[k].fer; });
    if (!ok) e.horaires = MESSAGES.horaires_invalides;
    if (!v.consentement_conditions || !v.consentement_messages) e.consentements = MESSAGES.consentement_requis;
    return { ok: Object.keys(e).length === 0, erreurs: e };
  }

  /** Contrôle d'un fichier choisi : { name, size, type }. Renvoie un message d'erreur ou null. */
  function erreurFichier(f) {
    if (!f) return null;
    if (f.size > TAILLE_MAX) return 'Fichier trop volumineux (5 Mo au maximum).';
    if (f.size < 1) return 'Fichier vide.';
    if (TYPES.indexOf(f.type) === -1) return 'Format refusé : PDF, JPG ou PNG.';
    return null;
  }

  /** Corps JSON (champ « donnees ») envoyé à creer-demande. */
  function construireDonnees(v, captcha) {
    var d = {
      nom_pharmacie: v.nom_pharmacie.trim(), quartier_id: v.quartier_id, adresse: v.adresse.trim(), telephone_fixe: v.telephone_fixe.trim(),
      nom_titulaire: v.nom_titulaire.trim(), numero_ordre: v.numero_ordre.trim(), email_titulaire: v.email_titulaire.trim(),
      telephone_mobile: v.telephone_mobile.trim(), horaires: construireHoraires(v.grille), participe_garde: v.participe_garde === true,
      consentement_conditions: true, consentement_messages: true, captcha: captcha
    };
    if (typeof v.latitude === 'number' && typeof v.longitude === 'number') { d.latitude = v.latitude; d.longitude = v.longitude; }
    return d;
  }

  /** Jeton d'un lien (#t=...) ; null si absent ou mal formé. Le jeton ne passe jamais par la requête serveur ni le Referer. */
  function jetonDuFragment(hash) {
    var m = /^#?t=([A-Za-z0-9_-]{16,128})$/.exec(hash || '');
    return m ? m[1] : null;
  }

  return { JOURS: JOURS, TAILLE_MAX: TAILLE_MAX, messageErreur: messageErreur, normaliserTelephone: normaliserTelephone,
    construireHoraires: construireHoraires, horairesParDefaut: horairesParDefaut, validerFormulaire: validerFormulaire,
    erreurFichier: erreurFichier, construireDonnees: construireDonnees, jetonDuFragment: jetonDuFragment };
}));
