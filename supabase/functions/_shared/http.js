// Aides HTTP des fonctions publiques : CORS par liste blanche d'origines, IP du client.

/** ALLOWED_ORIGINS : origines autorisées séparées par des virgules. Absent = aucune origine croisée autorisée. */
export function enTetesCors(req, allowed) {
  const origine = req.headers.get('origin');
  const liste = String(allowed || '').split(',').map((s) => s.trim()).filter(Boolean);
  const base = { 'vary': 'origin', 'access-control-allow-methods': 'GET, POST, OPTIONS', 'access-control-allow-headers': 'content-type, apikey, authorization' };
  return origine && liste.includes(origine) ? { ...base, 'access-control-allow-origin': origine } : base;
}

/** IP du client derrière le proxy Supabase/Cloudflare : cf-connecting-ip, sinon le dernier saut de x-forwarded-for. */
export function ipClient(headers) {
  const cf = headers.get('cf-connecting-ip');
  if (cf) return cf.trim();
  const xff = headers.get('x-forwarded-for');
  if (xff) return xff.split(',')[0].trim() || null;
  return null;
}
