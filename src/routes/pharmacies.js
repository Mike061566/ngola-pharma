const { Router } = require('express');
const { supabaseAdmin, supabase: supabaseAnon } = require('../config/supabase');
const supabase = supabaseAdmin || supabaseAnon;

const router = Router();

/**
 * GET /api/pharmacies
 * Liste des pharmacies avec filtres optionnels.
 */
router.get('/', async (req, res, next) => {
  try {
    const {
      quartier,
      statut,
      garde,
      q,
      page = 1,
      limit = 20,
    } = req.query;

    const pageNum = Math.max(1, parseInt(page, 10) || 1);
    const limitNum = Math.min(50, Math.max(1, parseInt(limit, 10) || 20));
    const from = (pageNum - 1) * limitNum;
    const to = from + limitNum - 1;

    let query = supabase
      .from('pharmacies')
      .select('*', { count: 'exact' });

    // Filtres
    if (quartier) {
      const { data: qData } = await supabase
        .from('quartiers')
        .select('id')
        .eq('slug', quartier)
        .single();

      if (qData) {
        query = query.eq('quartier_id', qData.id);
      } else {
        return res.json({ data: [], total: 0, page: pageNum, limit: limitNum });
      }
    }

    if (statut) {
      query = query.eq('statut', statut);
    }

    if (garde === 'true') {
      query = query.eq('est_de_garde', true);
    }

    if (q) {
      query = query.ilike('nom', `%${q}%`);
    }

    query = query.order('nom').range(from, to);

    const { data, error, count } = await query;

    if (error) throw error;

    // Enrichir avec les noms de quartier
    if (data && data.length > 0) {
      const quartierIds = [...new Set(data.map(p => p.quartier_id))];
      const { data: quartiers } = await supabase
        .from('quartiers')
        .select('id, nom, slug')
        .in('id', quartierIds);

      const quartierMap = {};
      if (quartiers) {
        quartiers.forEach(q => { quartierMap[q.id] = q; });
      }

      data.forEach(p => {
        const q = quartierMap[p.quartier_id] || null;
        p.quartier = q;
        p.quartier_nom = q ? q.nom : null;
        p.quartier_slug = q ? q.slug : null;
      });
    }

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
 * GET /api/pharmacies/proches
 */
router.get('/proches', async (req, res, next) => {
  try {
    const { lat, lng, rayon = 2000, limit = 10 } = req.query;

    if (!lat || !lng) {
      return res.status(400).json({ error: 'Paramètres lat et lng requis' });
    }

    const { data, error } = await supabase.rpc('pharmacies_proches', {
      lat: parseFloat(lat),
      lng: parseFloat(lng),
      rayon_m: parseInt(rayon, 10),
    });

    if (error) throw error;

    const limited = data.slice(0, parseInt(limit, 10));
    res.json(limited);
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/pharmacies/:id
 * Détail d'une pharmacie avec son stock.
 */
router.get('/:id', async (req, res, next) => {
  try {
    // Récupérer la pharmacie
    const { data: pharmacie, error } = await supabase
      .from('pharmacies')
      .select('*')
      .eq('id', req.params.id)
      .single();

    if (error || !pharmacie) {
      return res.status(404).json({ error: 'Pharmacie non trouvée' });
    }

    // Récupérer le quartier
    const { data: quartier } = await supabase
      .from('quartiers')
      .select('nom, slug')
      .eq('id', pharmacie.quartier_id)
      .single();

    pharmacie.quartier = quartier;

    // Récupérer les stocks
    const { data: stocks } = await supabase
      .from('stocks')
      .select('id, prix_fcfa, en_stock, date_maj, medicament_id')
      .eq('pharmacie_id', req.params.id);

    // Enrichir les stocks avec les médicaments
    if (stocks && stocks.length > 0) {
      const medIds = stocks.map(s => s.medicament_id);
      const { data: meds } = await supabase
        .from('medicaments')
        .select('id, nom, nom_commercial, dci, forme, dosage, categorie')
        .in('id', medIds);

      const medMap = {};
      if (meds) {
        meds.forEach(m => { medMap[m.id] = m; });
      }

      stocks.forEach(s => {
        s.medicament = medMap[s.medicament_id] || null;
      });
    }

    pharmacie.stocks = stocks || [];

    res.json(pharmacie);
  } catch (err) {
    next(err);
  }
});

module.exports = router;
