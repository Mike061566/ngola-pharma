// Edge Function publique `repondre-complements` : POST multipart (champs « donnees » = {"jeton": "..."} , « message », fichiers « autre »).
// Le lien signé de l'email « compléments » tient lieu d'authentification (14 jours, usage unique).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { creerMagasinOnboarding } from '../_shared/magasin-onboarding.js';
import { deposerComplements } from '../_shared/activation-compte.js';
import { enTetesCors, lireDemandeMultipart } from '../_shared/http.js';

Deno.serve(async (req) => {
  const cors = enTetesCors(req, Deno.env.get('ALLOWED_ORIGINS'));
  const rep = (status, corps) => new Response(JSON.stringify(corps), { status, headers: { 'content-type': 'application/json', ...cors } });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') return rep(405, { erreur: 'methode_non_autorisee' });
  const entree = await lireDemandeMultipart(req, ['autre']);
  if (entree?.trop_grand) return rep(413, { erreur: 'corps_trop_grand' });
  if (!entree) return rep(400, { erreur: 'corps_invalide' });
  try {
    const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
    const r = await deposerComplements({ jeton: entree.champs?.jeton, message: entree.message, fichiers: entree.fichiers },
      { magasin: creerMagasinOnboarding(sb), journal: (e) => console.log(JSON.stringify(e)) });
    return rep(r.status, r.corps);
  } catch (e) {
    console.error(JSON.stringify({ evt: 'erreur_repondre_complements', erreur: e?.name || 'inconnue' }));
    return rep(500, { erreur: 'erreur_interne' });
  }
});
