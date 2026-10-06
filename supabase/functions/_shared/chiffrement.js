// Chiffrement des adresses de l'outbox (AES-256-GCM, WebCrypto : Deno et Node ≥ 20).
// Format : 1 octet de version (1) | IV de 12 octets | texte chiffré + étiquette GCM.
// La clé (ENCRYPTION_KEY, 32 octets en base64) vient UNIQUEMENT de l'environnement.
const VERSION = 1;
const encodeur = new TextEncoder();
const decodeur = new TextDecoder();

function base64VersOctets(b64) {
  const bin = atob(b64);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export async function cleDepuisBase64(b64) {
  if (typeof b64 !== 'string' || b64.length === 0) throw new Error('ENCRYPTION_KEY manquante');
  const brut = base64VersOctets(b64);
  if (brut.length !== 32) throw new Error('ENCRYPTION_KEY doit contenir 32 octets (base64)');
  return crypto.subtle.importKey('raw', brut, 'AES-GCM', false, ['encrypt', 'decrypt']);
}

export async function chiffrer(cle, texte) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const chiffre = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, cle, encodeur.encode(texte)));
  const sortie = new Uint8Array(1 + 12 + chiffre.length);
  sortie[0] = VERSION;
  sortie.set(iv, 1);
  sortie.set(chiffre, 13);
  return sortie;
}

export async function dechiffrer(cle, octets) {
  if (!(octets instanceof Uint8Array) || octets.length < 13 + 16 || octets[0] !== VERSION) {
    throw new Error('Donnée chiffrée invalide');
  }
  const clair = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: octets.slice(1, 13) }, cle, octets.slice(13));
  return decodeur.decode(clair);
}

/** Représentation texte d'un bytea PostgreSQL (format hexadécimal), telle qu'échangée avec PostgREST. */
export function versBytea(octets) {
  return '\\x' + Array.from(octets, (o) => o.toString(16).padStart(2, '0')).join('');
}

export function depuisBytea(texte) {
  if (typeof texte !== 'string' || !/^\\x([0-9a-fA-F]{2})*$/.test(texte)) throw new Error('bytea invalide');
  const hex = texte.slice(2);
  const sortie = new Uint8Array(hex.length / 2);
  for (let i = 0; i < sortie.length; i++) sortie[i] = parseInt(hex.slice(2 * i, 2 * i + 2), 16);
  return sortie;
}
