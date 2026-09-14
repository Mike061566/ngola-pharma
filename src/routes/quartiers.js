const { Router } = require('express');
const { supabaseAdmin, supabase: supabaseAnon } = require('../config/supabase');
const supabase = supabaseAdmin || supabaseAnon;

const router = Router();

/**
 * GET /api/quartiers
 * Liste tous les quartiers.
 */
router.get('/', async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('quartiers')
      .select('*')
      .order('nom');

    if (error) throw error;
    res.json(data);
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/quartiers/:slug
 * Détail d'un quartier par slug + ses pharmacies.
 */
router.get('/:slug', async (req, res, next) => {
  try {
    const { data: quartier, error } = await supabase
      .from('quartiers')
      .select('*')
      .eq('slug', req.params.slug)
      .single();

    if (error || !quartier) {
      return res.status(404).json({ error: 'Quartier non trouvé' });
    }

    // Récupérer les pharmacies du quartier
    const { data: pharmacies, error: errPharm } = await supabase
      .from('pharmacies')
      .select('id, nom, adresse, telephone, statut, latitude, longitude, horaires, est_de_garde')
      .eq('quartier_id', quartier.id)
      .order('nom');

    if (errPharm) throw errPharm;

    res.json({ ...quartier, pharmacies });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
