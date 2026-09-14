const { createClient } = require('@supabase/supabase-js');

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseAnonKey = process.env.SUPABASE_ANON_KEY;
const supabaseServiceKey = process.env.SUPABASE_SERVICE_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
  console.error('❌ SUPABASE_URL et SUPABASE_ANON_KEY sont requis');
  process.exit(1);
}

// Client public (respecte les RLS policies)
const supabase = createClient(supabaseUrl, supabaseAnonKey);

// Client admin (contourne les RLS — pour le seed et les opérations serveur)
const supabaseAdmin = supabaseServiceKey
  ? createClient(supabaseUrl, supabaseServiceKey)
  : null;

// Log au démarrage pour diagnostiquer
if (supabaseAdmin) {
  console.log('✅ Client Supabase Admin (service key) actif — RLS contourné');
} else {
  console.warn('⚠️  Pas de SUPABASE_SERVICE_KEY — utilisation du client anon (RLS actif !)');
  console.warn('   Ajoutez SUPABASE_SERVICE_KEY dans votre fichier .env');
}

module.exports = { supabase, supabaseAdmin };
