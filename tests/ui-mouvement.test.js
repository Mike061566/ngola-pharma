const M = require('../public/ui-mouvement');

function fenetre({ reduce = false, io = true, hauteur = 800 } = {}) {
  const observes = [];
  const win = {
    innerHeight: hauteur,
    matchMedia: (q) => ({ matches: reduce && q.includes('reduce') }),
    setTimeout: (f) => f(),
  };
  if (io) {
    win.IntersectionObserver = function (cb) {
      this.observe = (el) => observes.push(el);
      this.unobserve = () => {};
      win.__declencher = (el) => cb([{ isIntersecting: true, target: el }]);
    };
  }
  return { win, observes };
}

function element(top) {
  const classes = new Set();
  return {
    classes,
    classList: { add: (...c) => c.forEach((x) => classes.add(x)), remove: (c) => classes.delete(c) },
    getBoundingClientRect: () => ({ top }),
  };
}

describe('micro-interactions (sans dépendance)', () => {
  test('mouvement réduit détecté ; une erreur de matchMedia vaut « non réduit »', () => {
    expect(M.reduit(fenetre({ reduce: true }).win)).toBe(true);
    expect(M.reduit(fenetre().win)).toBe(false);
    expect(M.reduit({ matchMedia: () => { throw new Error('x'); } })).toBe(false);
    expect(M.reduit(undefined)).toBe(false);
  });

  test('révélation : seuls les éléments sous l\'écran sont masqués, puis révélés une fois', () => {
    const { win, observes } = fenetre();
    const visible = element(100), dessous = element(1200);
    expect(M.reveler([visible, dessous], win)).toBe(1);
    expect(visible.classes.size).toBe(0);
    expect(dessous.classes.has('ng-a-reveler')).toBe(true);
    expect(observes).toEqual([dessous]);
    win.__declencher(dessous);
    expect(dessous.classes.has('ng-a-reveler')).toBe(false);
  });

  test('révélation : rien n\'est masqué en mouvement réduit ou sans IntersectionObserver (contenu toujours visible)', () => {
    for (const opts of [{ reduce: true }, { io: false }]) {
      const el = element(1200);
      expect(M.reveler([el], fenetre(opts).win)).toBe(0);
      expect(el.classes.size).toBe(0);
    }
  });

  test('sortie : immédiate en mouvement réduit, sinon classe ng-sortie retirée à la fin', () => {
    let fini = 0;
    const el = element(0);
    M.fermerAvecSortie(el, fenetre({ reduce: true }).win, () => fini++);
    expect(fini).toBe(1);
    expect(el.classes.size).toBe(0);
    M.fermerAvecSortie(el, fenetre().win, () => fini++);
    expect(fini).toBe(2);
    expect(el.classes.has('ng-sortie')).toBe(false);
  });

  test('piège du focus : Tab sur le dernier revient au premier, Maj+Tab sur le premier va au dernier', () => {
    const focus = [];
    const mk = (nom) => ({ nom, focus: () => focus.push(nom), hasAttribute: () => false, getAttribute: () => null });
    const a = mk('a'), b = mk('b');
    const conteneur = { querySelectorAll: () => [a, b], contains: (el) => el === a || el === b };
    const evt = (shiftKey) => ({ key: 'Tab', shiftKey, prevented: false, preventDefault() { this.prevented = true; } });
    let e = evt(false);
    expect(M.pieger(conteneur, e, { activeElement: b })).toBe(true);
    expect(e.prevented).toBe(true);
    e = evt(true);
    M.pieger(conteneur, e, { activeElement: a });
    expect(focus).toEqual(['a', 'b']);
    e = evt(false);
    expect(M.pieger(conteneur, e, { activeElement: a })).toBe(false);
    expect(M.pieger(conteneur, { key: 'Enter' }, { activeElement: a })).toBe(false);
  });
});
