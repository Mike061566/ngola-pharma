// Configuration publique de la page « Alerte de disponibilité ». Rien de secret ici : l'URL et la clé « anon » sont celles
// déjà utilisées par index.html et pro.html (la sécurité repose sur RLS et sur les Edge Functions, pas sur ce fichier).
// `turnstileSiteKey` : clé de SITE Cloudflare Turnstile (publique). Vide = captcha simulé, accepté par le serveur
// uniquement en mode démonstration. Le secret Turnstile reste dans les variables d'environnement de la fonction.
window.NGOLA_ALERTE = {
  apiBase: 'https://ueycknsdwthmtmpzptqp.supabase.co',
  anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVleWNrbnNkd3RobXRtcHpwdHFwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkxNjM4MzEsImV4cCI6MjEwNDczOTgzMX0.MHLnZVRgT7PbVtDfam4TThIuYwr6wCZCghhfFddgyig',
  turnstileSiteKey: '',
  // Nom d'utilisateur PUBLIC du bot Telegram (sans @), pour le lien d'activation de l'Espace Pro. Vide = activation Telegram indisponible.
  telegramBot: 'ngola_pharma_Bot'
};
