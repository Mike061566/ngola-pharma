// Vérification du captcha (SPEC 2 §3 : Turnstile). Fournisseurs :
//  - `mock`      : aucun appel réseau ; accepte uniquement le jeton « mock-ok », et SEULEMENT en mode démo ;
//  - `turnstile` : appelle Cloudflare siteverify avec CAPTCHA_SECRET (variable d'environnement, jamais dans le dépôt).
// Le résultat ne contient jamais le jeton ni l'IP.
const URL_TURNSTILE = 'https://challenges.cloudflare.com/turnstile/v0/siteverify';

export async function verifierCaptcha({ fournisseur = 'mock', secret, jeton, ip, mode, fetchFn = globalThis.fetch }) {
  if (typeof jeton !== 'string' || jeton.length === 0 || jeton.length > 2048) return { ok: false, raison: 'jeton_absent' };
  if (fournisseur === 'mock') {
    if (mode !== 'demo') return { ok: false, raison: 'captcha_non_configure' };   // jamais de captcha simulé en production
    return jeton === 'mock-ok' ? { ok: true } : { ok: false, raison: 'jeton_invalide' };
  }
  if (fournisseur === 'turnstile') {
    if (!secret) return { ok: false, raison: 'captcha_non_configure' };
    try {
      const corps = new URLSearchParams({ secret, response: jeton });
      if (ip) corps.set('remoteip', ip);
      const rep = await fetchFn(URL_TURNSTILE, { method: 'POST', body: corps });
      if (!rep.ok) return { ok: false, raison: 'indisponible' };
      const json = await rep.json();
      return json && json.success === true ? { ok: true } : { ok: false, raison: 'jeton_invalide' };
    } catch {
      return { ok: false, raison: 'indisponible' };
    }
  }
  return { ok: false, raison: 'captcha_non_configure' };
}
