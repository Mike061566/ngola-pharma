const U = require('../public/onboarding-utils');

const etat = (faits, extra = {}) => ({
  total: 6, faits: faits.length, statut: 'verifie', est_publiee: false, fraicheur_jours: 7, min_items_frais: 10, items_frais: 4,
  items: U.ORDRE.map((cle) => ({ cle, fait: faits.includes(cle) })).map((i) => (i.cle === 'seuil' ? { ...i, items_frais: 4, min_items_frais: 10 } : i)),
  ...extra
});

test('tâches dans l\'ordre de la spec, avec libellés', () => {
  const t = U.tachesAffichables(etat([]));
  expect(t.map((x) => x.cle)).toEqual(['mot_de_passe', 'ma_pharmacie', 'telegram', 'import', 'confirmation', 'seuil']);
  expect(t[0].titre).toMatch(/mot de passe/);
  expect(t.every((x) => x.fait === false)).toBe(true);
});

test('progression et prochaine tâche', () => {
  expect(U.progression(etat([]))).toBe(0);
  expect(U.progression(etat(['mot_de_passe', 'telegram', 'import']))).toBe(50);
  expect(U.prochaineTache(etat(['mot_de_passe']))).toMatchObject({ cle: 'ma_pharmacie' });
  expect(U.prochaineTache(etat(U.ORDRE))).toBeNull();
  expect(U.progression(null)).toBe(0);
});

test('détails : seuil de fraîcheur, Telegram, position', () => {
  const t = U.tachesAffichables(etat([]));
  expect(t.find((x) => x.cle === 'seuil').detail).toBe('4 / 10 médicaments confirmés depuis moins de 7 jours');
  const e = etat([]);
  e.items[1] = { cle: 'ma_pharmacie', fait: false, horaires: false, gps_present: true, gps_confirme: false };
  e.items[2] = { cle: 'telegram', fait: true, sans_telegram: true };
  const t2 = U.tachesAffichables(e);
  expect(t2[1].detail).toBe('horaires à renseigner · position à confirmer');
  expect(t2[2].detail).toMatch(/Sans Telegram.*réactivité moindre/);
});

test('visibilité et message de publication', () => {
  expect(U.checklistVisible(etat([]))).toBe(true);
  expect(U.checklistVisible(etat(U.ORDRE, { est_publiee: true }))).toBe(false);
  expect(U.checklistVisible(null)).toBe(false);
  expect(U.messagePublication(etat(U.ORDRE, { statut: 'non_verifie' }))).toMatch(/vérifiée/);
  expect(U.messagePublication(etat(U.ORDRE, { est_publiee: true }))).toMatch(/publiée/);
  expect(U.messagePublication(etat(['mot_de_passe']))).toBe('');
});

test('code couleur de fraîcheur : vert ≤ 3 j, orange ≤ 7 j, rouge au-delà', () => {
  const now = new Date('2026-10-10T12:00:00Z').getTime();
  const il = (j) => new Date(now - j * 86400000).toISOString();
  expect(U.couleurFraicheur(il(0.5), now)).toBe('vert');
  expect(U.couleurFraicheur(il(3), now)).toBe('vert');
  expect(U.couleurFraicheur(il(3.1), now)).toBe('orange');
  expect(U.couleurFraicheur(il(7), now)).toBe('orange');
  expect(U.couleurFraicheur(il(7.1), now)).toBe('rouge');
  expect(U.couleurFraicheur(null, now)).toBe('rouge');
  expect(U.couleurCss('vert')).not.toBe(U.couleurCss('rouge'));
});

test('mot de passe : 10 caractères et confirmation', () => {
  expect(U.erreurMotDePasse('court', 'court')).toMatch(/10 caractères/);
  expect(U.erreurMotDePasse('assezlongmdp', 'autrechose1')).toMatch(/identiques/);
  expect(U.erreurMotDePasse('assezlongmdp', 'assezlongmdp')).toBeNull();
});

test('liens des rappels : étape -> onglet, URL ?etape= validée', () => {
  expect(U.ongletPourEtape('telegram')).toBe('alerts');
  expect(U.ongletPourEtape('import')).toBe('import');
  expect(U.ongletPourEtape('ma_pharmacie')).toBe('pharmacy');
  expect(U.ongletPourEtape('inconnue')).toBeNull();
  expect(U.ongletPourEtape('__proto__')).toBeNull();
  expect(U.etapeDeLUrl('?etape=import')).toBe('import');
  expect(U.etapeDeLUrl('?a=1&etape=telegram&b=2')).toBe('telegram');
  expect(U.etapeDeLUrl('?etape=<script>')).toBeNull();
  expect(U.etapeDeLUrl('?etape=admin')).toBeNull();
  expect(U.etapeDeLUrl('')).toBeNull();
  expect(U.libelleEtape('activation')).toBe('Activation du compte');
  expect(U.libelleEtape('import')).toMatch(/Importer/);
});
