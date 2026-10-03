/**
 * Bannière « MODE DÉMO — données fictives » (SPEC 2 §4.0bis) sur le site public, l'Espace Pro et la console admin.
 * Le mode est lu via la fonction publique `mode_public` (aucun secret). En cas d'échec de lecture, rien n'est affiché
 * (on n'affirme jamais un mode qu'on ne connaît pas). Aucune promesse de disponibilité réelle n'est faite en démo.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.DemoBanner = factory();
}(typeof self !== 'undefined' ? self : this, function () {
  var TEXTE = 'MODE DÉMO — données fictives. Aucune disponibilité réelle n\'est garantie.';

  /** Le bandeau s'affiche uniquement en mode « demo ». */
  function bandeauNecessaire(mode) { return mode === 'demo'; }

  function afficher(doc) {
    if (doc.getElementById('bandeau-demo')) return;
    var b = doc.createElement('div');
    b.id = 'bandeau-demo';
    b.setAttribute('role', 'status');
    b.textContent = TEXTE;
    b.style.cssText = 'position:sticky;top:0;z-index:2147483000;background:#b26a00;color:#fff;text-align:center;padding:6px 10px;font:600 13px/1.3 system-ui,sans-serif;letter-spacing:.2px';
    doc.body.insertBefore(b, doc.body.firstChild);
  }

  function charger(win) {
    var c = win.NGOLA_ALERTE;
    if (!c || !win.fetch) return;
    win.fetch(c.apiBase + '/rest/v1/rpc/mode_public', { method: 'POST', headers: { apikey: c.anonKey, 'content-type': 'application/json' }, body: '{}' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (mode) { if (bandeauNecessaire(mode)) afficher(win.document); })
      .catch(function () { /* mode inconnu : aucun bandeau */ });
  }

  if (typeof window !== 'undefined' && window.document) {
    if (window.document.readyState === 'loading') window.document.addEventListener('DOMContentLoaded', function () { charger(window); });
    else charger(window);
  }
  return { bandeauNecessaire: bandeauNecessaire, TEXTE: TEXTE };
}));
