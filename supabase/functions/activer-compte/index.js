// Edge Function publique `activer-compte` : POST JSON { jeton } (jeton d'activation de l'email d'approbation, 72 h, usage unique).
// Répond { lien_connexion } : lien Supabase court vers l'Espace Pro. Redirections autorisées à déclarer dans Supabase Auth (voir README).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { creerMagasinOnboarding } from '../_shared/magasin-onboarding.js';
import { activerCompte } from '../_shared/activation-compte.js';
import { enTetesCors } from '../_shared/http.js';

Deno.serve(async (req) => {
  const cors = enTetesCors(req, Deno.env.get('ALLOWED_ORIGINS'));
  const rep = (status, corps) => new Response(JSON.stringify(corps), { status, headers: { 'content-type': 'application/json', ...cors } });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') return rep(405, { erreur: 'methode_non_autorisee' });
  if (Number(req.headers.get('content-length') || 0) > 2048) return rep(413, { erreur: 'corps_trop_grand' });
  let corps;
  try { corps = JSON.parse(await req.text()); } catch { return rep(400, { erreur: 'corps_invalide' }); }
  try {
    const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
    const r = await activerCompte({ jeton: corps?.jeton }, { magasin: creerMagasinOnboarding(sb), env: { APP_BASE_URL: Deno.env.get('APP_BASE_URL') },
      journal: (e) => console.log(JSON.stringify(e)) });
    return rep(r.status, r.corps);
  } catch (e) {
    console.error(JSON.stringify({ evt: 'erreur_activer_compte', erreur: e?.name || 'inconnue' }));
    return rep(500, { erreur: 'erreur_interne' });
  }
});
