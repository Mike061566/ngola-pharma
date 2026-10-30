-- ============================================================
-- Planification de l'Edge Function `traiter-outbox` (pg_cron + pg_net) — À EXÉCUTER À LA MAIN, par l'admin.
-- Ce fichier ne contient AUCUN secret : il lit le secret et l'URL dans Supabase Vault.
-- Ne pas l'exécuter tant que le déploiement de la fonction n'est pas validé (rien ne part en mode `mock`,
-- mais l'outbox se viderait vers le fournisseur configuré).
--
-- Préalables (Dashboard > Edge Functions > Secrets, jamais dans le dépôt ni dans le chat) :
--   CRON_SECRET, ENCRYPTION_KEY (32 octets en base64). TELEGRAM_PROVIDER / SMS_PROVIDER / EMAIL_PROVIDER restent
--   absents (= mock) jusqu'à la PR 7.
-- Préalables (SQL Editor, valeurs saisies à la main) :
--   select vault.create_secret('<url du projet>/functions/v1/traiter-outbox', 'url_traiter_outbox');
--   select vault.create_secret('<même valeur que CRON_SECRET>', 'cron_secret');
-- Extensions : pg_cron et pg_net (Dashboard > Database > Extensions).
-- ============================================================

-- Toutes les minutes (pg_cron ne descend pas sous la minute ; le worker boucle ~50 s par appel).
select cron.schedule(
  'traiter-outbox',
  '* * * * *',
  $$
  select net.http_post(
    url     := (select decrypted_secret from vault.decrypted_secrets where name = 'url_traiter_outbox'),
    headers := jsonb_build_object(
                 'content-type', 'application/json',
                 'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
  $$
);

-- Arrêt : select cron.unschedule('traiter-outbox');
