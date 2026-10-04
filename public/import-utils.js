/**
 * Import guidé des stocks (SPEC 1 §5.1), partie navigateur : lecture tolérante d'un fichier CSV/Excel, détection des colonnes,
 * prix et booléens à la française, découpage en paquets, libellés de l'aperçu. Sans réseau ni DOM, testé avec Jest
 * (tests/import-utils.test.js). Chargé dans le navigateur sous `window.ImportUtils`.
 * Le serveur REVALIDE tout (prix, nom, rapprochement) : ce fichier ne sert qu'à lire et à présenter, jamais à décider.
 * Aucune ordonnance n'est lue ni envoyée (CLAUDE.md règle 5).
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ImportUtils = factory();
}(typeof self !== 'undefined' ? self : this, function () {
  var MAX_LIGNES = 5000;
  var MAX_OCTETS = 5 * 1024 * 1024;
  var TAILLE_PAQUET = 200;

  var SYNONYMES = {
    nom: ['nom', 'name', 'medicament', 'produit', 'designation', 'libelle', 'article', 'nomcommercial'],
    dosage: ['dosage', 'dose', 'concentration', 'strength', 'dosageforce'],
    conditionnement: ['conditionnement', 'pack', 'packsize', 'boite', 'presentation', 'colisage'],
    prix: ['prix', 'price', 'prixfcfa', 'prixxaf', 'tarif', 'montant', 'prixunitaire', 'pv', 'pu', 'prixdevente', 'cout'],
    en_stock: ['enstock', 'stock', 'disponible', 'dispo', 'available', 'disponibilite']
  };
  var OBLIGATOIRES = ['nom', 'prix'];

  /** Octets d'un fichier -> texte : UTF-8 si valide, sinon Windows-1252 (Excel français). Le BOM est retiré. */
  function decoderOctets(octets) {
    var u8 = octets instanceof Uint8Array ? octets : new Uint8Array(octets);
    var texte;
    try { texte = new TextDecoder('utf-8', { fatal: true }).decode(u8); }
    catch (e) { texte = new TextDecoder('windows-1252').decode(u8); }
    return texte.charCodeAt(0) === 0xFEFF ? texte.slice(1) : texte;
  }

  /** Séparateur le plus plausible parmi « ; », « , » et tabulation (hors guillemets), d'après les premières lignes. */
  function detecterSeparateur(texte) {
    var candidats = [';', ',', '\t'];
    var lignes = [], cour = '', guillemets = false;
    for (var i = 0; i < texte.length && lignes.length < 6; i++) {
      var c = texte.charAt(i);
      if (c === '"') guillemets = !guillemets;
      if ((c === '\n' || c === '\r') && !guillemets) { if (cour.trim()) lignes.push(cour); cour = ''; }
      else cour += c;
    }
    if (cour.trim() && lignes.length < 6) lignes.push(cour);
    var meilleur = ';', meilleurScore = -1;
    candidats.forEach(function (sep) {
      var comptes = lignes.map(function (l) {
        var n = 0, q = false;
        for (var k = 0; k < l.length; k++) { var ch = l.charAt(k); if (ch === '"') q = !q; else if (ch === sep && !q) n++; }
        return n;
      });
      if (!comptes.length) return;
      var min = Math.min.apply(null, comptes), egaux = comptes.every(function (n) { return n === comptes[0]; });
      var score = egaux && comptes[0] > 0 ? 1000 + comptes[0] : min;
      if (score > meilleurScore) { meilleur = sep; meilleurScore = score; }
    });
    return meilleur;
  }

  /** CSV -> tableau de lignes (tableaux de cellules). Guillemets, guillemets doublés, retours à la ligne dans une cellule. */
  function parserCsv(texte, sep) {
    sep = sep || detecterSeparateur(texte);
    var lignes = [], ligne = [], cell = '', q = false, i = 0, n = texte.length;
    while (i < n) {
      var c = texte.charAt(i);
      if (q) {
        if (c === '"') { if (texte.charAt(i + 1) === '"') { cell += '"'; i += 2; continue; } q = false; i++; continue; }
        cell += c; i++; continue;
      }
      if (c === '"' && cell === '') { q = true; i++; continue; }
      if (c === sep) { ligne.push(cell); cell = ''; i++; continue; }
      if (c === '\r' || c === '\n') {
        if (c === '\r' && texte.charAt(i + 1) === '\n') i++;
        ligne.push(cell); lignes.push(ligne); ligne = []; cell = ''; i++; continue;
      }
      cell += c; i++;
    }
    if (cell !== '' || ligne.length) { ligne.push(cell); lignes.push(ligne); }
    return lignes;
  }

  function normaliserEntete(h) {
    return String(h == null ? '' : h).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]/g, '');
  }

  /** { indices: { nom, dosage, ... }, manquantes: [champs obligatoires absents] } d'après la ligne d'en-têtes. */
  function detecterColonnes(entetes) {
    var normes = (entetes || []).map(normaliserEntete), indices = {};
    Object.keys(SYNONYMES).forEach(function (champ) {
      for (var s = 0; s < SYNONYMES[champ].length; s++) {
        var k = normes.indexOf(SYNONYMES[champ][s]);
        if (k >= 0 && !Object.keys(indices).some(function (c) { return indices[c] === k; })) { indices[champ] = k; return; }
      }
    });
    return { indices: indices, manquantes: OBLIGATOIRES.filter(function (c) { return indices[c] === undefined; }) };
  }

  /** « 5 400 », « 5400 FCFA », « 5.400 », « 1 250,50 F CFA », nombre Excel -> entier de FCFA, ou null. */
  function parserPrix(brut) {
    if (typeof brut === 'number') return isFinite(brut) ? Math.round(brut) : null;
    var t = String(brut == null ? '' : brut).toLowerCase().replace(/ /g, ' ').replace(/f\s*cfa|fcfa|xaf|cfa|francs?/g, '').replace(/\bf\b/g, '').replace(/\s+/g, ' ').trim();
    if (!t || !/\d/.test(t)) return null;
    if (/^\d{1,3}([ .,]\d{3})+$/.test(t)) return parseInt(t.replace(/[ .,]/g, ''), 10);   // séparateurs de milliers
    if (/^\d{1,3}([ .]\d{3})+[,.]\d{1,2}$/.test(t)) return Math.round(parseFloat(t.replace(/[ .](?=\d{3})/g, '').replace(',', '.')));
    if (/^\d+[.,]\d{1,2}$/.test(t)) return Math.round(parseFloat(t.replace(',', '.')));
    if (/^\d+$/.test(t.replace(/ /g, ''))) return parseInt(t.replace(/ /g, ''), 10);
    return null;
  }

  /** oui/non/yes/no/1/0/vrai/faux/true/false -> true/false ; vide -> défaut ; autre -> null (valeur illisible). */
  function parserBooleen(brut, defaut) {
    if (typeof brut === 'boolean') return brut;
    if (typeof brut === 'number') return brut === 1 ? true : brut === 0 ? false : null;
    var t = String(brut == null ? '' : brut).trim().toLowerCase();
    if (t === '') return defaut === undefined ? true : defaut;
    if (['oui', 'o', 'yes', 'y', 'true', 'vrai', '1', 'x', 'disponible', 'en stock'].indexOf(t) >= 0) return true;
    if (['non', 'n', 'no', 'false', 'faux', '0', 'rupture', 'indisponible'].indexOf(t) >= 0) return false;
    return null;
  }

  var texteCellule = function (v) { return v == null ? '' : String(v).trim(); };

  /**
   * tableau : lignes de cellules, la première étant l'en-tête. Renvoie { ok:true, lignes, colonnes, vides } ou { ok:false, erreur, ... }.
   * Chaque ligne : { numero (n° de ligne dans le fichier), nom, dosage, conditionnement, prix_brut, prix, en_stock, en_stock_invalide }.
   */
  function lignesDepuisTableau(tableau) {
    if (!tableau || tableau.length < 2) return { ok: false, erreur: 'fichier_vide' };
    var col = detecterColonnes(tableau[0]);
    if (col.manquantes.length) return { ok: false, erreur: 'colonnes_manquantes', manquantes: col.manquantes };
    var ix = col.indices, lignes = [], vides = 0;
    for (var r = 1; r < tableau.length; r++) {
      var row = tableau[r] || [];
      if (!row.some(function (c) { return texteCellule(c) !== ''; })) { vides++; continue; }
      if (lignes.length >= MAX_LIGNES) return { ok: false, erreur: 'trop_de_lignes', limite: MAX_LIGNES };
      var brutPrix = row[ix.prix], bool = ix.en_stock === undefined ? true : parserBooleen(row[ix.en_stock], true);
      lignes.push({
        numero: r + 1,
        nom: texteCellule(row[ix.nom]),
        dosage: ix.dosage === undefined ? '' : texteCellule(row[ix.dosage]),
        conditionnement: ix.conditionnement === undefined ? '' : texteCellule(row[ix.conditionnement]),
        prix_brut: texteCellule(brutPrix).slice(0, 50),
        prix: parserPrix(brutPrix),
        en_stock: bool === null ? true : bool,
        en_stock_invalide: bool === null
      });
    }
    if (!lignes.length) return { ok: false, erreur: 'fichier_vide' };
    return { ok: true, lignes: lignes, colonnes: ix, vides: vides };
  }

  /** Contrôle d'un fichier choisi { name, size } : message d'erreur ou null. */
  function erreurFichier(f) {
    if (!f) return 'Choisissez un fichier.';
    if (f.size > MAX_OCTETS) return 'Fichier trop volumineux (5 Mo au maximum).';
    if (f.size < 1) return 'Fichier vide.';
    var ext = String(f.name || '').split('.').pop().toLowerCase();
    if (['csv', 'txt', 'xlsx', 'xls'].indexOf(ext) < 0) return 'Format non supporté. Utilisez .csv, .xlsx ou .xls.';
    return null;
  }
  function typeFichier(nom) { return /\.(xlsx|xls)$/i.test(nom || '') ? 'excel' : 'csv'; }

  function decouper(lignes, taille) {
    var t = taille || TAILLE_PAQUET, p = [];
    for (var i = 0; i < lignes.length; i += t) p.push(lignes.slice(i, i + t));
    return p;
  }

  /** Modèle téléchargeable : en-tête + 3 lignes d'exemple (séparateur « ; » : s'ouvre directement dans Excel français). */
  var MODELE = [
    ['nom', 'dosage', 'conditionnement', 'prix', 'en_stock'],
    ['Paracétamol', '500mg', 'Boîte de 16', '1 500', 'oui'],
    ['Amoxicilline', '500mg', 'Boîte de 12', '2 500', 'oui'],
    ['Ibuprofène', '400mg', 'Boîte de 20', '1 800', 'non']
  ];
  function modeleCsv() {
    return '﻿' + MODELE.map(function (l) { return l.join(';'); }).join('\r\n') + '\r\n';
  }

  var ETATS = {
    reconnu: { libelle: 'Reconnu', icone: '✅', classe: 'ok' }, suggestion: { libelle: 'Suggestion', icone: '✅', classe: 'ok' },
    a_confirmer: { libelle: 'À confirmer', icone: '⚠️', classe: 'attention' }, non_reconnu: { libelle: 'Non reconnu', icone: '❓', classe: 'inconnu' },
    erreur: { libelle: 'Erreur', icone: '❌', classe: 'erreur' }
  };
  var PROBLEMES = {
    nom_absent: 'Nom du médicament absent.', prix_invalide: 'Prix absent, non numérique, nul ou supérieur à 500 000 FCFA.',
    en_stock_invalide: 'Valeur « en stock » illisible (attendu : oui/non).', ambigu: 'Plusieurs fiches possibles : choisissez la bonne.',
    doublon_fichier: 'Doublon dans le fichier : la dernière ligne de ce médicament est retenue.', prix_ecart_median: 'Prix très éloigné de celui des autres pharmacies.'
  };
  function libelleEtat(e) { return ETATS[e] || { libelle: e, icone: '', classe: '' }; }
  function libelleProbleme(p) {
    var base = PROBLEMES[p && p.code] || (p && p.code) || '';
    return p && p.code === 'prix_ecart_median' && p.detail ? base + ' (' + p.detail + ')' : base;
  }
  function erreurLecture(r) {
    if (r.erreur === 'fichier_vide') return 'Le fichier ne contient aucune ligne de médicament.';
    if (r.erreur === 'colonnes_manquantes') return 'Colonne(s) obligatoire(s) introuvable(s) : ' + r.manquantes.join(', ') + '. Téléchargez le modèle.';
    if (r.erreur === 'trop_de_lignes') return 'Trop de lignes : ' + r.limite + ' au maximum par import.';
    return 'Fichier illisible.';
  }
  /** Résumé en une phrase des compteurs renvoyés par le serveur. */
  function resume(c) {
    if (!c) return '';
    return c.total + ' ligne(s) : ' + (c.reconnu + c.suggestion) + ' reconnue(s), ' + c.a_confirmer + ' à confirmer, ' + c.non_reconnu + ' non reconnue(s), ' + c.erreur + ' en erreur.';
  }
  function peutValider(c) { return !!c && c.a_ecrire > 0; }

  return { MAX_LIGNES: MAX_LIGNES, MAX_OCTETS: MAX_OCTETS, TAILLE_PAQUET: TAILLE_PAQUET, MODELE: MODELE, decoderOctets: decoderOctets,
    detecterSeparateur: detecterSeparateur, parserCsv: parserCsv, detecterColonnes: detecterColonnes, parserPrix: parserPrix, parserBooleen: parserBooleen,
    lignesDepuisTableau: lignesDepuisTableau, erreurFichier: erreurFichier, typeFichier: typeFichier, decouper: decouper, modeleCsv: modeleCsv,
    libelleEtat: libelleEtat, libelleProbleme: libelleProbleme, erreurLecture: erreurLecture, resume: resume, peutValider: peutValider };
}));
