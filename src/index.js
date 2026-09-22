require('dotenv').config();

const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');

const pharmaciesRouter = require('./routes/pharmacies');
const medicamentsRouter = require('./routes/medicaments');
const quartiersRouter = require('./routes/quartiers');
const stocksRouter = require('./routes/stocks');
const errorHandler = require('./middleware/errorHandler');

const app = express();
const PORT = process.env.PORT || 3000;

// ── Sécurité ──────────────────────────────────────────
app.use(helmet({
  contentSecurityPolicy: false,  // Désactivé — le frontend utilise des onclick inline
}));

// ── CORS ──────────────────────────────────────────────
// Pas de fallback '*' : sans CORS_ORIGIN explicite, les requêtes cross-origin sont refusées.
// Toutes les routes de cette API sont en lecture seule (GET) — aucune méthode d'écriture
// n'est implémentée, donc aucune n'est autorisée ici.
app.use(cors({
  origin: process.env.CORS_ORIGIN || false,
  methods: ['GET'],
  allowedHeaders: ['Content-Type', 'Authorization'],
}));

// ── Rate limiting ─────────────────────────────────────
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Trop de requêtes, veuillez réessayer plus tard.' },
});
app.use('/api/', limiter);

// ── Parsing & logging ─────────────────────────────────
app.use(express.json());
app.use(morgan(process.env.NODE_ENV === 'production' ? 'combined' : 'dev'));

// ── Fichiers statiques ────────────────────────────────
app.use(express.static('public'));

// ── Routes API ────────────────────────────────────────
app.use('/api/pharmacies', pharmaciesRouter);
app.use('/api/medicaments', medicamentsRouter);
app.use('/api/quartiers', quartiersRouter);
app.use('/api/stocks', stocksRouter);

// ── Health check ──────────────────────────────────────
app.get('/api/health', (req, res) => {
  res.json({
    status: 'ok',
    version: require('../package.json').version,
    timestamp: new Date().toISOString(),
  });
});

// ── Diagnostic (dev only) ────────────────────────────
// Non monté du tout en production : évite d'exposer les comptages de tables, les noms de
// colonnes et si la clé de service admin est active.
if (process.env.NODE_ENV !== 'production') {
  app.get('/api/diagnostic', async (req, res) => {
    const { supabaseAdmin, supabase: supabaseAnon } = require('./config/supabase');
    const sb = supabaseAdmin || supabaseAnon;
    const results = {
      client: supabaseAdmin ? 'admin (service key)' : 'anon (PAS de service key !)',
      tests: {},
    };

    // Test chaque table
    const tables = ['quartiers', 'pharmacies', 'medicaments', 'stocks'];
    for (const table of tables) {
      try {
        const { data, error, count } = await sb.from(table).select('*', { count: 'exact' }).limit(1);
        results.tests[table] = error
          ? { ok: false, error: error.message }
          : { ok: true, count, sample: data && data[0] ? Object.keys(data[0]) : [] };
      } catch (e) {
        results.tests[table] = { ok: false, error: e.message };
      }
    }

    // Test quartier → pharmacies flow
    try {
      const { data: q } = await sb.from('quartiers').select('id, slug').limit(1).single();
      if (q) {
        const { data: p, error: pe, count } = await sb
          .from('pharmacies')
          .select('id, nom', { count: 'exact' })
          .eq('quartier_id', q.id);
        results.tests['quartier→pharmacies'] = pe
          ? { ok: false, quartier: q.slug, error: pe.message }
          : { ok: true, quartier: q.slug, pharmacies_count: count };
      }
    } catch (e) {
      results.tests['quartier→pharmacies'] = { ok: false, error: e.message };
    }

    res.json(results);
  });
}

// ── 404 ───────────────────────────────────────────────
app.use('/api/*', (req, res) => {
  res.status(404).json({ error: 'Route non trouvée' });
});

// ── Error handler ─────────────────────────────────────
app.use(errorHandler);

// ── Démarrage ─────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`🏥 N'Gola Pharma API démarrée sur le port ${PORT}`);
  console.log(`   Environnement : ${process.env.NODE_ENV || 'development'}`);
});

module.exports = app;
