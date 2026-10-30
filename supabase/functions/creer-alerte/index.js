// Edge Function publique `creer-alerte` (SPEC 2 §3) : POST JSON. Aucun jeton Supabase (verify_jwt = false) ; la
// protection est : feature flag ALERT_AUTO_ROUTING, captcha, liste blanche de champs, limite de 5 alertes/jour par
// numéro et par IP (fonction SQL atomique), liste de blocage. Variables d'environnement : voir creation-alerte.js.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { creerMagasinAlertes } from '../_shared/magasin-alertes.js';
import { cleDepuisBase64 } from '../_shared/chiffrement.js';
import { traiterCreation } from '../_shared/creation-alerte.js';
import { enTetesCors, ipClient } from '../_shared/http.js';

Deno.serve(async (req) => {
  const cors = enTetesCors(req, Deno.env.get('ALLOWED_ORIGINS'));
  const rep = (status, corps) => new Response(JSON.stringify(corps), { status, headers: { 'content-type': 'application/json', ...cors } });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') return rep(405, { erreur: 'methode_non_autorisee' });
  if (Number(req.headers.get('content-length') || 0) > 4096) return rep(413, { erreur: 'corps_trop_grand' });
  let corps;
  try { corps = JSON.parse(await req.text()); } catch { return rep(400, { erreur: 'corps_invalide', message: 'Requête invalide.' }); }
  try {
    const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
    const r = await traiterCreation(corps, {
      env: Object.fromEntries(['ALERT_AUTO_ROUTING', 'CAPTCHA_PROVIDER', 'CAPTCHA_SECRET', 'SIGNING_SECRET', 'TELEGRAM_BOT_USERNAME', 'APP_BASE_URL']
        .map((k) => [k, Deno.env.get(k)])),
      ip: ipClient(req.headers), magasin: creerMagasinAlertes(sb), cle: await cleDepuisBase64(Deno.env.get('ENCRYPTION_KEY')),
      journal: (e) => console.log(JSON.stringify(e)),
    });
    return rep(r.status, r.corps);
  } catch (e) {
    console.error(JSON.stringify({ evt: 'erreur_creer_alerte', erreur: e?.name || 'inconnue' }));
    return rep(500, { erreur: 'erreur_interne', message: 'Une erreur est survenue. Réessayez.' });
  }
});
