// Edge Function publique `repondre-lien` (SPEC 2 §5.2, page /r/<code>) : GET ?code= (informations, sans donnée patient) et
// POST { code, reponse, prix? } (réponse idempotente). Le code (10 caractères aléatoires, secret) n'est valable que jusqu'à
// l'expiration de l'alerte. Aucune connexion requise.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { creerMagasinAlertes } from '../_shared/magasin-alertes.js';
import { creerFournisseurs } from '../_shared/fournisseurs.js';
import { traiterLien } from '../_shared/reponses.js';
import { enTetesCors } from '../_shared/http.js';

Deno.serve(async (req) => {
  const cors = enTetesCors(req, Deno.env.get('ALLOWED_ORIGINS'));
  const rep = (status, corps) => new Response(JSON.stringify(corps), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store', ...cors } });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'GET' && req.method !== 'POST') return rep(405, { erreur: 'methode_non_autorisee' });
  let entree;
  if (req.method === 'GET') entree = { code: new URL(req.url).searchParams.get('code') };
  else {
    if (Number(req.headers.get('content-length') || 0) > 1024) return rep(413, { erreur: 'corps_trop_grand' });
    try { entree = JSON.parse(await req.text()); } catch { return rep(400, { erreur: 'corps_invalide' }); }
    if (!entree || typeof entree !== 'object') return rep(400, { erreur: 'corps_invalide' });
  }
  try {
    const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
    const magasin = creerMagasinAlertes(sb);
    const journal = (e) => console.log(JSON.stringify(e));
    const fournisseurs = creerFournisseurs({ TELEGRAM_PROVIDER: Deno.env.get('TELEGRAM_PROVIDER'), TELEGRAM_BOT_TOKEN: Deno.env.get('TELEGRAM_BOT_TOKEN') }, { journal });
    const r = await traiterLien(req.method, entree, { magasin, fournisseur: fournisseurs.telegram, config: await magasin.lireConfig(), journal, maintenant: () => new Date() });
    return rep(r.status, r.corps);
  } catch (e) {
    console.error(JSON.stringify({ evt: 'erreur_lien', erreur: e?.name || 'inconnue' }));
    return rep(500, { erreur: 'erreur_interne' });
  }
});
