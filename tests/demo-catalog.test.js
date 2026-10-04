const { analyserCatalogueDemo, chargerCatalogueDemo } = require('../src/utils/demo-catalog');
const { reinitialiserDemo } = require('../src/utils/demo-reset');
const { lireArguments } = require('../scripts/demo-reset');

const ENTETE = 'dci,brand_name,strength,form,pack_size,requires_prescription,restricted';

describe('analyserCatalogueDemo : « restricted » est la décision du propriétaire, jamais déduite', () => {
  test('valeurs explicites respectées (true ET false)', () => {
    const r = analyserCatalogueDemo(`${ENTETE}\nIbuprofène,Brufen,400mg,comprimé,20,false,false\nMorphine fictive,,10mg,ampoule,5,true,true\n`);
    expect(r.erreurs).toEqual([]);
    expect(r.medicaments.map((m) => [m.nom, m.restreint, m.ordonnance])).toEqual([['Brufen', false, false], ['Morphine fictive', true, true]]);
    expect(r.medicaments.every((m) => m.est_demo === true)).toBe(true);
  });
  test('restricted vide, mal écrit ou absent : restreint (défaut sûr) avec avertissement', () => {
    for (const v of ['', 'oui', 'non', 'FALSEY', '0']) {
      const r = analyserCatalogueDemo(`${ENTETE}\nX,Y,1mg,cp,1,false,${v}\n`);
      expect(r.medicaments[0].restreint).toBe(true);
      expect(r.avertissements.join(' ')).toMatch(/restreint retenu/);
    }
  });
  test('« False » ou « FALSE » explicites sont acceptés (casse ignorée)', () => {
    expect(analyserCatalogueDemo(`${ENTETE}\nX,Y,1mg,cp,1,false,FALSE\n`).medicaments[0].restreint).toBe(false);
    expect(analyserCatalogueDemo(`${ENTETE}\nX,Y,1mg,cp,1,false, False \n`).medicaments[0].restreint).toBe(false);
  });
  test('la fiche fictive « Exemple restreint (démo) » ne peut pas être non restreinte', () => {
    const r = analyserCatalogueDemo(`${ENTETE}\n,Exemple restreint (démo),,fictif,,false,false\n`);
    expect(r.medicaments).toEqual([]);
    expect(r.erreurs[0]).toMatch(/doit rester restricted=true/);
    expect(analyserCatalogueDemo(`${ENTETE}\n,Exemple restreint (démo),,fictif,,false,true\n`).medicaments).toHaveLength(1);
  });
  test('requires_prescription : vide = false « à confirmer », illisible = erreur', () => {
    const v = analyserCatalogueDemo(`${ENTETE}\nX,Y,1mg,cp,1,,false\n`);
    expect(v.medicaments[0].ordonnance).toBe(false);
    expect(v.avertissements.join(' ')).toMatch(/à confirmer/);
    expect(analyserCatalogueDemo(`${ENTETE}\nX,Y,1mg,cp,1,peut-être,false\n`).erreurs[0]).toMatch(/requires_prescription/);
  });
  test('erreurs de structure : colonnes manquantes, fichier vide, ligne sans nom ; doublons ignorés ; guillemets et BOM', () => {
    expect(analyserCatalogueDemo('dci,brand_name\nX,Y\n').erreurs[0]).toMatch(/Colonnes manquantes/);
    expect(analyserCatalogueDemo('').erreurs).toEqual(['Fichier vide']);
    expect(analyserCatalogueDemo(`${ENTETE}\n,,1mg,cp,1,false,false\n`).erreurs[0]).toMatch(/ni brand_name ni dci/);
    const d = analyserCatalogueDemo(`\uFEFF${ENTETE}\n"Ibu, profène","Bru ""fen""",400 mg,cp,1,false,false\nIbu,"Bru ""fen""",400mg,cp,1,false,false\n`);
    expect(d.medicaments).toHaveLength(1);
    expect(d.medicaments[0].nom).toBe('Bru "fen"');
    expect(d.avertissements.join(' ')).toMatch(/doublon/);
  });
  test('avertissements répétitifs regroupés ; colonne facultative « category » reprise', () => {
    const lignes = Array.from({ length: 12 }, (_, i) => `D${i},M${i},${i}mg,cp,,,,Analgésiques`).join('\n');
    const r = analyserCatalogueDemo(`${ENTETE},category\n${lignes}\n`);
    expect(r.medicaments).toHaveLength(12);
    expect(r.medicaments[0].categorie).toBe('Analgésiques');
    expect(r.avertissements.filter((a) => /^Ligne/.test(a))).toHaveLength(10);        // 5 + 5 détaillés
    expect(r.avertissements.join(' ')).toMatch(/12 fiche\(s\) sans décision « restricted »/);
    expect(analyserCatalogueDemo(`${ENTETE}\nX,Y,1mg,cp,,false,false\n`).medicaments[0].categorie).toBe('démonstration');
  });
  test('catalogue livré (issu de drug_variant_catalog.csv) : valide, fiche fictive restreinte, AUCUNE classification inventée', () => {
    const r = analyserCatalogueDemo(require('fs').readFileSync(require('path').join(__dirname, '../supabase/seed/demo_catalog.csv'), 'utf-8'));
    expect(r.erreurs).toEqual([]);
    expect(r.medicaments).toHaveLength(237);
    expect(r.medicaments.filter((m) => !m.restreint)).toEqual([]);                         // aucune décision du propriétaire : tout reste restreint
    expect(r.medicaments.find((m) => m.nom === 'Exemple restreint (démo)').restreint).toBe(true);
    expect(new Set(r.medicaments.map((m) => m.categorie)).size).toBeGreaterThan(5);
    const cles = r.medicaments.map((m) => `${m.nom.toLowerCase()}|${(m.dosage || '').replace(/\s+/g, '')}`);
    expect(new Set(cles).size).toBe(cles.length);                                           // compatible avec l'index unique nom + dosage
  });
});

