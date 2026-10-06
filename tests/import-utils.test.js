const U = require('../public/import-utils');

describe('parserPrix', () => {
  test.each([
    ['5400', 5400], ['5 400', 5400], ['5400 FCFA', 5400], ['5.400', 5400], ['5,400', 5400], ['1 250 F CFA', 1250], ['12 500 XAF', 12500],
    ['1.250.000', 1250000], ['1 250,50', 1251], ['99,5', 100], ['5 400', 5400], [5400, 5400], [5399.6, 5400]
  ])('%p -> %p', (entree, attendu) => { expect(U.parserPrix(entree)).toBe(attendu); });
  test.each([[''], ['abc'], [null], [undefined], ['n/a'], ['--']])('%p -> null', (e) => { expect(U.parserPrix(e)).toBeNull(); });
});

describe('parserBooleen', () => {
  const cas = [['oui', true], ['OUI', true], ['yes', true], ['1', true], ['vrai', true], [true, true], [1, true], ['non', false], ['no', false], ['0', false], ['faux', false], ['rupture', false]];
  test.each(cas)('%p -> %p', (e, a) => { expect(U.parserBooleen(e)).toBe(a); });
  test('vide -> défaut ; illisible -> null', () => {
    expect(U.parserBooleen('')).toBe(true);
    expect(U.parserBooleen('', false)).toBe(false);
    expect(U.parserBooleen('peut-être')).toBeNull();
  });
});

describe('CSV', () => {
  test('séparateur ; (Excel FR) et , détectés', () => {
    expect(U.detecterSeparateur('nom;prix\na;1,5\nb;2')).toBe(';');
    expect(U.detecterSeparateur('nom,prix\na,1\nb,2')).toBe(',');
    expect(U.detecterSeparateur('nom\tprix\na\t1')).toBe('\t');
  });
  test('guillemets, guillemets doublés, retour à la ligne dans une cellule, CRLF', () => {
    const t = 'nom;prix\r\n"Dolip;rane ""fort""";5 400\r\n"ligne\nbrisée";100\r\n';
    expect(U.parserCsv(t)).toEqual([['nom', 'prix'], ['Dolip;rane "fort"', '5 400'], ['ligne\nbrisée', '100']]);
  });
  test('encodage : UTF-8, BOM retiré, repli Windows-1252', () => {
    expect(U.decoderOctets(new Uint8Array([0xEF, 0xBB, 0xBF, 0x50, 0xC3, 0xA9]))).toBe('Pé');
    expect(U.decoderOctets(new Uint8Array([0x50, 0xE9, 0x72, 0x65]))).toBe('Pére');   // 0xE9 seul : invalide en UTF-8
  });
});

describe('détection des colonnes', () => {
  test('synonymes, accents, casse', () => {
    const c = U.detecterColonnes(['Désignation', 'Dosage', 'Prix (FCFA)', 'En stock ?', 'Conditionnement']);
    expect(c.indices).toEqual({ nom: 0, dosage: 1, prix: 2, en_stock: 3, conditionnement: 4 });
    expect(c.manquantes).toEqual([]);
  });
  test('colonnes obligatoires manquantes', () => {
    expect(U.detecterColonnes(['produit', 'dosage']).manquantes).toEqual(['prix']);
    expect(U.detecterColonnes(['x', 'y']).manquantes).toEqual(['nom', 'prix']);
  });
});

