// Edge Function `traiter-outbox` : traite l'outbox de notifications (PR 2). Appelée chaque minute par pg_cron/pg_net
// (voir supabase/ops/planifier_outbox.sql) avec l'en-tête `x-cron-secret`.
// Variables d'environnement (jamais dans le dépôt) : CRON_SECRET, ENCRYPTION_KEY, SUPABASE_URL,
// SUPABASE_SERVICE_ROLE_KEY (fournies par Supabase), TELEGRAM_PROVIDER / SMS_PROVIDER / EMAIL_PROVIDER (défaut : mock).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { traiterOutbox } from '../_shared/traitement.js';
import { creerMagasinSupabase } from '../_shared/magasin-supabase.js';
import { creerFournisseurs } from '../_shared/fournisseurs.js';
import { cleDepuisBase64 } from '../_shared/chiffrement.js';
import { egalConstante } from '../_shared/securite.js';

const json = (corps, status = 200) => new Response(JSON.stringify(corps), { status, headers: { 'content-type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ erreur: 'méthode non autorisée' }, 405);
  if (!(await egalConstante(req.headers.get('x-cron-secret') || '', Deno.env.get('CRON_SECRET') || ''))) {
    return json({ erreur: 'non autorisé' }, 401);
  }
  try {
    const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
      { auth: { persistSession: false } });
    const resume = await traiterOutbox({
      magasin: creerMagasinSupabase(sb),
      fournisseurs: creerFournisseurs({
        TELEGRAM_PROVIDER: Deno.env.get('TELEGRAM_PROVIDER'),
        SMS_PROVIDER: Deno.env.get('SMS_PROVIDER'),
        EMAIL_PROVIDER: Deno.env.get('EMAIL_PROVIDER'),
      }, { journal: (e) => console.log(JSON.stringify(e)) }),
      cle: await cleDepuisBase64(Deno.env.get('ENCRYPTION_KEY')),
      journal: (e) => console.log(JSON.stringify(e)),
    });
    return json(resume);
  } catch (e) {
    console.error(JSON.stringify({ evt: 'erreur_worker', erreur: e?.name || 'inconnue' }));
    return json({ erreur: 'échec du traitement' }, 500);
  }
});