function faux({ mode = 'demo', existants = [], rpcResultat = { data: { ok: 1 }, error: null } } = {}) {
  const appels = [];
  const sb = {
    appels,
    rpc: (nom, args) => { appels.push(['rpc', nom, args]); return Promise.resolve(nom === 'mode_public' ? { data: mode, error: null } : rpcResultat); },
    from: (table) => ({
      select: () => Promise.resolve({ data: existants, error: null }),
      insert: (v) => { appels.push(['insert', table, v]); return Promise.resolve({ error: null }); },
      update: (v) => ({ eq: (c, id) => { appels.push(['update', table, v, id]); return Promise.resolve({ error: null }); } }),
    }),
  };
  return sb;
}

describe('chargerCatalogueDemo', () => {
  const med = (nom, restreint, ordonnance = false, dosage = null) => ({ nom, dosage, restreint, ordonnance, est_demo: true });
  test('refuse hors mode démo : aucune écriture', async () => {
    const sb = faux({ mode: 'production' });
    await expect(chargerCatalogueDemo(sb, [med('A', true)])).rejects.toThrow(/mode démo/);
    expect(sb.appels.filter((a) => a[0] !== 'rpc')).toEqual([]);
  });
  test('insère les nouvelles fiches, met à jour celles dont la classification du fichier diffère, laisse le reste', async () => {
    const sb = faux({ existants: [{ id: 'e1', nom: 'Déjà là', dosage: '100 mg', ordonnance: false, restreint: true }, { id: 'e2', nom: 'Identique', dosage: null, ordonnance: false, restreint: true }] });
    const bilan = await chargerCatalogueDemo(sb, [med('Nouveau', false), med('déjà là', false, false, '100mg'), med('Identique', true)]);
    expect(bilan).toEqual({ inseres: 1, mis_a_jour: 1, inchanges: 1, restreints: 1, non_restreints: 2 });
    expect(sb.appels.find((a) => a[0] === 'insert')[2].restreint).toBe(false);
    expect(sb.appels.find((a) => a[0] === 'update')).toEqual(['update', 'medicaments', { ordonnance: false, restreint: false, est_demo: true }, 'e1']);
  });
  test('idempotent : un second chargement ne crée rien', async () => {
    const sb = faux({ existants: [{ id: 'e1', nom: 'A', dosage: null, ordonnance: false, restreint: true }] });
    expect(await chargerCatalogueDemo(sb, [med('A', true)])).toMatchObject({ inseres: 0, mis_a_jour: 0, inchanges: 1 });
  });
});

describe('reinitialiserDemo et script', () => {
  test('refuse hors mode démo, sinon appelle la fonction SQL avec le nombre de pharmacies', async () => {
    const prod = faux({ mode: 'production' });
    await expect(reinitialiserDemo(prod)).rejects.toThrow(/mode démo/);
    expect(prod.appels.some((a) => a[1] === 'reinitialiser_demo')).toBe(false);
    const ok = faux({ rpcResultat: { data: { empreinte: 'abc' }, error: null } });
    expect(await reinitialiserDemo(ok, { nbPharmacies: 4 })).toEqual({ empreinte: 'abc' });
    expect(ok.appels.find((a) => a[1] === 'reinitialiser_demo')[2]).toEqual({ p_nb_pharmacies: 4 });
  });
  test('erreur de la base : message sans détail', async () => {
    const sb = faux({ rpcResultat: { data: null, error: { code: '55000', message: 'détail sensible' } } });
    await expect(reinitialiserDemo(sb)).rejects.toThrow(/55000/);
    await expect(reinitialiserDemo(sb)).rejects.not.toThrow(/sensible/);
  });
  test('arguments du script : sans --confirmer rien n\'est confirmé ; valeurs bornées ; argument inconnu refusé', () => {
    expect(lireArguments([])).toEqual({ confirmer: false, nbPharmacies: 6, catalogue: null });
    expect(lireArguments(['--confirmer', '--nb-pharmacies', '3', '--catalogue']).catalogue).toBe('supabase/seed/demo_catalog.csv');
    expect(() => lireArguments(['--nb-pharmacies', '0'])).toThrow(/entier de 1 à 50/);
    expect(() => lireArguments(['--nb-pharmacies', 'abc'])).toThrow();
    expect(() => lireArguments(['--force'])).toThrow(/Argument inconnu/);
  });
});
