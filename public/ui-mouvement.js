/**
 * Micro-interactions de N'Gola Pharma, sans dépendance (décision du propriétaire : pas de bibliothèque Motion).
 * - Seules transform et opacity sont animées (règles CSS dans ui-tokens.css et index.html), 300 ms au plus.
 * - Tout est coupé si l'appareil demande moins d'animations : chaque fonction le vérifie d'abord.
 * - Le contenu reste visible si ce script échoue : un élément n'est masqué que s'il va être révélé.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.NgMouvement = factory();
}(typeof self !== 'undefined' ? self : this, function () {
  var DUREE_SORTIE = 140;      // ms : la sortie est plus courte que l'entrée (200 ms)
  var DUREE_TOAST = 4000;      // ms : le message reste aussi dans la page, le toast n'est qu'un rappel
  var TOASTS_MAX = 2;
  var SELECTEUR_FOCUS = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), ' +
    'textarea:not([disabled]), iframe, [tabindex]:not([tabindex="-1"])';

  /** Vrai si l'appareil demande moins d'animations (ou si on ne peut pas le savoir sans erreur : faux). */
  function reduit(win) {
    try { return !!(win && win.matchMedia && win.matchMedia('(prefers-reduced-motion: reduce)').matches); } catch (e) { return false; }
  }

  /**
   * Révèle une seule fois, au défilement, les éléments situés sous l'écran. Ceux déjà visibles ne bougent pas
   * (aucun clignotement au chargement). Sans IntersectionObserver ou en mouvement réduit : rien n'est masqué.
   * Renvoie le nombre d'éléments mis en attente de révélation.
   */
  function reveler(elements, win) {
    var liste = [].slice.call(elements || []);
    if (!liste.length || !win || !win.IntersectionObserver || reduit(win)) return 0;
    var hauteur = win.innerHeight || 0;
    var obs = new win.IntersectionObserver(function (entrees) {
      entrees.forEach(function (e) {
        if (!e.isIntersecting) return;
        e.target.classList.remove('ng-a-reveler');
        obs.unobserve(e.target);
      });
    }, { rootMargin: '0px 0px -10% 0px' });
    var n = 0;
    liste.forEach(function (el) {
      if (el.getBoundingClientRect().top < hauteur) return;
      el.classList.add('ng-a-reveler');   // masqué d'abord, sans transition (l'élément est hors de l'écran)
      void el.offsetWidth;
      el.classList.add('ng-revelable');
      obs.observe(el);
      n++;
    });
    return n;
  }

  /** Ferme un élément avec une courte sortie (classe ng-sortie), puis appelle fin(). Immédiat en mouvement réduit. */
  function fermerAvecSortie(el, win, fin) {
    if (!el || reduit(win) || !win || !win.setTimeout) { fin(); return; }
    el.classList.add('ng-sortie');
    win.setTimeout(function () { el.classList.remove('ng-sortie'); fin(); }, DUREE_SORTIE);
  }

  /** Éléments atteignables au clavier dans un conteneur, dans l'ordre du document. */
  function focusables(conteneur) {
    return [].slice.call(conteneur.querySelectorAll(SELECTEUR_FOCUS)).filter(function (el) {
      return !el.hasAttribute('hidden') && el.getAttribute('aria-hidden') !== 'true';
    });
  }

  /** Garde le focus clavier dans le conteneur (fenêtre modale) : Tab et Maj+Tab bouclent. */
  function pieger(conteneur, evt, doc) {
    if (evt.key !== 'Tab') return false;
    var liste = focusables(conteneur);
    if (!liste.length) { evt.preventDefault(); return true; }
    var premier = liste[0], dernier = liste[liste.length - 1], actif = doc.activeElement;
    if (evt.shiftKey && (actif === premier || !conteneur.contains(actif))) { evt.preventDefault(); dernier.focus(); return true; }
    if (!evt.shiftKey && (actif === dernier || !conteneur.contains(actif))) { evt.preventDefault(); premier.focus(); return true; }
    return false;
  }

  /** Zone des messages de confirmation, créée vide au chargement pour que les lecteurs d'écran l'annoncent ensuite. */
  function preparerToasts(doc) {
    var zone = doc.getElementById('ng-toasts');
    if (zone) return zone;
    zone = doc.createElement('div');
    zone.id = 'ng-toasts';
    zone.className = 'ng-toasts';
    zone.setAttribute('role', 'status');
    zone.setAttribute('aria-live', 'polite');
    doc.body.appendChild(zone);
    return zone;
  }

  /** Affiche un message de confirmation (4 s, fermable), au plus deux à la fois. */
  function toast(doc, message, opts) {
    opts = opts || {};
    var zone = preparerToasts(doc);
    while (zone.children.length >= TOASTS_MAX) zone.removeChild(zone.firstChild);
    var t = doc.createElement('div');
    t.className = 'ng-toast';
    var icone = doc.createElement('span');
    icone.className = 'ng-toast-icone';
    icone.setAttribute('aria-hidden', 'true');
    icone.innerHTML = '<svg viewBox="0 0 16 16" width="16" height="16"><path d="M3 8.5l3 3 7-7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    var texte = doc.createElement('span');
    texte.className = 'ng-toast-texte';
    texte.textContent = message;
    var fermer = doc.createElement('button');
    fermer.type = 'button';
    fermer.className = 'ng-toast-fermer';
    fermer.setAttribute('aria-label', opts.libelleFermer || 'Fermer');
    fermer.textContent = '×';
    t.appendChild(icone); t.appendChild(texte); t.appendChild(fermer);
    zone.appendChild(t);
    var minuteur = setTimeout(retirer, opts.duree || DUREE_TOAST);
    function retirer() { clearTimeout(minuteur); if (t.parentNode) t.parentNode.removeChild(t); }
    fermer.addEventListener('click', retirer);
    return t;
  }

  if (typeof window !== 'undefined' && window.document) {
    var demarrer = function () {
      preparerToasts(window.document);
      reveler(window.document.querySelectorAll('[data-ng-reveler]'), window);
    };
    if (window.document.readyState === 'loading') window.document.addEventListener('DOMContentLoaded', demarrer);
    else demarrer();
  }

  return { reduit: reduit, reveler: reveler, fermerAvecSortie: fermerAvecSortie, focusables: focusables, pieger: pieger,
    preparerToasts: preparerToasts, toast: toast, DUREE_SORTIE: DUREE_SORTIE };
}));
