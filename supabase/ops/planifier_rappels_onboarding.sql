-- ============================================================
-- Planification de l'Edge Function `rappels-onboarding` (pg_cron + pg_net) — À EXÉCUTER À LA MAIN, par l'admin.
-- AUCUN secret dans ce fichier : l'URL et le secret sont lus dans Supabase Vault (même principe que planifier_outbox.sql).
-- Une fois par jour à 07:00 UTC (08:00 à Yaoundé). Ne pas exécuter avant : migration 20261014000000 appliquée, fonction déployée,
-- secrets posés (CRON_SECRET, ENCRYPTION_KEY, APP_BASE_URL, ADMIN_ALERT_EMAIL).
--
-- Préalable (SQL Editor, valeur saisie à la main) :
--   select vault.create_secret('<url du projet>/functions/v1/rappels-onboarding', 'url_rappels_onboarding');
--   (le secret 'cron_secret' est celui déjà créé pour l'outbox)
-- En mode démo, les rappels vont à l'outbox mais seuls les contacts de la liste blanche reçoivent un vrai message.
-- ============================================================
select cron.schedule(
  'rappels-onboarding',
  '0 7 * * *',
  $$
  select net.http_post(
    url     := (select decrypted_secret from vault.decrypted_secrets where name = 'url_rappels_onboarding'),
    headers := jsonb_build_object(
                 'content-type', 'application/json',
                 'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
  $$
);

-- Arrêt : select cron.unschedule('rappels-onboarding');
