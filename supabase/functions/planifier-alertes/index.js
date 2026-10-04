// Edge Function `planifier-alertes` : appelée chaque minute par pg_cron/pg_net (supabase/ops/planifier_alertes.sql) avec
// l'en-tête `x-cron-secret`. Exécute les décisions du moteur de routage (vagues, escalade, expiration, agrégation, relances).
// Variables d'environnement : CRON_SECRET, ENCRYPTION_KEY, ALERT_AUTO_ROUTING, APP_BASE_URL, ADMIN_ALERT_EMAIL (facultatif).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { creerMagasinAlertes } from '../_shared/magasin-alertes.js';
import { cleDepuisBase64 } from '../_shared/chiffrement.js';
import { planifierAlertes } from '../_shared/planificateur.js';
import { egalConstante } from '../_shared/securite.js';

const json = (corps, status = 200) => new Response(JSON.stringify(corps), { status, headers: { 'content-type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ erreur: 'méthode non autorisée' }, 405);
  if (!(await egalConstante(req.headers.get('x-cron-secret') || '', Deno.env.get('CRON_SECRET') || ''))) return json({ erreur: 'non autorisé' }, 401);
  try {
    const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
    const resume = await planifierAlertes({
      magasin: creerMagasinAlertes(sb), cle: await cleDepuisBase64(Deno.env.get('ENCRYPTION_KEY')),
      env: Object.fromEntries(['ALERT_AUTO_ROUTING', 'APP_BASE_URL', 'ADMIN_ALERT_EMAIL'].map((k) => [k, Deno.env.get(k)])),
      journal: (e) => console.log(JSON.stringify(e)),
    });
    return json(resume);
  } catch (e) {
    console.error(JSON.stringify({ evt: 'erreur_planificateur', erreur: e?.name || 'inconnue' }));
    return json({ erreur: 'échec du traitement' }, 500);
  }
});
