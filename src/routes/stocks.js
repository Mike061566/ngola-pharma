const { Router } = require('express');
const { supabaseAdmin, supabase: supabaseAnon } = require('../config/supabase');
const supabase = supabaseAdmin || supabaseAnon;

const router = Router();

/**
 * GET /api/stocks
 * Recherche dans les stocks.
 */
router.get('/', async (req, res, next) => {
  try {
    const {
      medicament,
      pharmacie_id,
      en_stock = 'true',
      tri = 'prix',
      page = 1,
      limit = 20,
    } = req.query;

    const pageNum = Math.max(1, parseInt(page, 10) || 1);
    const limitNum = Math.min(50, Math.max(1, parseInt(limit, 10) || 20));
    const from = (pageNum - 1) * limitNum;
    const to = from + limitNum - 1;

    let query = supabase
      .from('stocks')
      .select('*', { count: 'exact' });

    if (en_stock === 'true') {
      query = query.eq('en_stock', true);
    }

    if (pharmacie_id) {
      query = query.eq('pharmacie_id', pharmacie_id);
    }

    if (medicament) {
      const { data: meds } = await supabase
        .from('medicaments')
        .select('id')
        .or(`nom.ilike.%${medicament}%,dci.ilike.%${medicament}%,nom_commercial.ilike.%${medicament}%,categorie.ilike.%${medicament}%`);

      if (!meds || meds.length === 0) {
        return res.json({ data: [], total: 0, page: pageNum, limit: limitNum, pages: 0 });
      }

      const medIds = meds.map(m => m.id);
      query = query.in('medicament_id', medIds);
    }

    if (tri === 'prix') {
      query = query.order('prix_fcfa', { ascending: true });
    } else if (tri === 'date') {
      query = query.order('date_maj', { ascending: false });
    }

    query = query.range(from, to);

    const { data, error, count } = await query;

    if (error) throw error;

    // Enrichir avec pharmacie et médicament
    if (data && data.length > 0) {
      const pharmIds = [...new Set(data.map(s => s.pharmacie_id))];
      const medIds = [...new Set(data.map(s => s.medicament_id))];

      const [pharmRes, medRes, quartRes] = await Promise.all([
        supabase.from('pharmacies').select('id, nom, adresse, telephone, quartier_id').in('id', pharmIds),
        supabase.from('medicaments').select('id, nom, nom_commercial, dci, forme, dosage').in('id', medIds),
        supabase.from('quartiers').select('id, nom, slug'),
      ]);

      const quartierMap = {};
      if (quartRes.data) {
        quartRes.data.forEach(q => { quartierMap[q.id] = q; });
      }

      const pharmMap = {};
      if (pharmRes.data) {
        pharmRes.data.forEach(p => {
          p.quartier = quartierMap[p.quartier_id] || null;
          pharmMap[p.id] = p;
        });
      }

      const medMap = {};
      if (medRes.data) {
        medRes.data.forEach(m => { medMap[m.id] = m; });
      }

      data.forEach(s => {
        s.pharmacie = pharmMap[s.pharmacie_id] || null;
        s.medicament = medMap[s.medicament_id] || null;
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
 * GET /api/stocks/meilleurs-prix
 * Retourne le meilleur prix (le plus bas, en stock) par médicament.
 *
 * Filtres optionnels :
 *   ?dci=paracetamol     — filtre par DCI (recherche partielle)
 *   ?garde=true          — uniquement les pharmacies de garde
 *   ?q=ibupro            — recherche libre sur nom/dci/nom_commercial
 */
router.get('/meilleurs-prix', async (req, res, next) => {
  try {
    const { dci, garde, q } = req.query;

    // 1. Pré-filtrer les pharmacies si garde=true
    let pharmacieIds = null;
    if (garde === 'true') {
      const { data: gardePharms, error: ge } = await supabase
        .from('pharmacies')
        .select('id')
        .eq('est_de_garde', true);
      if (ge) throw ge;
      pharmacieIds = (gardePharms || []).map(p => p.id);
      if (pharmacieIds.length === 0) {
        return res.json({ data: [], filters: { garde: true, dci: dci || null } });
      }
    }

    // 2. Pré-filtrer les médicaments si dci ou q
    let medicamentIds = null;
    if (dci || q) {
      let medQuery = supabase.from('medicaments').select('id');
      if (dci) {
        medQuery = medQuery.ilike('dci', `%${dci}%`);
      }
      if (q) {
        medQuery = medQuery.or(`nom.ilike.%${q}%,dci.ilike.%${q}%,nom_commercial.ilike.%${q}%,categorie.ilike.%${q}%`);
      }
      const { data: filteredMeds, error: me } = await medQuery;
      if (me) throw me;
      medicamentIds = (filteredMeds || []).map(m => m.id);
      if (medicamentIds.length === 0) {
        return res.json({ data: [], filters: { garde: garde === 'true', dci: dci || null, q: q || null } });
      }
    }

    // 3. Récupérer les stocks en stock, triés par prix
    let stockQuery = supabase
      .from('stocks')
      .select('id, prix_fcfa, pharmacie_id, medicament_id')
      .eq('en_stock', true)
      .order('prix_fcfa', { ascending: true });

    if (pharmacieIds) {
      stockQuery = stockQuery.in('pharmacie_id', pharmacieIds);
    }
    if (medicamentIds) {
      stockQuery = stockQuery.in('medicament_id', medicamentIds);
    }

    const { data: stocks, error } = await stockQuery;
    if (error) throw error;

    // 4. Garder le meilleur prix par médicament
    const bestByMed = {};
    (stocks || []).forEach(s => {
      if (!bestByMed[s.medicament_id]) {
        bestByMed[s.medicament_id] = s;
      }
    });
    const bestList = Object.values(bestByMed);

    if (bestList.length === 0) {
      return res.json({ data: [], filters: { garde: garde === 'true', dci: dci || null, q: q || null } });
    }

    // 5. Enrichir avec médicaments, pharmacies, quartiers
    const medIds = [...new Set(bestList.map(s => s.medicament_id))];
    const pharmIds = [...new Set(bestList.map(s => s.pharmacie_id))];

    const [medRes, pharmRes, quartRes] = await Promise.all([
      supabase.from('medicaments').select('id, nom, dci, forme, dosage').in('id', medIds),
      supabase.from('pharmacies').select('id, nom, quartier_id, est_de_garde').in('id', pharmIds),
      supabase.from('quartiers').select('id, nom'),
    ]);

    const medMap = {};
    if (medRes.data) medRes.data.forEach(m => { medMap[m.id] = m; });

    const quartierMap = {};
    if (quartRes.data) quartRes.data.forEach(q => { quartierMap[q.id] = q; });

    const pharmMap = {};
    if (pharmRes.data) pharmRes.data.forEach(p => {
      p.quartier_nom = quartierMap[p.quartier_id] ? quartierMap[p.quartier_id].nom : '';
      pharmMap[p.id] = p;
    });

    // 6. Construire la réponse
    const result = bestList.map(s => {
      const med = medMap[s.medicament_id] || {};
      const pharm = pharmMap[s.pharmacie_id] || {};
      return {
        medicament_id: s.medicament_id,
        medicament_nom: med.nom || '',
        dci: med.dci || '',
        forme: med.forme || '',
        dosage: med.dosage || '',
        prix_fcfa: s.prix_fcfa,
        pharmacie_id: s.pharmacie_id,
        pharmacie_nom: pharm.nom || '',
        quartier_nom: pharm.quartier_nom || '',
        est_de_garde: pharm.est_de_garde || false,
      };
    }).sort((a, b) => a.medicament_nom.localeCompare(b.medicament_nom));

    res.json({
      data: result,
      filters: { garde: garde === 'true', dci: dci || null, q: q || null },
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
