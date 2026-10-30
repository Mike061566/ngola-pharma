#!/usr/bin/env node
// Enregistre le webhook du bot Telegram (à lancer MANUELLEMENT par le propriétaire, jamais en CI).
// Variables d'environnement requises (aucune valeur dans le dépôt ni dans le chat) :
//   TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET, WEBHOOK_URL (https://<projet>.supabase.co/functions/v1/webhook-telegram)
// Usage : node scripts/telegram-set-webhook.js --confirmer   (sans --confirmer : affiche seulement ce qui serait envoyé)
const { TELEGRAM_BOT_TOKEN: jeton, TELEGRAM_WEBHOOK_SECRET: secret, WEBHOOK_URL: url } = process.env;
const confirmer = process.argv.includes('--confirmer');
if (!jeton || !secret || !url) { console.error('Variables manquantes : TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET, WEBHOOK_URL'); process.exit(1); }
if (!/^https:\/\//.test(url)) { console.error('WEBHOOK_URL doit être en https'); process.exit(1); }
if (!/^[A-Za-z0-9_-]{16,256}$/.test(secret)) { console.error('TELEGRAM_WEBHOOK_SECRET : 16 à 256 caractères parmi A-Z a-z 0-9 _ -'); process.exit(1); }
const corps = { url, secret_token: secret, allowed_updates: ['message', 'callback_query'], drop_pending_updates: false };
if (!confirmer) { console.log('Simulation (ajoutez --confirmer pour envoyer) :', JSON.stringify({ ...corps, secret_token: '***' })); process.exit(0); }
(async () => {
  const r = await fetch(`https://api.telegram.org/bot${jeton}/setWebhook`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(corps) });
  const j = await r.json().catch(() => ({}));
  console.log(j.ok ? 'Webhook enregistré.' : `Échec : ${j.description || r.status}`);
  process.exit(j.ok ? 0 : 1);
})();
