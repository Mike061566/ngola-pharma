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
   * Identité d'un produit du catalogue : DCI + nom commercial + dosage + forme (minuscules, dosage sans
   * espaces) — la même clé que supabase/diagnostics/doublons_stocks.sql. Deux fiches distinctes pour le
   * même produit (ex. « Coartem » et « Artemether-Lumefantrine ») ont la même clé.
   */
  function medIdentityKey(med) {
    if (!med) return '';
    var dci = norm(med.dci), marque = norm(med.nom_commercial);
    var parts = [dci, marque, norm(med.dosage).replace(/\s+/g, ''), norm(med.forme)];
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

  return { formatHoraires: formatHoraires, statutInfo: statutInfo, medIdentityKey: medIdentityKey,
    findOwnedStock: findOwnedStock, mapLinks: mapLinks };
}));
