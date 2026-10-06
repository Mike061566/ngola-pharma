// Edge Function `inviter-pharmacie` (console admin) : POST JSON { pharmacie_id } + Authorization: Bearer <session admin>.
// Envoie au titulaire (email de l'identité enregistrée) un lien d'activation de 72 h pour une pharmacie VÉRIFIÉE. verify_jwt = false : jeton vérifié dans le code.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { creerMagasinOnboarding } from '../_shared/magasin-onboarding.js';
import { cleDepuisBase64 } from '../_shared/chiffrement.js';
import { inviterPharmacie } from '../_shared/invitation-pharmacie.js';
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
    const r = await inviterPharmacie({ jwt, corps }, { magasin: creerMagasinOnboarding(sb), cle: await cleDepuisBase64(Deno.env.get('ENCRYPTION_KEY')),
      env: { APP_BASE_URL: Deno.env.get('APP_BASE_URL') }, journal: (e) => console.log(JSON.stringify(e)) });
    return rep(r.status, r.corps);
  } catch (e) {
    console.error(JSON.stringify({ evt: 'erreur_inviter_pharmacie', erreur: e?.name || 'inconnue' }));
    return rep(500, { erreur: 'erreur_interne' });
  }
});
