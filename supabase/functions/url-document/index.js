// Edge Function `url-document` (console admin) : POST JSON { document_id } + Authorization: Bearer <session admin>.
// Renvoie une URL signée de 5 minutes d'un justificatif (bucket privé : jamais d'URL publique). L'accès est journalisé.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { creerMagasinOnboarding } from '../_shared/magasin-onboarding.js';
import { enTetesCors } from '../_shared/http.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
    const magasin = creerMagasinOnboarding(sb);
    const user = jwt ? await magasin.utilisateurDuJeton(jwt) : null;
    if (!user || !(await magasin.estAdmin(user.id))) return rep(403, { erreur: 'refuse' });
    if (!UUID.test(corps?.document_id || '')) return rep(400, { erreur: 'requete_invalide' });
    const { data: doc } = await sb.from('documents_demande').select('chemin_stockage, demande_id').eq('id', corps.document_id).maybeSingle();
    if (!doc) return rep(404, { erreur: 'introuvable' });
    await sb.rpc('journaliser_onboarding', { p_demande: doc.demande_id, p_pharmacie: null, p_acteur: user.id, p_type: 'admin', p_evenement: 'document_consulte', p_details: { document_id: corps.document_id } });
    return rep(200, { url: await magasin.urlSignee(doc.chemin_stockage, 300) });
  } catch (e) {
    console.error(JSON.stringify({ evt: 'erreur_url_document', erreur: e?.name || 'inconnue' }));
    return rep(500, { erreur: 'erreur_interne' });
  }
});
