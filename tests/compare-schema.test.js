const { parseInventory, compareInventories, fixHint } = require('../scripts/compare-schema');

const expected = parseInventory([
  'table|stocks|table rls=true force_rls=false',
  'policy|profils.profils_update|cmd=UPDATE using=(id = auth.uid()) with_check=(pharmacie_id = x)',
  'trigger|pharmacies.trg_pharmacies_protect|CREATE TRIGGER trg_pharmacies_protect BEFORE UPDATE ON public.pharmacies',
  'info|count.stocks|15',
].join('\n'));

describe('compare-schema', () => {
  test('ignore les lignes info et les extensions en trop', () => {
    expect([...expected.keys()].some((k) => k.startsWith('info|'))).toBe(false);
    const prod = parseInventory('extension|pg_graphql|\ntable|stocks|table rls=true force_rls=false');
    const r = compareInventories(expected, prod);
    expect(r.extra).toEqual([]);
  });

  test('détecte manquant, différent et en trop', () => {
    const prod = parseInventory([
      'table|stocks|table rls=false force_rls=false',
      'policy|profils.profils_update|cmd=UPDATE using=(id = auth.uid()) with_check=(pharmacie_id = x)',
      'policy|stocks.ancienne|cmd=ALL',
    ].join('\n'));
    const r = compareInventories(expected, prod);
    expect(r.missing.map((m) => m.key)).toEqual(['trigger|pharmacies.trg_pharmacies_protect']);
    expect(r.different.map((d) => d.key)).toEqual(['table|stocks']);
    expect(r.extra.map((e) => e.key)).toEqual(['policy|stocks.ancienne']);
  });

  test('lit le CSV entre guillemets et ignore les préfixes de schéma', () => {
    const prod = parseInventory('"table|stocks|table rls=true force_rls=false"\n"trigger|pharmacies.trg_pharmacies_protect|CREATE TRIGGER trg_pharmacies_protect BEFORE UPDATE ON extensions.pharmacies"');
    const r = compareInventories(
      parseInventory('table|stocks|table rls=true force_rls=false\ntrigger|pharmacies.trg_pharmacies_protect|CREATE TRIGGER trg_pharmacies_protect BEFORE UPDATE ON public.pharmacies'),
      prod
    );
    expect(r.missing).toEqual([]);
    expect(r.different).toEqual([]);
  });

  test('associe un écart connu à son script correctif', () => {
    expect(fixHint('trigger|pharmacies.trg_pharmacies_protect', 'x')).toBe('supabase/fix_pharmacies_colonnes_protegees.sql');
    expect(fixHint('table|stocks', 'x')).toBeNull();
  });
});
