/**
 * Création en masse de pharmacies (SPEC 1 §4), partie navigateur : lecture du CSV de l'admin, détection des colonnes, téléphones au format
 * +237, coordonnées, découpage en paquets, libellés de l'aperçu. Sans réseau ni DOM, testé avec Jest (tests/pharmacies-masse-utils.test.js).
 * Chargé sous `window.PharmaciesMasseUtils` (après import-utils.js, dont il réutilise la lecture CSV/encodage). Le serveur REVALIDE tout.
 * Colonnes : nom, quartier, adresse, telephone, latitude, longitude, titulaire, numero_ordre, email, telephone_mobile.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./import-utils'));
  else root.PharmaciesMasseUtils = factory(root.ImportUtils);
}(typeof self !== 'undefined' ? self : this, function (IU) {
  var MAX_LIGNES = 1000;
  var TAILLE_PAQUET = 200;
  var SYNONYMES = {
    nom: ['nom', 'name', 'pharmacie', 'officine', 'nompharmacie', 'denomination'],
    quartier: ['quartier', 'district', 'zone', 'localite', 'neighborhood'],
    adresse: ['adresse', 'address', 'localisation', 'rue'],
    telephone: ['telephone', 'tel', 'phone', 'telephonefixe', 'fixe', 'telofficine'],
    latitude: ['latitude', 'lat'],
    longitude: ['longitude', 'lng', 'lon', 'long'],
    titulaire: ['titulaire', 'pharmacien', 'pharmacientitulaire', 'responsable', 'nomtitulaire'],
    numero_ordre: ['numeroordre', 'nordre', 'ordre', 'numordre', 'noordre', 'numerodordre', 'inscriptionordre'],
    email: ['email', 'mail', 'courriel', 'emailtitulaire'],
    telephone_mobile: ['telephonemobile', 'mobile', 'portable', 'gsm', 'telmobile']
  };
  var OBLIGATOIRES = ['nom', 'quartier'];
  var ENTETE = ['nom', 'quartier', 'adresse', 'telephone', 'latitude', 'longitude', 'titulaire', 'numero_ordre', 'email', 'telephone_mobile'];

  function norm(h) { return String(h == null ? '' : h).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]/g, ''); }
  function cellule(v) { return v == null ? '' : String(v).trim(); }

  function detecterColonnes(entetes) {
    var normes = (entetes || []).map(norm), indices = {};
    Object.keys(SYNONYMES).forEach(function (champ) {
      for (var s = 0; s < SYNONYMES[champ].length; s++) {
        var k = normes.indexOf(SYNONYMES[champ][s]);
        if (k >= 0 && !Object.keys(indices).some(function (c) { return indices[c] === k; })) { indices[champ] = k; return; }
      }
    });
    return { indices: indices, manquantes: OBLIGATOIRES.filter(function (c) { return indices[c] === undefined; }) };
  }

  /** Numéro camerounais -> +237XXXXXXXXX, ou '' si illisible (le serveur écarte alors la valeur avec un avertissement). */
  function normaliserTelephone(brut) {
    var t = cellule(brut).replace(/[\s.\-()]/g, '');
    if (!t) return '';
    if (t.indexOf('+237') === 0) t = t.slice(4); else if (t.indexOf('00237') === 0) t = t.slice(5); else if (t.indexOf('237') === 0 && t.length === 12) t = t.slice(3);
    return /^[2368]\d{8}$/.test(t) ? '+237' + t : cellule(brut);   // illisible : renvoyé tel quel pour que le serveur le signale
  }

  /** « 3,8667 » ou « 3.8667 » -> nombre ; vide -> null ; illisible -> NaN. */
  function nombre(brut) {
    var t = cellule(brut).replace(',', '.');
    if (t === '') return null;
    return /^-?\d+(\.\d+)?$/.test(t) ? Number(t) : NaN;
  }

  /** tableau : lignes de cellules, la première étant l'en-tête. -> { ok, lignes, vides } ou { ok:false, erreur, manquantes? }. */
  function lignesDepuisTableau(tableau) {
    if (!tableau || tableau.length < 2) return { ok: false, erreur: 'fichier_vide' };
    var col = detecterColonnes(tableau[0]);
    if (col.manquantes.length) return { ok: false, erreur: 'colonnes_manquantes', manquantes: col.manquantes };
    var ix = col.indices, lignes = [], vides = 0;
    for (var r = 1; r < tableau.length; r++) {
      var row = tableau[r] || [];
      if (!row.some(function (c) { return cellule(c) !== ''; })) { vides++; continue; }
      if (lignes.length >= MAX_LIGNES) return { ok: false, erreur: 'trop_de_lignes', limite: MAX_LIGNES };
      var get = function (c) { return ix[c] === undefined ? '' : cellule(row[ix[c]]); };
      var lat = nombre(get('latitude')), lng = nombre(get('longitude'));
      var illisible = (lat !== null && isNaN(lat)) || (lng !== null && isNaN(lng));
      lignes.push({ numero: r + 1, nom: get('nom'), quartier: get('quartier'), adresse: get('adresse'), telephone: normaliserTelephone(get('telephone')),
        latitude: illisible ? null : lat, longitude: illisible ? null : lng, gps_invalide: illisible,
        titulaire: get('titulaire'), numero_ordre: get('numero_ordre'), email: get('email'), telephone_mobile: normaliserTelephone(get('telephone_mobile')) });
    }
    if (!lignes.length) return { ok: false, erreur: 'fichier_vide' };
    return { ok: true, lignes: lignes, vides: vides };
  }

  function lireTexteCsv(texte) { return lignesDepuisTableau(IU.parserCsv(texte)); }

  function modeleCsv() {
    var lignes = [ENTETE, ['Pharmacie Exemple', 'Bastos', 'Rue 1.234, Bastos', '222 23 45 67', '3.8870', '11.5120', 'Dr Prénom Nom', 'ORD-0000', 'titulaire@exemple.test', '6 99 12 34 56']];
    return '﻿' + lignes.map(function (l) { return l.join(';'); }).join('\r\n') + '\r\n';
  }

  var ETATS = { pret: { libelle: 'Prête', icone: '✅' }, doublon: { libelle: 'Doublon', icone: '⚠️' }, erreur: { libelle: 'Erreur', icone: '❌' } };
  var PROBLEMES = {
    nom_absent: 'Nom de la pharmacie absent.', quartier_absent: 'Quartier absent.', quartier_inconnu: 'Quartier inconnu de la liste.',
    gps_invalide: 'Position invalide (latitude et longitude ensemble, dans les limites du Cameroun).',
    telephone_invalide: 'Téléphone fixe illisible : écarté.', telephone_mobile_invalide: 'Téléphone mobile illisible : écarté.', email_invalide: 'Email illisible : écarté.',
    doublon: 'Doublon probable avec une pharmacie ou une demande existante.', doublon_fichier: 'Doublon d\'une ligne plus haut dans le fichier.'
  };
  var RAISONS = { telephone: 'même téléphone', numero_ordre: 'même numéro d\'Ordre', nom_quartier: 'même nom dans le même quartier', gps_30m: 'à moins de 30 m d\'une pharmacie existante' };
  function libelleEtat(e) { return ETATS[e] || { libelle: e, icone: '' }; }
  function libelleProbleme(p) {
    var base = PROBLEMES[p && p.code] || (p && p.code) || '';
    if (p && p.code === 'doublon' && Array.isArray(p.detail)) return base + ' (' + p.detail.map(function (r) { return RAISONS[r] || r; }).join(', ') + ')';
    if (p && p.code === 'quartier_inconnu' && p.detail) return base + ' « ' + p.detail + ' »';
    return base;
  }
  function erreurLecture(r) {
    if (r.erreur === 'fichier_vide') return 'Le fichier ne contient aucune ligne de pharmacie.';
    if (r.erreur === 'colonnes_manquantes') return 'Colonne(s) obligatoire(s) introuvable(s) : ' + r.manquantes.join(', ') + '. Téléchargez le modèle.';
    if (r.erreur === 'trop_de_lignes') return 'Trop de lignes : ' + r.limite + ' au maximum par fichier.';
    return 'Fichier illisible.';
  }
  function resume(c) { return c ? c.total + ' ligne(s) : ' + c.pret + ' prête(s), ' + c.doublon + ' doublon(s) probable(s), ' + c.erreur + ' en erreur. À créer : ' + c.a_creer + '.' : ''; }
  var peutValider = function (c) { return !!c && c.a_creer > 0; };

  /** Cases de la checklist de vérification (mêmes que pour une demande). */
  var CASES = [['ordre_ok', 'Numéro d\'Ordre cohérent avec le nom du titulaire'], ['autorisation_ok', 'Autorisation d\'exploitation vue et valide'],
    ['rappel_tel_ok', 'Rappel téléphonique au numéro fixe de l\'officine (le numéro répond et confirme le nom)'], ['adresse_gps_ok', 'Adresse et GPS cohérents sur la carte'],
    ['pas_doublon', 'Aucun doublon avec une pharmacie existante']];
  function etatCases(cochees) { var s = {}; (cochees || []).forEach(function (c) { s[c.element || c] = true; }); return CASES.map(function (c) { return { element: c[0], libelle: c[1], coche: !!s[c[0]] }; }); }
  function peutVerifier(cochees) { return etatCases(cochees).every(function (c) { return c.coche; }); }

  return { MAX_LIGNES: MAX_LIGNES, TAILLE_PAQUET: TAILLE_PAQUET, ENTETE: ENTETE, detecterColonnes: detecterColonnes, normaliserTelephone: normaliserTelephone, nombre: nombre,
    lignesDepuisTableau: lignesDepuisTableau, lireTexteCsv: lireTexteCsv, modeleCsv: modeleCsv, libelleEtat: libelleEtat, libelleProbleme: libelleProbleme,
    erreurLecture: erreurLecture, resume: resume, peutValider: peutValider, CASES: CASES, etatCases: etatCases, peutVerifier: peutVerifier };
}));
