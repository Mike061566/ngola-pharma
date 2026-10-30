const http = require('http');
const express = require('express');

// Faux client Supabase : enregistre les appels de filtre et répond « aucun résultat ».
const mockCalls = [];
function mockBuilder(table) {
  const builder = new Proxy({}, {
    get(_t, prop) {
      if (prop === 'then') {
        return (resolve) => resolve({ data: [], error: null, count: 0 });
      }
      return (...args) => { mockCalls.push({ table, method: String(prop), args }); return builder; };
    },
  });
  return builder;
}
jest.mock('../src/config/supabase', () => {
  const client = { from: (table) => mockBuilder(table) };
  return { supabase: client, supabaseAdmin: client };
});

const { sanitizeSearchTerm, orIlike, MAX_SEARCH_LENGTH } = require('../src/utils/search');

const COLS = ['nom', 'dci', 'nom_commercial', 'categorie'];
const HOSTILE = [
  "x%,id.not.is.null",
  'a),(nom.eq.b',
  'a"b\\c',
  'doli*',
  'x%,pharmacie_id.in.(1,2)',
  "paracetamol,or(nom.ilike.%)",
];

/** Découpe un filtre or() comme PostgREST : une virgule = un nouveau filtre. */
function splitOr(filter) { return filter.split(','); }

describe('sanitizeSearchTerm', () => {
  test('conserve les noms de médicaments usuels, accents compris', () => {
    expect(sanitizeSearchTerm('Paracétamol 500mg')).toBe('Paracétamol 500mg');
    expect(sanitizeSearchTerm('Artémether-Lumefantrine 20/120mg')).toBe('Artémether-Lumefantrine 20/120mg');
    expect(sanitizeSearchTerm("Dafalgan  1.5 g")).toBe('Dafalgan 1.5 g');
  });

  test.each(HOSTILE)('retire les caractères de contrôle PostgREST : %s', (payload) => {
    const t = sanitizeSearchTerm(payload);
    expect(t).not.toMatch(/[,()"\\%*_:]/);
  });

  test('valeurs non textuelles, vides, trop longues', () => {
    expect(sanitizeSearchTerm(undefined)).toBe('');
    expect(sanitizeSearchTerm(['a', 'b'])).toBe('');
    expect(sanitizeSearchTerm({ a: 1 })).toBe('');
    expect(sanitizeSearchTerm('%%%')).toBe('');
    expect(sanitizeSearchTerm('a'.repeat(500)).length).toBe(MAX_SEARCH_LENGTH);
  });

  test.each(HOSTILE)('le filtre or() produit exactement 4 filtres : %s', (payload) => {
    const parts = splitOr(orIlike(COLS, sanitizeSearchTerm(payload) || 'x'));
    expect(parts).toHaveLength(4);
    parts.forEach((p, i) => expect(p).toMatch(new RegExp(`^${COLS[i]}\\.ilike\\.%[^,()"\\\\*]*%$`)));
  });
});

describe('routes : aucune injection dans or()', () => {
  let server;
  let base;
  beforeAll(() => new Promise((resolve) => {
    const app = express();
    app.use('/api/medicaments', require('../src/routes/medicaments'));
    app.use('/api/stocks', require('../src/routes/stocks'));
    app.use('/api/pharmacies', require('../src/routes/pharmacies'));
    app.use((err, _req, res, _next) => res.status(500).json({ error: String(err.message) }));
    server = http.createServer(app).listen(0, () => { base = `http://127.0.0.1:${server.address().port}`; resolve(); });
  }));
  afterAll(() => new Promise((resolve) => {
    server.close(() => resolve());
    server.closeAllConnections();
  }));
  beforeEach(() => { mockCalls.length = 0; });

  const orCalls = () => mockCalls.filter((c) => c.method === 'or');

  test.each(HOSTILE)('GET /api/medicaments?q=%s', async (payload) => {
    await fetch(`${base}/api/medicaments?q=${encodeURIComponent(payload)}`);
    orCalls().forEach((c) => expect(splitOr(c.args[0])).toHaveLength(4));
  });

  test.each(HOSTILE)('GET /api/stocks?medicament=%s', async (payload) => {
    await fetch(`${base}/api/stocks?medicament=${encodeURIComponent(payload)}`);
    orCalls().forEach((c) => expect(splitOr(c.args[0])).toHaveLength(4));
  });

  test.each(HOSTILE)('GET /api/stocks/meilleurs-prix?q=%s', async (payload) => {
    await fetch(`${base}/api/stocks/meilleurs-prix?q=${encodeURIComponent(payload)}`);
    orCalls().forEach((c) => expect(splitOr(c.args[0])).toHaveLength(4));
  });

  test('recherche saine : le filtre est bien appliqué', async () => {
    await fetch(`${base}/api/medicaments?q=${encodeURIComponent('Coartem 20/120mg')}`);
    expect(orCalls()).toHaveLength(1);
    expect(orCalls()[0].args[0]).toBe(orIlike(COLS, 'Coartem 20/120mg'));
  });

  test('terme sans caractère admis : réponse vide, aucune requête de filtre', async () => {
    const res = await fetch(`${base}/api/medicaments?q=${encodeURIComponent('%%%')}`);
    expect(await res.json()).toMatchObject({ data: [], total: 0 });
    expect(orCalls()).toHaveLength(0);
  });

  test('q vide ou absent : pas de filtre (comportement inchangé)', async () => {
    await fetch(`${base}/api/medicaments?q=`);
    await fetch(`${base}/api/medicaments`);
    expect(orCalls()).toHaveLength(0);
  });

  test('q passé en tableau (?q[]=a) : traité comme texte invalide, sans exception', async () => {
    const res = await fetch(`${base}/api/medicaments?q[]=a&q[]=b`);
    expect(res.status).toBe(200);
    expect(orCalls()).toHaveLength(0);
  });
});
