// Edge Function publique `creer-demande` (SPEC 1 §3) : POST multipart (champ « donnees » JSON + justificatifs). verify_jwt = false ;
// protections : captcha, liste blanche de champs, 3 demandes/jour/IP (fonction SQL atomique), type de fichier vérifié sur les octets.
// Variables : ENCRYPTION_KEY, SIGNING_SECRET, CAPTCHA_PROVIDER, CAPTCHA_SECRET, ALLOWED_ORIGINS, APP_BASE_URL.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { creerMagasinOnboarding } from '../_shared/magasin-onboarding.js';
import { cleDepuisBase64 } from '../_shared/chiffrement.js';
import { traiterDemande, NATURES, reponseErreur } from '../_shared/demande.js';
import { enfiler } from '../_shared/file-sortie.js';
import { enTetesCors, ipClient, lireDemandeMultipart } from '../_shared/http.js';

Deno.serve(async (req) => {
  const cors = enTetesCors(req, Deno.env.get('ALLOWED_ORIGINS'));
  const rep = (status, corps) => new Response(JSON.stringify(corps), { status, headers: { 'content-type': 'application/json', ...cors } });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') return rep(405, { erreur: 'methode_non_autorisee' });
  const entree = await lireDemandeMultipart(req, NATURES);
  if (entree?.trop_grand) return rep(413, { erreur: 'corps_trop_grand' });
  if (!entree) return rep(400, { erreur: 'corps_invalide', message: 'Requête invalide.' });
  try {
    const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
    const magasin = creerMagasinOnboarding(sb);
    const cle = await cleDepuisBase64(Deno.env.get('ENCRYPTION_KEY'));
    const r = await traiterDemande(entree, {
      env: Object.fromEntries(['CAPTCHA_PROVIDER', 'CAPTCHA_SECRET', 'SIGNING_SECRET', 'APP_BASE_URL'].map((k) => [k, Deno.env.get(k)])),
      ip: ipClient(req.headers), magasin, cle, journal: (e) => console.log(JSON.stringify(e)),
      accuser: ({ demandeId, email, nomOfficine }) => enfiler(magasin, cle, {
        typeDestinataire: 'pharmacy', destinataireRef: null, canal: 'email', modele: 'onboarding_recu', adresse: email,
        variables: { nom_officine: nomOfficine }, cleBase: `onboarding:${demandeId}:recu` }),
    });
    return rep(r.status, r.corps);
  } catch (e) {
    console.error(JSON.stringify({ evt: 'erreur_creer_demande', erreur: e?.name || 'inconnue' }));
    const r = reponseErreur('erreur_interne');
    return rep(r.status, r.corps);
  }
});
