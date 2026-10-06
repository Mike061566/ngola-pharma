// seedMedicaments doit être idempotent : un rechargement du seed ne recrée jamais de fiche (cause des doublons Coartem / Chloroquine).
process.env.SUPABASE_URL = 'http://localhost';
process.env.SUPABASE_SERVICE_KEY = 'cle-de-test';

const mockTable = [];
jest.mock('@supabase/supabase-js', () => ({
  createClient: () => ({
    from: () => ({
      select: () => Promise.resolve({ data: mockTable.slice(), error: null }),
      insert: (rows) => ({
        select: () => {
          const ajoutes = rows.map((r, i) => ({ id: `n${mockTable.length + i}`, ...r }));
          mockTable.push(...ajoutes);
          return Promise.resolve({ data: ajoutes, error: null });
        },
      }),
    }),
  }),
}));

const { seedMedicaments } = require('../src/utils/seed');

describe('seedMedicaments', () => {
  beforeEach(() => { mockTable.length = 0; jest.spyOn(console, 'log').mockImplementation(() => {}); });
  afterEach(() => jest.restoreAllMocks());

  test('deux exécutions successives : aucune fiche en double', async () => {
    await seedMedicaments();
    const apresPremier = mockTable.length;
    expect(apresPremier).toBeGreaterThan(0);
    await seedMedicaments();
    expect(mockTable.length).toBe(apresPremier);
  });

  test('une fiche existante sous un autre nom (même produit) n\'est pas recréée', async () => {
    mockTable.push({ id: 'existant', nom: 'Coartem', nom_commercial: 'Coartem', dci: 'Artemether-Lumefantrine', forme: 'Comprimé', dosage: '20/120mg' });
    await seedMedicaments();
    const coartem = mockTable.filter((m) => (m.dci || '').toLowerCase().startsWith('artemether'));
    expect(coartem).toHaveLength(1);
  });
});
