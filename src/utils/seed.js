/**
 * Seed N'Gola Pharma — Importe les CSV dans Supabase.
 *
 * Usage : npm run seed
 * Requiert SUPABASE_URL et SUPABASE_SERVICE_KEY dans .env
 */
require('dotenv').config();

const fs = require('fs');
const path = require('path');
const { createClient } = require('@supabase/supabase-js');

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseServiceKey = process.env.SUPABASE_SERVICE_KEY;

if (!supabaseUrl || !supabaseServiceKey) {
  console.error('❌ SUPABASE_URL et SUPABASE_SERVICE_KEY requis dans .env');
  process.exit(1);
}

const supabase = createClient(supabaseUrl, supabaseServiceKey);

// ── Parse CSV ───────────────────────────────────────────
function parseCSV(filePath) {
  const content = fs.readFileSync(filePath, 'utf-8');
  const lines = content.trim().split('\n');
  const headers = parseCSVLine(lines[0]);

  return lines.slice(1).filter(l => l.trim()).map(line => {
    const values = parseCSVLine(line);
    const obj = {};
    headers.forEach((h, i) => {
      obj[h] = values[i] || null;
    });
    return obj;
  });
}

/**
 * Parse une ligne CSV en gérant les champs entre guillemets
 * (nécessaire pour le JSON des horaires).
 */
function parseCSVLine(line) {
  const result = [];
  let current = '';
  let inQuotes = false;

  for (let i = 0; i < line.length; i++) {
    const char = line[i];
    if (char === '"') {
      if (inQuotes && line[i + 1] === '"') {
        current += '"';
        i++; // skip escaped quote
      } else {
        inQuotes = !inQuotes;
      }
    } else if (char === ',' && !inQuotes) {
      result.push(current.trim());
      current = '';
    } else {
      current += char;
    }
  }
  result.push(current.trim());
  return result;
}

// ── Seed functions ──────────────────────────────────────
async function seedQuartiers() {
  const csvPath = path.join(__dirname, '../../supabase/seed/quartiers.csv');
  const rows = parseCSV(csvPath);

  console.log(`📍 Insertion de ${rows.length} quartiers…`);

  const { data, error } = await supabase
    .from('quartiers')
    .upsert(rows.map(r => ({
      nom: r.nom,
      slug: r.slug,
      description: r.description,
    })), { onConflict: 'slug' })
    .select();

  if (error) throw new Error(`Quartiers: ${error.message}`);
  console.log(`   ✅ ${data.length} quartiers insérés`);
  return data;
}

async function seedPharmacies(quartiers) {
  const csvPath = path.join(__dirname, '../../supabase/seed/pharmacies.csv');
  const rows = parseCSV(csvPath);

  // Mapper les slugs de quartier vers leurs UUIDs
  const quartierMap = {};
  quartiers.forEach(q => { quartierMap[q.slug] = q.id; });

  const pharmacies = rows.map(r => {
    const quartier_id = quartierMap[r.quartier_slug];
    if (!quartier_id) {
      console.warn(`   ⚠️  Quartier "${r.quartier_slug}" non trouvé pour ${r.nom}`);
      return null;
    }

    let horaires = {};
    if (r.horaires && r.horaires !== '{}') {
      try { horaires = JSON.parse(r.horaires); } catch { /* ignore */ }
    }

    return {
      nom: r.nom,
      slug: r.nom.toLowerCase()
        .normalize('NFD').replace(/[̀-ͯ]/g, '')
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/(^-|-$)/g, ''),
      quartier_id,
      adresse: r.adresse,
      latitude: r.latitude ? parseFloat(r.latitude) : null,
      longitude: r.longitude ? parseFloat(r.longitude) : null,
      telephone: r.telephone,
      statut: r.statut || 'non_verifie',
      source: r.source || 'admin',
      horaires,
    };
  }).filter(Boolean);

  console.log(`🏥 Insertion de ${pharmacies.length} pharmacies…`);

  const { data, error } = await supabase
    .from('pharmacies')
    .upsert(pharmacies, { onConflict: 'slug' })
    .select();

  if (error) throw new Error(`Pharmacies: ${error.message}`);
  console.log(`   ✅ ${data.length} pharmacies insérées`);
  return data;
}

async function seedMedicaments() {
  const csvPath = path.join(__dirname, '../../supabase/seed/medicaments.csv');
  const rows = parseCSV(csvPath);

  const medicaments = rows.map(r => ({
    nom: r.nom,
    nom_commercial: r.nom_commercial,
    dci: r.dci,
    forme: r.forme,
    dosage: r.dosage || null,
    categorie: r.categorie,
    ordonnance: r.ordonnance === 'true',
    description: r.description,
  }));

  console.log(`💊 Insertion de ${medicaments.length} médicaments…`);

  const { data, error } = await supabase
    .from('medicaments')
    .upsert(medicaments, { onConflict: 'nom' })
    .select();

  if (error) throw new Error(`Médicaments: ${error.message}`);
  console.log(`   ✅ ${data.length} médicaments insérés`);
  return data;
}

async function seedDemoStocks(pharmacies, medicaments) {
  // Créer quelques stocks de démo pour les premières pharmacies
  const demoPharmacies = pharmacies.slice(0, 6);
  const demoMedicaments = medicaments.slice(0, 5);

  const stocks = [];
  const basePrices = [500, 1500, 750, 3500, 2000];

  demoPharmacies.forEach(p => {
    demoMedicaments.forEach((m, i) => {
      // Variation de prix ±20%
      const basePrice = basePrices[i] || 1000;
      const variation = 1 + (Math.random() * 0.4 - 0.2);
      const prix = Math.round(basePrice * variation / 25) * 25; // arrondi à 25 FCFA

      stocks.push({
        pharmacie_id: p.id,
        medicament_id: m.id,
        prix_fcfa: prix,
        en_stock: Math.random() > 0.15, // 85% de chance d'être en stock
        source: 'admin',
      });
    });
  });

  console.log(`📦 Insertion de ${stocks.length} stocks de démo…`);

  const { data, error } = await supabase
    .from('stocks')
    .upsert(stocks, { onConflict: 'pharmacie_id,medicament_id' })
    .select();

  if (error) throw new Error(`Stocks: ${error.message}`);
  console.log(`   ✅ ${data.length} stocks insérés`);
}

// ── Main ────────────────────────────────────────────────
async function main() {
  console.log('🌱 Seed N\'Gola Pharma — Début\n');

  try {
    const quartiers = await seedQuartiers();
    const pharmacies = await seedPharmacies(quartiers);
    const medicaments = await seedMedicaments();
    await seedDemoStocks(pharmacies, medicaments);

    console.log('\n✅ Seed terminé avec succès !');
    console.log(`   ${quartiers.length} quartiers`);
    console.log(`   ${pharmacies.length} pharmacies`);
    console.log(`   ${medicaments.length} médicaments`);
  } catch (err) {
    console.error('\n❌ Erreur seed:', err.message);
    process.exit(1);
  }
}

main();
