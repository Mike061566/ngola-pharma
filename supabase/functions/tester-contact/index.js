// Edge Function `tester-contact` (SPEC 2 §10, réglage des canaux) : POST { contact_id } avec le jeton de session du pharmacien
// (Authorization: Bearer). Envoie un message de test, via l'outbox, à UN contact de SA pharmacie. 1 test par minute et par contact.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { creerMagasinAlertes } from '../_shared/magasin-alertes.js';
import { cleDepuisBase64 } from '../_shared/chiffrement.js';
import { traiterTestContact } from '../_shared/test-contact.js';
import { enTetesCors } from '../_shared/http.js';

Deno.serve(async (req) => {
  const cors = enTetesCors(req, Deno.env.get('ALLOWED_ORIGINS'));
  const rep = (status, corps) => new Response(JSON.stringify(corps), { status, headers: { 'content-type': 'application/json', ...cors } });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') return rep(405, { erreur: 'methode_non_autorisee' });
  const jeton = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jeton) return rep(401, { erreur: 'non_authentifie' });
  let corps;
  try { corps = JSON.parse(await req.text()); } catch { return rep(400, { erreur: 'corps_invalide' }); }
  try {
    const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
    const { data, error } = await sb.auth.getUser(jeton);           // le jeton est vérifié par Supabase Auth
    if (error || !data?.user) return rep(401, { erreur: 'non_authentifie' });
    const r = await traiterTestContact({ contactId: corps?.contact_id, utilisateurId: data.user.id },
      { magasin: creerMagasinAlertes(sb), cle: await cleDepuisBase64(Deno.env.get('ENCRYPTION_KEY')) });
    return rep(r.status, r.corps);
  } catch (e) {
    console.error(JSON.stringify({ evt: 'erreur_test_contact', erreur: e?.name || 'inconnue' }));
    return rep(500, { erreur: 'erreur_interne' });
  }
});