describe('lignesDepuisTableau', () => {
  const t = [['nom', 'dosage', 'prix', 'en_stock'], ['Doliprane 500', '', '5 400 FCFA', 'oui'], ['', '', '', ''], ['Amoxicilline', '500 mg', 'abc', 'peut-être'], ['Efferalgan', '', '900', '']];
  test('lignes lues, vides ignorées, n° de ligne du fichier, erreurs signalées sans bloquer le lot', () => {
    const r = U.lignesDepuisTableau(t);
    expect(r.ok).toBe(true);
    expect(r.vides).toBe(1);
    expect(r.lignes.map((l) => l.numero)).toEqual([2, 4, 5]);
    expect(r.lignes[0]).toMatchObject({ nom: 'Doliprane 500', prix: 5400, prix_brut: '5 400 FCFA', en_stock: true, en_stock_invalide: false });
    expect(r.lignes[1]).toMatchObject({ prix: null, en_stock_invalide: true });
    expect(r.lignes[2]).toMatchObject({ en_stock: true, en_stock_invalide: false });
  });
  test('colonne en_stock absente : tout en stock ; colonne obligatoire absente : erreur', () => {
    expect(U.lignesDepuisTableau([['nom', 'prix'], ['A', '100']]).lignes[0].en_stock).toBe(true);
    const e = U.lignesDepuisTableau([['nom', 'dosage'], ['A', '1']]);
    expect(e).toMatchObject({ ok: false, erreur: 'colonnes_manquantes', manquantes: ['prix'] });
    expect(U.erreurLecture(e)).toMatch(/prix/);
  });
  test('fichier sans ligne, et plus de 5 000 lignes', () => {
    expect(U.lignesDepuisTableau([['nom', 'prix']]).erreur).toBe('fichier_vide');
    const gros = [['nom', 'prix']].concat(Array.from({ length: 5001 }, (_, i) => ['M' + i, '100']));
    expect(U.lignesDepuisTableau(gros).erreur).toBe('trop_de_lignes');
    expect(U.lignesDepuisTableau(gros.slice(0, 5001)).ok).toBe(true);
  });
  test('le modèle téléchargeable est relu sans erreur', () => {
    const r = U.lignesDepuisTableau(U.parserCsv(U.decoderOctets(new TextEncoder().encode(U.modeleCsv()))));
    expect(r.ok).toBe(true);
    expect(r.lignes.map((l) => l.prix)).toEqual([1500, 2500, 1800]);
    expect(r.lignes[2].en_stock).toBe(false);
    expect(r.lignes.every((l) => !l.en_stock_invalide)).toBe(true);
  });
});

test('fichier : taille et extension', () => {
  expect(U.erreurFichier({ name: 'a.csv', size: 100 })).toBeNull();
  expect(U.erreurFichier({ name: 'a.XLSX', size: 100 })).toBeNull();
  expect(U.erreurFichier({ name: 'a.csv', size: 6 * 1024 * 1024 })).toMatch(/volumineux/);
  expect(U.erreurFichier({ name: 'a.pdf', size: 100 })).toMatch(/Format/);
  expect(U.erreurFichier({ name: 'a.csv', size: 0 })).toMatch(/vide/);
  expect(U.erreurFichier(null)).toMatch(/Choisissez/);
  expect(U.typeFichier('x.xls')).toBe('excel');
  expect(U.typeFichier('x.csv')).toBe('csv');
});

test('découpage en paquets', () => {
  expect(U.decouper(Array.from({ length: 450 }, (_, i) => i)).map((p) => p.length)).toEqual([200, 200, 50]);
  expect(U.decouper([], 10)).toEqual([]);
});

test('libellés d\'aperçu et résumé', () => {
  expect(U.libelleEtat('a_confirmer')).toMatchObject({ libelle: 'À confirmer', classe: 'attention' });
  expect(U.libelleEtat('inconnu').libelle).toBe('inconnu');
  expect(U.libelleProbleme({ code: 'prix_ecart_median', detail: 'médiane : 5000 FCFA' })).toMatch(/5000/);
  expect(U.libelleProbleme({ code: 'ambigu' })).toMatch(/Plusieurs fiches/);
  expect(U.libelleProbleme({ code: 'conditionnement_non_verifie', detail: 'Boîte de 20' })).toMatch(/non vérifié.*Boîte de 20/);
  expect(U.libelleProbleme({ code: 'conditionnement_different', detail: 'fichier : 8 ; catalogue : 16' })).toMatch(/différent.*catalogue : 16/);
  expect(U.resume({ total: 10, reconnu: 5, suggestion: 1, a_confirmer: 2, non_reconnu: 1, erreur: 1 })).toBe('10 ligne(s) : 6 reconnue(s), 2 à confirmer, 1 non reconnue(s), 1 en erreur.');
  expect(U.peutValider({ a_ecrire: 0 })).toBe(false);
  expect(U.peutValider({ a_ecrire: 3 })).toBe(true);
});
