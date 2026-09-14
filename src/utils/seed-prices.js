/**
 * Seed prix & stocks — Enrichit la base avec des prix réalistes
 * pour la comparaison et les offres exclusives.
 *
 * Usage : node src/utils/seed-prices.js
 */
require('dotenv').config();
const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

// Prix de référence réalistes en FCFA par médicament (nom partiel → prix moyen)
const PRIX_REF = {
  'Paracétamol 500':   { min: 500,  max: 1500 },
  'Paracétamol 1000':  { min: 800,  max: 2000 },
  'Ibuprofène':        { min: 1000, max: 2500 },
  'Aspirine':          { min: 600,  max: 1500 },
  'Amoxicilline':      { min: 2000, max: 4500 },
  'Métronidazole':     { min: 1500, max: 3500 },
  'Coartem':           { min: 3000, max: 6000 },
  'Quinine':           { min: 2500, max: 5000 },
  'Oméprazole':        { min: 1500, max: 3500 },
  'Métformine':        { min: 2000, max: 4000 },
  'Vitamine C':        { min: 1000, max: 2500 },
  'Multivitamines':    { min: 2500, max: 5000 },
  'Chloroquine':       { min: 1200, max: 2800 },
  'Diclofénac':        { min: 1200, max: 3000 },
  'Cotrimoxazole':     { min: 1800, max: 4000 },
  'Cétirizine':        { min: 1500, max: 3500 },
  'Lopéramide':        { min: 2000, max: 4500 },
  'Salbutamol':        { min: 3500, max: 7000 },
  'Fer':               { min: 2000, max: 4000 },
  'Ciprofloxacine':    { min: 2500, max: 5500 },
};

function getPrixRange(nomMed) {
  for (const [key, range] of Object.entries(PRIX_REF)) {
    if (nomMed.includes(key)) return range;
  }
  return { min: 1000, max: 3000 };
}

function randomPrice(min, max) {
  // Arrondi à 25 FCFA
  return Math.round((min + Math.random() * (max - min)) / 25) * 25;
}

async function main() {
  console.log('💰 Seed prix et stocks — Début\n');

  // 1. Récupérer toutes les pharmacies et médicaments
  const { data: pharmacies, error: pe } = await supabase
    .from('pharmacies').select('id, nom').order('nom');
  if (pe) { console.error('Pharmacies:', pe.message); process.exit(1); }

  const { data: medicaments, error: me } = await supabase
    .from('medicaments').select('id, nom').order('nom');
  if (me) { console.error('Médicaments:', me.message); process.exit(1); }

  console.log(`  ${pharmacies.length} pharmacies, ${medicaments.length} médicaments\n`);

  // 2. Générer des stocks : chaque pharmacie a 60-90% des médicaments
  const stocks = [];
  pharmacies.forEach(p => {
    medicaments.forEach(m => {
      // 75% de chance qu'une pharmacie ait ce médicament
      if (Math.random() > 0.75) return;

      const range = getPrixRange(m.nom);
      stocks.push({
        pharmacie_id: p.id,
        medicament_id: m.id,
        prix_fcfa: randomPrice(range.min, range.max),
        en_stock: Math.random() > 0.1, // 90% en stock
        source: 'admin',
      });
    });
  });

  console.log(`📦 Insertion de ${stocks.length} stocks…`);

  // Insérer par lots de 200
  for (let i = 0; i < stocks.length; i += 200) {
    const batch = stocks.slice(i, i + 200);
    const { error } = await supabase
      .from('stocks')
      .upsert(batch, { onConflict: 'pharmacie_id,medicament_id' });
    if (error) {
      console.error(`  ❌ Lot ${i}: ${error.message}`);
    } else {
      process.stdout.write(`  ✅ ${Math.min(i + 200, stocks.length)}/${stocks.length}\r`);
    }
  }

  // 3. Marquer quelques pharmacies de garde
  const gardePharmacies = pharmacies
    .sort(() => Math.random() - 0.5)
    .slice(0, Math.min(5, pharmacies.length));

  for (const p of gardePharmacies) {
    await supabase.from('pharmacies')
      .update({ est_de_garde: true })
      .eq('id', p.id);
  }
  console.log(`\n🌙 ${gardePharmacies.length} pharmacies de garde : ${gardePharmacies.map(p => p.nom).join(', ')}`);

  // 4. Vérification
  const { count } = await supabase.from('stocks').select('*', { count: 'exact', head: true });
  console.log(`\n✅ Seed terminé — ${count} stocks en base`);
}

main().catch(err => {
  console.error('❌', err.message);
  process.exit(1);
});
