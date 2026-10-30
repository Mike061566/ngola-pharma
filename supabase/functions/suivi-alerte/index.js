// Edge Function publique `suivi-alerte` (SPEC 2 §9, GET /alerte/:publicId) : état de suivi, SANS donnée patient et
// sans donnée de pharmacie tant qu'aucune n'a répondu positivement. Appelée en GET ?id=NG-XXXXXXXX (rafraîchie toutes les 15 s).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { creerMagasinAlertes } from '../_shared/magasin-alertes.js';
import { traiterSuivi } from '../_shared/suivi-alerte.js';
import { enTetesCors } from '../_shared/http.js';

Deno.serve(async (req) => {
  const cors = enTetesCors(req, Deno.env.get('ALLOWED_ORIGINS'));
  const rep = (status, corps) => new Response(JSON.stringify(corps), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store', ...cors } });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'GET') return rep(405, { erreur: 'methode_non_autorisee' });
  try {
    const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
    const r = await traiterSuivi(new URL(req.url).searchParams.get('id'), { magasin: creerMagasinAlertes(sb) });
    return rep(r.status, r.corps);
  } catch (e) {
    console.error(JSON.stringify({ evt: 'erreur_suivi', erreur: e?.name || 'inconnue' }));
    return rep(500, { erreur: 'erreur_interne' });
  }
});
