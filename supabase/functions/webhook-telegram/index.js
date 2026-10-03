// Edge Function `webhook-telegram` (SPEC 2 §5, §6.1) : reçoit les mises à jour du bot (setWebhook avec secret_token, PR 7).
// Rejette tout appel sans le bon en-tête X-Telegram-Bot-Api-Secret-Token (TELEGRAM_WEBHOOK_SECRET). Répond 200 à toute mise à jour
// authentifiée (même ignorée) pour éviter les rejeux en boucle de Telegram ; 500 seulement en cas de panne d'infrastructure.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { creerMagasinAlertes } from '../_shared/magasin-alertes.js';
import { cleDepuisBase64 } from '../_shared/chiffrement.js';
import { creerFournisseurs } from '../_shared/fournisseurs.js';
import { egalConstante } from '../_shared/securite.js';
import { traiterMiseAJour } from '../_shared/reponses.js';

const json = (corps, status = 200) => new Response(JSON.stringify(corps), { status, headers: { 'content-type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ erreur: 'méthode non autorisée' }, 405);
  if (!(await egalConstante(req.headers.get('x-telegram-bot-api-secret-token') || '', Deno.env.get('TELEGRAM_WEBHOOK_SECRET') || ''))) {
    console.log(JSON.stringify({ evt: 'webhook_refuse' }));
    return json({ erreur: 'non autorisé' }, 401);
  }
  if (Number(req.headers.get('content-length') || 0) > 65536) return json({ ok: true });
  let update;
  try { update = JSON.parse(await req.text()); } catch { return json({ ok: true }); }
  try {
    const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
    const magasin = creerMagasinAlertes(sb);
    const journal = (e) => console.log(JSON.stringify(e));
    const fournisseurs = creerFournisseurs({ TELEGRAM_PROVIDER: Deno.env.get('TELEGRAM_PROVIDER'), SMS_PROVIDER: Deno.env.get('SMS_PROVIDER'), EMAIL_PROVIDER: Deno.env.get('EMAIL_PROVIDER') }, { journal });
    await traiterMiseAJour(update, {
      magasin, cle: await cleDepuisBase64(Deno.env.get('ENCRYPTION_KEY')), fournisseur: fournisseurs.telegram,
      env: { SIGNING_SECRET: Deno.env.get('SIGNING_SECRET') }, config: await magasin.lireConfig(), journal,
    });
    return json({ ok: true });
  } catch (e) {
    console.error(JSON.stringify({ evt: 'erreur_webhook', erreur: e?.name || 'inconnue' }));
    return json({ erreur: 'échec du traitement' }, 500);
  }
});
