const { icone, NOMS } = require('../public/ui-icones');

describe('icônes SVG', () => {
  test('chaque icône est décorative (aria-hidden, non focalisable) et hérite de la couleur du texte', () => {
    for (const nom of NOMS) {
      const svg = icone(nom);
      expect(svg).toMatch(/^<svg class="ng-icone"/);
      expect(svg).toContain('aria-hidden="true"');
      expect(svg).toContain('focusable="false"');
      expect(svg).toContain('stroke="currentColor"');
      expect(svg).not.toMatch(/<script|on\w+=/i);
    }
  });

  test('les statuts de la charte ont tous une icône distincte (jamais la couleur seule)', () => {
    const statuts = ['garde', 'verifie', 'dispo', 'faible', 'rupture', 'horloge'];
    for (const s of statuts) expect(NOMS).toContain(s);
    expect(new Set(statuts.map((s) => icone(s))).size).toBe(statuts.length);
  });

  test('nom inconnu : chaîne vide, classe supplémentaire ajoutée', () => {
    expect(icone('inconnue')).toBe('');
    expect(icone('garde', 'grande')).toMatch(/^<svg class="ng-icone grande"/);
  });
});
