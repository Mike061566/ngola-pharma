const fs = require('fs');
const path = require('path');

const sql = fs.readFileSync(path.join(__dirname, '../supabase/diagnostics/verification_post_migrations.sql'), 'utf8');

// Requêtes passées à query_to_xml(...) : texte entre la première quote et « ', false, true, '') »
const requetes = [...sql.matchAll(/query_to_xml\('((?:[^']|'')*)', false, true, ''\)/g)].map((m) => m[1].replace(/''/g, "'"));

describe('verification_post_migrations.sql', () => {
  test('les requêtes lues en XML sont toutes repérées', () => {
    expect(requetes.length).toBe((sql.match(/query_to_xml\(/g) || []).length);
    expect(requetes.length).toBeGreaterThan(0);
  });

  // Une requête sans ligne produit un document XML vide : xpath() échoue (« could not parse XML document ») et tout
  // le script s'arrête. Cas réel en production : schéma storage présent, bucket documents-demandes pas encore créé.
  test('chaque requête renvoie toujours exactement une ligne (agrégat ou sous-requête scalaire)', () => {
    for (const q of requetes) {
      const uneLigne = /^SELECT \(SELECT .+\) AS v$/s.test(q) || (/^SELECT .*\b(count|string_agg)\(/s.test(q) && !/\bGROUP BY\b/i.test(q));
      expect({ requete: q, uneLigne }).toEqual({ requete: q, uneLigne: true });
    }
  });
});
