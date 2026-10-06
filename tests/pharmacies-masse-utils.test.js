const U = require('../public/pharmacies-masse-utils');
const IU = require('../public/import-utils');

test('colonnes : synonymes et accents ; nom et quartier obligatoires', () => {
  const c = U.detecterColonnes(['Pharmacie', 'Quartier', 'Adresse', 'Tél', 'Lat', 'Lng', 'Pharmacien', 'N° Ordre', 'Courriel', 'Mobile']);
  expect(c.indices).toEqual({ nom: 0, quartier: 1, adresse: 2, telephone: 3, latitude: 4, longitude: 5, titulaire: 6, numero_ordre: 7, email: 8, telephone_mobile: 9 });
  expect(c.manquantes).toEqual([]);
  expect(U.detecterColonnes(['adresse', 'telephone']).manquantes).toEqual(['nom', 'quartier']);
});

test('téléphones : formats camerounais -> +237 ; illisible renvoyé tel quel pour que le serveur le signale', () => {
  expect(U.normaliserTelephone('6 99 12 34 56')).toBe('+237699123456');
  expect(U.normaliserTelephone('+237 222 23 45 67')).toBe('+237222234567');
  expect(U.normaliserTelephone('00237699123456')).toBe('+237699123456');
  expect(U.normaliserTelephone('237699123456')).toBe('+237699123456');
  expect(U.normaliserTelephone('')).toBe('');
  expect(U.normaliserTelephone('123')).toBe('123');
});

test('coordonnées : virgule décimale, vide = null, illisible = NaN', () => {
  expect(U.nombre('3,8667')).toBe(3.8667);
  expect(U.nombre('11.5')).toBe(11.5);
  expect(U.nombre('')).toBeNull();
  expect(Number.isNaN(U.nombre('abc'))).toBe(true);
});

describe('lignesDepuisTableau', () => {
  const t = [['nom', 'quartier', 'telephone', 'latitude', 'longitude', 'numero_ordre'],
    ['Pharmacie A', 'Bastos', '222 23 45 67', '3,88', '11,51', 'ORD-1'], ['', '', '', '', '', ''], ['Pharmacie B', 'Mvog-Ada', '', 'abc', '11.5', ''], ['Pharmacie C', 'Bastos', '6 99 00 00 01', '', '', '']];
  test('lignes lues, vides ignorées, numéro de ligne du fichier, GPS illisible signalé', () => {
    const r = U.lignesDepuisTableau(t);
    expect(r.ok).toBe(true);
    expect(r.vides).toBe(1);
    expect(r.lignes.map((l) => l.numero)).toEqual([2, 4, 5]);
    expect(r.lignes[0]).toMatchObject({ nom: 'Pharmacie A', telephone: '+237222234567', latitude: 3.88, longitude: 11.51, gps_invalide: false, numero_ordre: 'ORD-1' });
    expect(r.lignes[1]).toMatchObject({ latitude: null, longitude: null, gps_invalide: true });
    expect(r.lignes[2]).toMatchObject({ latitude: null, longitude: null, gps_invalide: false, telephone: '+237699000001' });
  });
  test('erreurs de fichier', () => {
    expect(U.lignesDepuisTableau([['nom', 'quartier']]).erreur).toBe('fichier_vide');
    const e = U.lignesDepuisTableau([['nom', 'adresse'], ['A', 'x']]);
    expect(e).toMatchObject({ ok: false, erreur: 'colonnes_manquantes', manquantes: ['quartier'] });
    expect(U.erreurLecture(e)).toMatch(/quartier/);
    const gros = [['nom', 'quartier']].concat(Array.from({ length: 1001 }, (_, i) => ['P' + i, 'Bastos']));
    expect(U.lignesDepuisTableau(gros).erreur).toBe('trop_de_lignes');
    expect(U.lignesDepuisTableau(gros.slice(0, 1001)).ok).toBe(true);
  });
});

test('le modèle téléchargeable (séparateur « ; », BOM) est relu sans erreur', () => {
  const r = U.lireTexteCsv(IU.decoderOctets(new TextEncoder().encode(U.modeleCsv())));
  expect(r.ok).toBe(true);
  expect(r.lignes[0]).toMatchObject({ nom: 'Pharmacie Exemple', quartier: 'Bastos', telephone: '+237222234567', telephone_mobile: '+237699123456' });
  expect(U.ENTETE).toHaveLength(10);
});

test('libellés d\'aperçu', () => {
  expect(U.libelleEtat('doublon').libelle).toBe('Doublon');
  expect(U.libelleProbleme({ code: 'doublon', detail: ['telephone', 'gps_30m'] })).toMatch(/même téléphone, à moins de 30 m/);
  expect(U.libelleProbleme({ code: 'quartier_inconnu', detail: 'Inconnuville' })).toMatch(/« Inconnuville »/);
  expect(U.libelleProbleme({ code: 'gps_invalide' })).toMatch(/Cameroun/);
  expect(U.resume({ total: 12, pret: 3, doublon: 5, erreur: 4, a_creer: 3 })).toBe('12 ligne(s) : 3 prête(s), 5 doublon(s) probable(s), 4 en erreur. À créer : 3.');
  expect(U.peutValider({ a_creer: 0 })).toBe(false);
  expect(U.peutValider({ a_creer: 2 })).toBe(true);
});

test('checklist de vérification : 5 cases, vérification seulement si toutes cochées', () => {
  expect(U.etatCases([{ element: 'ordre_ok' }])).toHaveLength(5);
  expect(U.peutVerifier(U.CASES.slice(0, 4).map((c) => ({ element: c[0] })))).toBe(false);
  expect(U.peutVerifier(U.CASES.map((c) => ({ element: c[0] })))).toBe(true);
  expect(U.peutVerifier([])).toBe(false);
});
