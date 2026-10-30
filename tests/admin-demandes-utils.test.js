const U = require('../public/admin-demandes-utils');

test('checklist : 5 éléments, état coché', () => {
  const e = U.etatChecklist([{ element: 'ordre_ok' }, { element: 'pas_doublon' }]);
  expect(e).toHaveLength(5);
  expect(e.filter((x) => x.coche).map((x) => x.element)).toEqual(['ordre_ok', 'pas_doublon']);
});

test('approbation : seulement en revue avec les 5 cases', () => {
  const toutes = U.ELEMENTS.map((x) => ({ element: x[0] }));
  expect(U.peutApprouver('in_review', toutes)).toBe(true);
  expect(U.peutApprouver('in_review', toutes.slice(0, 4))).toBe(false);
  expect(U.peutApprouver('submitted', toutes)).toBe(false);
  expect(U.peutApprouver('approved', toutes)).toBe(false);
});

test('actions selon le statut', () => {
  expect(U.actionsPossibles('submitted')).toEqual(['demarrer']);
  expect(U.actionsPossibles('needs_info')).toEqual(['demarrer']);
  expect(U.actionsPossibles('in_review')).toEqual(['approuver', 'complements', 'refuser']);
  expect(U.actionsPossibles('approved')).toEqual(['renvoyer_invitation']);
  expect(U.actionsPossibles('rejected')).toEqual([]);
});

test('libellés, raisons de doublon, erreurs, âge', () => {
  expect(U.libelleStatut('needs_info')).toBe('Compléments demandés');
  expect(U.libellesRaisons(['gps_30m', 'telephone'])).toEqual(['À moins de 30 m d\'une pharmacie existante', 'Même téléphone']);
  expect(U.messageErreur('checklist_incomplete')).toMatch(/5 cases/);
  expect(U.messageErreur('???')).toMatch(/erreur/);
  expect(U.formaterAge(0, false).texte).toBe('< 1 h');
  expect(U.formaterAge(30, true)).toEqual({ texte: '30 h', retard: true });
  expect(U.formaterAge(72, false).texte).toBe('3 j');
});
