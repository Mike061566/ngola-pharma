/**
 * Fonctions pures de l'Espace Pro (pro.html) : affichage des horaires, libellés de statut,
 * contrôle de doublon d'un médicament, liens de carte. Sans accès réseau ni DOM, pour être testées
 * avec Jest (tests/pro-utils.test.js). Chargées dans le navigateur sous `window.ProUtils`.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ProUtils = factory();
}(typeof self !== 'undefined' ? self : this, function () {
  var JOURS = [['lun', 'Lun'], ['mar', 'Mar'], ['mer', 'Mer'], ['jeu', 'Jeu'], ['ven', 'Ven'], ['sam', 'Sam'], ['dim', 'Dim']];
  var NON_RENSEIGNES = 'Non renseignés';

  /**
   * Horaires JSON ({"lun":{"ouv":"08:00","fer":"20:00"}, ...}) -> texte lisible, jours consécutifs
   * regroupés : « Lun–Sam 08:00–20:00 · Dim Fermé ». Jamais « [object Object] ».
   */
  function formatHoraires(h) {
    if (typeof h === 'string') {
      var t = h.trim();
      if (!t || t === '{}') return NON_RENSEIGNES;
      if (t.charAt(0) !== '{') return t; // texte libre historique
      try { h = JSON.parse(t); } catch (e) { return t; }
    }
    if (!h || typeof h !== 'object' || Array.isArray(h)) return NON_RENSEIGNES;

    var parJour = JOURS.map(function (j) {
      var d = h[j[0]];
      return d && d.ouv && d.fer ? d.ouv + '–' + d.fer : 'Fermé';
    });
    if (parJour.every(function (p) { return p === 'Fermé'; })) return NON_RENSEIGNES;

    var groupes = [];
    parJour.forEach(function (p, i) {
      var dernier = groupes[groupes.length - 1];
      if (dernier && dernier.horaire === p) dernier.fin = i;
      else groupes.push({ debut: i, fin: i, horaire: p });
    });
    return groupes.map(function (g) {
      var jours = g.debut === g.fin ? JOURS[g.debut][1] : JOURS[g.debut][1] + '–' + JOURS[g.fin][1];
      return jours + ' ' + g.horaire;
    }).join(' · ');
  }

  /** Statut de pharmacie (valeur de la base) -> libellé français et classe de badge. */
  function statutInfo(statut) {
    switch (statut) {
      case 'verifie': return { label: '✓ Vérifiée', css: 'badge-verified' };
      case 'partenaire': return { label: 'Partenaire', css: 'badge-partner' };
      case 'non_verifie': return { label: 'Non vérifiée', css: 'badge-unverified' };
      case 'suspendu': return { label: 'Suspendue', css: 'badge-suspended' };
      default: return { label: statut || '—', css: 'badge-unverified' };
    }
  }

  function norm(s) { return String(s == null ? '' : s).trim().toLowerCase(); }

  /**
   * Identité d'un produit du catalogue : DCI + nom commercial + dosage + forme + conditionnement (minuscules, sans
   * espaces pour dosage et conditionnement) — la même clé que supabase/diagnostics/doublons_stocks.sql. Deux fiches distinctes pour le
   * même produit (ex. « Coartem » et « Artemether-Lumefantrine ») ont la même clé.
   */
  function medIdentityKey(med) {
    if (!med) return '';
    var dci = norm(med.dci), marque = norm(med.nom_commercial);
    var parts = [dci, marque, norm(med.dosage).replace(/\s+/g, ''), norm(med.forme), norm(med.conditionnement).replace(/\s+/g, '')];
    // Sans DCI ni marque la clé serait trop pauvre : on s'appuie alors sur le nom.
    if (!dci && !marque) parts.push(norm(med.nom));
    return parts.join('|');
  }

  /**
   * Ligne de stock de la pharmacie qui correspond déjà à ce médicament (même fiche, ou fiche
   * équivalente du catalogue), sinon null. `stocks` : lignes avec { medicament_id, medicaments: {...} }.
   */
  function findOwnedStock(stocks, med) {
    if (!med) return null;
    var cle = medIdentityKey(med);
    for (var i = 0; i < stocks.length; i++) {
      var s = stocks[i];
      if (s.medicament_id === med.id) return s;
      if (cle && s.medicaments && medIdentityKey(s.medicaments) === cle) return s;
    }
    return null;
  }

  // Number() et non parseFloat : « 3abc » ou « 3"><script> » ne doivent pas être lus comme 3.
  function coord(v) {
    if (typeof v === 'string' && v.trim() === '') return null;
    if (typeof v !== 'number' && typeof v !== 'string') return null;
    var n = Number(v);
    return isFinite(n) ? n : null;
  }

  /** Liens de carte (OpenStreetMap intégrée, Google Maps) ; null si la position est absente ou invalide. */
  function mapLinks(lat, lng) {
    var la = coord(lat), lo = coord(lng);
    if (la === null || lo === null || la < -90 || la > 90 || lo < -180 || lo > 180) return null;
    return {
      embed: 'https://www.openstreetmap.org/export/embed.html?bbox=' +
        (lo - 0.005) + ',' + (la - 0.003) + ',' + (lo + 0.005) + ',' + (la + 0.003) +
        '&layer=mapnik&marker=' + la + ',' + lo,
      google: 'https://www.google.com/maps/search/?api=1&query=' + la + ',' + lo,
    };
  }

  /**
   * Classification du catalogue (admin) : fiches dont `restreint` ou `ordonnance` diffère de l'état chargé.
   * `original` et `courant` : { [id]: { restreint: bool, ordonnance: bool } }. Aucune valeur n'est jamais déduite ici.
   */
  function classificationChanges(original, courant) {
    var out = [];
    Object.keys(courant || {}).forEach(function (id) {
      var a = (original || {})[id], b = courant[id];
      if (!a || !b) return;
      if (a.restreint !== b.restreint || a.ordonnance !== b.ordonnance) {
        out.push({ medicament_id: id, restreint: b.restreint, ordonnance: b.ordonnance });
      }
    });
    return out;
  }

  /** Éléments envoyés à valider_classification : les valeurs AFFICHÉES des fiches cochées, telles quelles. */
  function validationElements(courant, ids) {
    return (ids || []).filter(function (id) { return courant && courant[id]; }).map(function (id) {
      return { medicament_id: id, restreint: courant[id].restreint === true, ordonnance: courant[id].ordonnance === true };
    });
  }

  /**
   * Alertes de l'Espace Pro : temps moyen de réponse (en minutes) sur les lignes répondues de `vue_alertes_pharmacie`.
   * `{ moyenneMin: number|null, n }` ; les dates invalides ou négatives sont ignorées.
   */
  function tempsMoyenReponse(lignes) {
    var ds = [];
    (lignes || []).forEach(function (l) {
      if (!l || !l.reponse || !l.repondu_le || !l.envoye_le) return;
      var d = (new Date(l.repondu_le).getTime() - new Date(l.envoye_le).getTime()) / 60000;
      if (isFinite(d) && d >= 0) ds.push(d);
    });
    if (!ds.length) return { moyenneMin: null, n: 0 };
    return { moyenneMin: Math.round((ds.reduce(function (a, b) { return a + b; }, 0) / ds.length) * 10) / 10, n: ds.length };
  }

  /** Adresse d'un contact masquée à l'affichage (numéro : 2 derniers chiffres ; email : 1re lettre et domaine ; Telegram : fin du chat). */
  function masquerAdresse(canal, adresse) {
    var a = String(adresse || '');
    if (a.indexOf('en_attente:') === 0) return 'activation en cours';
    if (canal === 'sms') return a.length > 5 ? a.slice(0, 4) + ' ••• •• ' + a.slice(-2) : '••••';
    if (canal === 'email') { var i = a.indexOf('@'); return i > 1 ? a.charAt(0) + '•••' + a.slice(i) : '••••'; }
    return a.length > 3 ? '••••' + a.slice(-3) : '••••';
  }

  /** État d'un contact de messagerie, pour l'affichage : { cle, libelle }. */
  function statutContact(c) {
    if (c.bloque_le) return { cle: 'bloque', libelle: 'Bloqué par le fournisseur' };
    if (c.desabonne_le) return { cle: 'desabonne', libelle: 'Désabonné' };
    if (c.canal === 'telegram' && !c.verifie_le) return { cle: 'attente', libelle: 'En attente d\'activation' };
    return { cle: 'actif', libelle: 'Actif' };
  }

  /** Lien profond d'activation Telegram (le jeton n'est affiché qu'une fois). null si le bot ou le jeton manque. */
  function lienTelegram(bot, jeton) {
    if (!/^[A-Za-z0-9_]{3,64}$/.test(String(bot || '')) || !/^[A-Za-z0-9_-]{16,128}$/.test(String(jeton || ''))) return null;
    return 'https://t.me/' + bot + '?start=' + jeton;
  }

  return { formatHoraires: formatHoraires, statutInfo: statutInfo, medIdentityKey: medIdentityKey,
    findOwnedStock: findOwnedStock, mapLinks: mapLinks, classificationChanges: classificationChanges,
    validationElements: validationElements, tempsMoyenReponse: tempsMoyenReponse, masquerAdresse: masquerAdresse,
    statutContact: statutContact, lienTelegram: lienTelegram };
}));
