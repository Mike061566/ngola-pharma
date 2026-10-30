const fs = require('fs');
const path = require('path');
const { convertirCatalogueVariantes, genererFeuilleDecisions, lireDecisions } = require('../src/utils/demo-convert');
const { analyserCatalogueDemo } = require('../src/utils/demo-catalog');
const { lireArguments } = require('../scripts/demo-convert-catalog');

const SRC = 'drug_id,dci,atc_code,category,variant_id,brand,dosage,form,is_generic,price_xaf,availability';
const source = [SRC,
  'd1,Paracétamol,WHO ATC: N02BE01,Analgésiques,v1,Paracétamol Brand1,250 mg,sirop,False,1000,in_stock',
  'd1,Paracétamol,WHO ATC: N02BE01,Analgésiques,v2,Paracétamol Brand1,250 mg,sirop,True,900,out',          // même fiche (générique, autre prix)
  'd1,Paracétamol,WHO ATC: N02BE01,Analgésiques,v3,Paracétamol Brand1,250 mg,comprimé,False,1100,low',     // autre forme = autre fiche
  'd2,Quinine,WHO ATC: P01BC01,Antipaludéens,v4,Quinine Brand2,500 mg,capsule,True,2000,unknown'].join('\n');

describe('convertirCatalogueVariantes', () => {
  test('une fiche par (marque, forme, dosage) ; la forme entre dans le nom ; variantes regroupées', () => {
    const r = convertirCatalogueVariantes(source);
    expect(r.stats).toMatchObject({ fiches: 3, variantes_regroupees: 1, dci: 2 });
    const a = analyserCatalogueDemo(r.csv);
    expect(a.erreurs).toEqual([]);
    expect(a.medicaments.map((m) => [m.nom, m.dosage, m.forme, m.dci, m.categorie])).toEqual([
      ['Paracétamol Brand1 sirop', '250 mg', 'sirop', 'Paracétamol', 'Analgésiques'],
      ['Paracétamol Brand1 comprimé', '250 mg', 'comprimé', 'Paracétamol', 'Analgésiques'],
      ['Quinine Brand2 capsule', '500 mg', 'capsule', 'Quinine', 'Antipaludéens']]);
  });
  test('SANS feuille de décisions : aucune classification inventée (restricted et ordonnance vides -> restreint)', () => {
    const r = convertirCatalogueVariantes(source);
    expect(r.stats.dci_avec_decision_restricted).toBe(0);
    const a = analyserCatalogueDemo(r.csv);
    expect(a.medicaments.every((m) => m.restreint === true)).toBe(true);
    expect(a.avertissements.join(' ')).toMatch(/restreint retenu/);
  });
  test('la décision du propriétaire (par DCI) est reprise telle quelle, true comme false ; une cellule vide reste vide', () => {
    const decisions = 'dci,category,atc_code,requires_prescription,restricted\nParacétamol,Analgésiques,N02BE01,false,false\nQuinine,Antipaludéens,P01BC01,true,\n';
    const r = convertirCatalogueVariantes(source, decisions);
    expect(r.stats).toMatchObject({ dci_avec_decision_restricted: 1, dci_sans_decision: 1 });
    const a = analyserCatalogueDemo(r.csv);
    expect(a.medicaments.filter((m) => m.dci === 'Paracétamol').every((m) => m.restreint === false && m.ordonnance === false)).toBe(true);
    const q = a.medicaments.find((m) => m.dci === 'Quinine');
    expect(q.restreint).toBe(true);          // restricted vide : défaut sûr
    expect(q.ordonnance).toBe(true);         // requires_prescription explicite
  });
  test('valeurs de décision autres que true/false ignorées (jamais interprétées)', () => {
    for (const v of ['oui', 'non', '1', 'peut-être', 'FALSE ']) {
      const d = lireDecisions(`dci,restricted,requires_prescription\nParacétamol,${v},${v}\n`).get('paracétamol');
      expect(d.restricted === 'false' || d.restricted === '').toBe(true);
      expect(['oui', 'non', '1', 'peut-être']).not.toContain(d.restricted);
    }
    expect(lireDecisions('dci,restricted,requires_prescription\nX,TRUE,False\n').get('x')).toEqual({ restricted: 'true', requires_prescription: 'false' });
  });
  test('erreurs : colonnes manquantes, fichier vide, ligne sans marque', () => {
    expect(() => convertirCatalogueVariantes('dci,brand\nX,Y\n')).toThrow(/Colonnes manquantes/);
    expect(() => convertirCatalogueVariantes('')).toThrow(/vide/);
    expect(() => convertirCatalogueVariantes(`${SRC}\nd,X,A,C,v,,250 mg,sirop,False,1,in_stock\n`)).toThrow(/sans dci ou sans marque/);
  });
});

describe('feuille de décisions', () => {
  test('une ligne par DCI, cellules de décision VIDES ; les décisions existantes sont conservées', () => {
    const r = convertirCatalogueVariantes(source);
    const feuille = genererFeuilleDecisions(r.dcis);
    expect(feuille.trim().split('\n')).toEqual(['dci,category,atc_code,requires_prescription,restricted', 'Paracétamol,Analgésiques,N02BE01,,', 'Quinine,Antipaludéens,P01BC01,,']);
    const rempli = feuille.replace('Quinine,Antipaludéens,P01BC01,,', 'Quinine,Antipaludéens,P01BC01,true,false');
    expect(genererFeuilleDecisions(r.dcis, rempli)).toBe(rempli);
  });
  test('la feuille LIVRÉE ne contient aucune décision : 20 DCI, cellules vides (elle est à remplir par le propriétaire)', () => {
    const t = fs.readFileSync(path.join(__dirname, '../supabase/seed/demo_classification.csv'), 'utf-8').trim().split('\n');
    expect(t[0]).toBe('dci,category,atc_code,requires_prescription,restricted');
    expect(t).toHaveLength(21);
    for (const l of t.slice(1)) expect(l).toMatch(/,,$/);
  });
  test('le catalogue livré correspond à la source et à la feuille livrée (régénération identique)', () => {
    const base = path.join(__dirname, '../supabase/seed');
    const r = convertirCatalogueVariantes(fs.readFileSync(path.join(base, 'source/drug_variant_catalog.csv'), 'utf-8'), fs.readFileSync(path.join(base, 'demo_classification.csv'), 'utf-8'));
    expect(r.stats).toMatchObject({ fiches: 236, dci: 20 });
    expect(fs.readFileSync(path.join(base, 'demo_catalog.csv'), 'utf-8')).toBe(r.csv + ',Exemple restreint (démo),,fictif,,false,true,démonstration\n');
  });
  test('arguments du script', () => {
    expect(lireArguments([]).sortie).toBe('supabase/seed/demo_catalog.csv');
    expect(lireArguments(['--sortie', 'x.csv']).sortie).toBe('x.csv');
    expect(() => lireArguments(['--force'])).toThrow(/Argument inconnu/);
    expect(() => lireArguments(['--source'])).toThrow(/valeur manquante/);
  });
});
