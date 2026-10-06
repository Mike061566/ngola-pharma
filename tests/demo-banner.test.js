const { bandeauNecessaire, TEXTE } = require('../public/demo-banner');

describe('bannière de démonstration', () => {
  test('affichée uniquement en mode demo (jamais en production, ni si le mode est inconnu)', () => {
    expect(bandeauNecessaire('demo')).toBe(true);
    for (const m of ['production', null, undefined, '', 'DEMO', 'autre']) expect(bandeauNecessaire(m)).toBe(false);
  });
  test('texte de la spec, sans promesse de disponibilité réelle', () => {
    expect(TEXTE).toMatch(/^MODE DÉMO — données fictives/);
    expect(TEXTE).toMatch(/Aucune disponibilité réelle/);
  });
});
