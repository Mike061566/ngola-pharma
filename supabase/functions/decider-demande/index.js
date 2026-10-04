// Edge Function `decider-demande` (console admin) : POST JSON { demande_id, decision: approve|reject|request_info|resend_invite, motif? }
// avec l'en-tête Authorization: Bearer <jeton de la session admin>. verify_jwt = false : le jeton est vérifié dans le code (rôle admin en base).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { creerMagasinOnboarding } from '../_shared/magasin-onboarding.js';
import { cleDepuisBase64 } from '../_shared/chiffrement.js';
import { deciderDemande } from '../_shared/decision-demande.js';
import { enTetesCors } from '../_shared/http.js';

Deno.serve(async (req) => {
  const cors = enTetesCors(req, Deno.env.get('ALLOWED_ORIGINS'));
  const rep = (status, corps) => new Response(JSON.stringify(corps), { status, headers: { 'content-type': 'application/json', ...cors } });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') return rep(405, { erreur: 'methode_non_autorisee' });
  let corps;
  try { corps = JSON.parse(await req.text()); } catch { return rep(400, { erreur: 'corps_invalide' }); }
  const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '') || null;
  try {
    const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
    const r = await deciderDemande({ jwt, corps }, {
      magasin: creerMagasinOnboarding(sb), cle: await cleDepuisBase64(Deno.env.get('ENCRYPTION_KEY')),
      env: { APP_BASE_URL: Deno.env.get('APP_BASE_URL') }, journal: (e) => console.log(JSON.stringify(e)) });
    return rep(r.status, r.corps);
  } catch (e) {
    console.error(JSON.stringify({ evt: 'erreur_decider_demande', erreur: e?.name || 'inconnue' }));
    return rep(500, { erreur: 'erreur_interne' });
  }
});
