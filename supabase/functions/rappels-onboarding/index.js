// Edge Function `rappels-onboarding` : rappels J+1 / J+3 / J+7 aux officines approuvées non publiées, alerte « dormante » à l'admin (SPEC 1 §5.3).
// Appelée UNE FOIS PAR JOUR par pg_cron/pg_net (voir supabase/ops/planifier_rappels_onboarding.sql) avec l'en-tête `x-cron-secret`.
// Variables : CRON_SECRET, ENCRYPTION_KEY, APP_BASE_URL, ADMIN_ALERT_EMAIL (SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY fournies par Supabase).
// Les messages passent par l'outbox : en mode démo, seuls les contacts de la liste blanche reçoivent un vrai message.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { creerMagasinOnboarding } from '../_shared/magasin-onboarding.js';
import { cleDepuisBase64 } from '../_shared/chiffrement.js';
import { egalConstante } from '../_shared/securite.js';
import { executerRappels } from '../_shared/rappels-onboarding.js';

const json = (corps, status = 200) => new Response(JSON.stringify(corps), { status, headers: { 'content-type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ erreur: 'méthode non autorisée' }, 405);
  if (!(await egalConstante(req.headers.get('x-cron-secret') || '', Deno.env.get('CRON_SECRET') || ''))) return json({ erreur: 'non autorisé' }, 401);
  try {
    const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
    const resume = await executerRappels({
      magasin: creerMagasinOnboarding(sb), cle: await cleDepuisBase64(Deno.env.get('ENCRYPTION_KEY')),
      env: { APP_BASE_URL: Deno.env.get('APP_BASE_URL'), ADMIN_ALERT_EMAIL: Deno.env.get('ADMIN_ALERT_EMAIL') },
      journal: (e) => console.log(JSON.stringify(e)),
    });
    return json(resume);
  } catch (e) {
    console.error(JSON.stringify({ evt: 'erreur_rappels_onboarding', erreur: e?.name || 'inconnue' }));
    return json({ erreur: 'échec du traitement' }, 500);
  }
});
