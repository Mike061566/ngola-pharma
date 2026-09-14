const { Router } = require('express');
const { supabaseAdmin, supabase: supabaseAnon } = require('../config/supabase');
const supabase = supabaseAdmin || supabaseAnon;

const router = Router();

/**
 * GET /api/medicaments
 * Liste des médicaments avec filtres.
 */
router.get('/', async (req, res, next) => {
  try {
    const {
      q,
      categorie,
      ordonnance,
      page = 1,
      limit = 20,
    } = req.query;

    const pageNum = Math.max(1, parseInt(page, 10) || 1);
    const limitNum = Math.min(50, Math.max(1, parseInt(limit, 10) || 20));
    const from = (pageNum - 1) * limitNum;
    const to = from + limitNum - 1;

    let query = supabase
      .from('medicaments')
      .select('*', { count: 'exact' });

    if (q) {
      query = query.or(`nom.ilike.%${q}%,dci.ilike.%${q}%,nom_commercial.ilike.%${q}%,categorie.ilike.%${q}%`);
    }

    if (categorie) {
      query = query.eq('categorie', categorie);
    }

    if (ordonnance !== undefined) {
      query = query.eq('ordonnance', ordonnance === 'true');
    }

    query = query.order('nom').range(from, to);

    const { data, error, count } = await query;

    if (error) throw error;

    res.json({
      data,
      total: count,
      page: pageNum,
      limit: limitNum,
      pages: Math.ceil((count || 0) / limitNum),
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/medicaments/categories
 */
router.get('/categories', async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('medicaments')
      .select('categorie')
      .order('categorie');

    if (error) throw error;

    const categories = [...new Set(data.map(d => d.categorie))].filter(Boolean);
    res.json(categories);
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/medicaments/dci
 * Liste distincte des DCI disponibles (pour dropdown/filtre).
 */
router.get('/dci', async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('medicaments')
      .select('dci')
      .order('dci');

    if (error) throw error;

    const dciList = [...new Set((data || []).map(d => d.dci).filter(Boolean))];
    res.json(dciList);
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/medicaments/:id
 * Détail d'un médicament + où le trouver.
 */
router.get('/:id', async (req, res, next) => {
  try {
    const { data: medicament, error } = await supabase
      .from('medicaments')
      .select('*')
      .eq('id', req.params.id)
      .single();

    if (error || !medicament) {
      return res.status(404).json({ error: 'Médicament non trouvé' });
    }

    // Stocks avec pharmacie info (requêtes séparées)
    const { data: stocks } = await supabase
      .from('stocks')
      .select('prix_fcfa, en_stock, date_maj, pharmacie_id')
      .eq('medicament_id', req.params.id)
      .eq('en_stock', true)
      .order('prix_fcfa');

    // Enrichir avec les pharmacies
    const disponibilite = [];
    if (stocks && stocks.length > 0) {
      const pharmIds = stocks.map(s => s.pharmacie_id);
      const { data: pharmacies } = await supabase
        .from('pharmacies')
        .select('id, nom, adresse, telephone, latitude, longitude, statut, quartier_id')
        .in('id', pharmIds);

      // Récupérer les quartiers
      const quartierIds = [...new Set((pharmacies || []).map(p => p.quartier_id))];
      const { data: quartiers } = await supabase
        .from('quartiers')
        .select('id, nom, slug')
        .in('id', quartierIds);

      const quartierMap = {};
      if (quartiers) {
        quartiers.forEach(q => { quartierMap[q.id] = q; });
      }

      const pharmMap = {};
      if (pharmacies) {
        pharmacies.forEach(p => {
          p.quartier = quartierMap[p.quartier_id] || null;
          pharmMap[p.id] = p;
        });
      }

      stocks.forEach(s => {
        disponibilite.push({
          prix_fcfa: s.prix_fcfa,
          en_stock: s.en_stock,
          date_maj: s.date_maj,
          pharmacie: pharmMap[s.pharmacie_id] || null,
        });
      });
    }

    res.json({ ...medicament, disponibilite });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
