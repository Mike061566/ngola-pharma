const fs = require('fs');
const path = require('path');
const { genererSqlCatalogueDemo } = require('../scripts/catalogue-demo-sql');
const { analyserCatalogueDemo } = require('../src/utils/demo-catalog');

const CSV = fs.readFileSync(path.join(__dirname, '../supabase/seed/demo_catalog.csv'), 'utf-8');
const SQL = fs.readFileSync(path.join(__dirname, '../supabase/ops/charger_catalogue_demo.sql'), 'utf-8');
const ENTETE = 'dci,brand_name,strength,form,pack_size,requires_prescription,restricted';
const lignesValeurs = (sql) => sql.split('\n').filter((l) => /^ {4}\(\d+, /.test(l)).map((l) => l.replace(/[,;]$/, ''));

describe('charger_catalogue_demo.sql (phase I2 sans Node.js ni clé service_role)', () => {
  test('le fichier SQL commité est à jour du CSV (sinon : node scripts/catalogue-demo-sql.js)', () => {
    expect(SQL).toBe(genererSqlCatalogueDemo(CSV));
  });

  test('une ligne SQL par fiche retenue par analyserCatalogueDemo (doublons du fichier ignorés)', () => {
    expect(lignesValeurs(SQL)).toHaveLength(analyserCatalogueDemo(CSV).medicaments.length);
  });

  test('classification recopiée du fichier, jamais décidée : restricted vide → restreint ; false seulement si écrit', () => {
    const sql = genererSqlCatalogueDemo(`${ENTETE}\nA,Sans décision,1mg,cp,,,\nB,Décision false,2mg,cp,,true,false\nC,Décision true,3mg,cp,,false,true\n`);
    expect(lignesValeurs(sql)).toEqual([
      "    (1, 'Sans décision', 'Sans décision', 'A', 'cp', '1mg', NULL, 'démonstration', false, true)",
      "    (2, 'Décision false', 'Décision false', 'B', 'cp', '2mg', NULL, 'démonstration', true, false)",
      "    (3, 'Décision true', 'Décision true', 'C', 'cp', '3mg', NULL, 'démonstration', false, true)",
    ]);
  });

  test('apostrophes échappées : aucune valeur du CSV ne peut sortir de sa chaîne SQL', () => {
    const sql = genererSqlCatalogueDemo(`${ENTETE}\nX,"L'eau'); DROP TABLE medicaments; --",1mg,cp,,,\n`);
    expect(lignesValeurs(sql)[0]).toBe("    (1, 'L''eau''); DROP TABLE medicaments; --', 'L''eau''); DROP TABLE medicaments; --', 'X', 'cp', '1mg', NULL, 'démonstration', false, true)");
  });

  test('CSV invalide : aucun SQL produit', () => {
    expect(() => genererSqlCatalogueDemo('dci,brand_name\nA,B\n')).toThrow(/Catalogue invalide/);
  });

  test('garde-fous du script : mode démo exigé, simulation par défaut, aucune suppression', () => {
    expect(SQL).toMatch(/IF public\.mode_application\(\) <> 'demo' THEN\s+RAISE EXCEPTION/);
    expect(SQL.trimEnd().split('\n').pop()).toMatch(/^ROLLBACK;\s+-- SIMULATION/);
    expect(SQL).not.toMatch(/^\s*(DELETE|TRUNCATE|DROP)\b/im);
    expect(SQL).not.toMatch(/^\s*COMMIT\b/im);
  });
});
