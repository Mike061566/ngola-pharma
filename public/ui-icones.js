/**
 * Icônes de N'Gola Pharma en SVG en ligne (remplacent les emoji : rendu identique sur tous les Android,
 * non lues par les lecteurs d'écran). Une icône accompagne TOUJOURS un texte : elle est donc décorative
 * (aria-hidden) et ne porte jamais seule une information (WCAG 1.1.1, 1.4.1).
 * Trait 1,6 px sur une grille 16 × 16, couleur héritée du texte (currentColor).
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.NgIcones = factory();
}(typeof self !== 'undefined' ? self : this, function () {
  var TRACES = {
    garde: '<circle cx="8" cy="8" r="6.5"/><path d="M8 4.8v6.4M4.8 8h6.4"/>',
    verifie: '<path d="M8 1.5l5 2v4c0 3.2-2.1 5.6-5 7-2.9-1.4-5-3.8-5-7v-4z"/><path d="M5.6 8l1.7 1.7 3.2-3.4"/>',
    dispo: '<circle cx="8" cy="8" r="6.5"/><path d="M5.2 8.2l1.9 1.9 3.7-4"/>',
    faible: '<path d="M8 2.2l6.2 11H1.8z"/><path d="M8 6.6v3.1M8 11.4v.1"/>',
    rupture: '<circle cx="8" cy="8" r="6.5"/><path d="M5.8 5.8l4.4 4.4M10.2 5.8l-4.4 4.4"/>',
    horloge: '<circle cx="8" cy="8" r="6.5"/><path d="M8 4.6V8l2.4 1.5"/>',
    telephone: '<path d="M3.6 2h2.2l1.1 2.9-1.5 1a7.4 7.4 0 0 0 3.7 3.7l1-1.5L13 9.2v2.2a1.6 1.6 0 0 1-1.7 1.6A10.4 10.4 0 0 1 2 3.7 1.6 1.6 0 0 1 3.6 2z"/>',
    epingle: '<path d="M8 14.5s4.5-4.2 4.5-8a4.5 4.5 0 0 0-9 0c0 3.8 4.5 8 4.5 8z"/><circle cx="8" cy="6.5" r="1.6"/>',
    cloche: '<path d="M4 11V7a4 4 0 0 1 8 0v4l1.2 1.4H2.8z"/><path d="M6.6 14.2h2.8"/>',
    pharmacie: '<path d="M2.5 14V5.6L8 2l5.5 3.6V14z"/><path d="M8 7v4.2M5.9 9.1h4.2"/>',
    pilule: '<path d="M5.3 13.2a2.9 2.9 0 0 1-4.1-4.1l7.6-7.6a2.9 2.9 0 0 1 4.1 4.1z"/><path d="M5 5.2l4.4 4.4"/>',
    ordonnance: '<path d="M4 1.5h5.4l2.6 2.8v10.2H4z"/><path d="M9.4 1.5v2.8H12M6 8h4M6 10.5h4"/>',
    info: '<circle cx="8" cy="8" r="6.5"/><path d="M8 7.3v3.9M8 4.8v.1"/>',
    email: '<path d="M2 3.5h12v9H2z"/><path d="M2.3 4l5.7 4.6L13.7 4"/>',
    mobile: '<path d="M5 1.5h6v13H5z"/><path d="M7.3 12.4h1.4"/>'
  };

  /** SVG décoratif prêt à insérer en HTML. Nom inconnu : chaîne vide (jamais d'erreur dans le rendu). */
  function icone(nom, classe) {
    var t = TRACES[nom];
    if (!t) return '';
    return '<svg class="ng-icone' + (classe ? ' ' + classe : '') + '" viewBox="0 0 16 16" width="16" height="16" fill="none" ' +
      'stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">' + t + '</svg>';
  }

  return { icone: icone, NOMS: Object.keys(TRACES) };
}));
