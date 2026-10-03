// Comparaison à temps constant (secret partagé de l'appel planifié). Les deux valeurs sont d'abord hachées :
// la comparaison porte sur des empreintes de longueur fixe, sans fuite de longueur ni court-circuit.
export async function egalConstante(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length === 0 || b.length === 0) return false;
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest('SHA-256', enc.encode(a)),
    crypto.subtle.digest('SHA-256', enc.encode(b)),
  ]);
  const x = new Uint8Array(ha), y = new Uint8Array(hb);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

/** HMAC-SHA256 en hexadécimal (empreintes anti-abus : jamais le numéro ni l'IP en clair). */
export async function hmacHex(secret, donnee) {
  if (typeof secret !== 'string' || secret.length < 16) throw new Error('SIGNING_SECRET manquant ou trop court');
  const enc = new TextEncoder();
  const cle = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', cle, enc.encode(donnee)));
  return Array.from(sig, (o) => o.toString(16).padStart(2, '0')).join('');
}

/** SHA-256 hexadécimal (jetons à usage unique stockés hachés). */
export async function sha256Hex(texte) {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texte)));
  return Array.from(h, (o) => o.toString(16).padStart(2, '0')).join('');
}

/** Chaîne aléatoire sûre : `n` caractères de l'alphabet Crockford base32 (sans I, L, O, U), ou jeton base64url. */
export function aleatoireBase32(n) {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  const octets = crypto.getRandomValues(new Uint8Array(n));
  return Array.from(octets, (o) => alphabet[o % 32]).join('');
}
export function jetonBase64url(nOctets = 32) {
  const o = crypto.getRandomValues(new Uint8Array(nOctets));
  return btoa(String.fromCharCode(...o)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
