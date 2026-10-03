-- ============================================================
-- Planification de l'Edge Function `planifier-alertes` (pg_cron + pg_net) — À EXÉCUTER À LA MAIN, par l'admin.
-- AUCUN secret dans ce fichier : l'URL et le secret sont lus dans Supabase Vault (voir planifier_outbox.sql, même principe).
-- Ne pas exécuter avant : déploiement validé de la fonction, secrets posés, et décision d'activer ALERT_AUTO_ROUTING.
-- Tant que ALERT_AUTO_ROUTING n'est pas « true », la fonction répond « inactif » et ne touche à rien.
--
-- Préalable (SQL Editor, valeur saisie à la main) :
--   select vault.create_secret('<url du projet>/functions/v1/planifier-alertes', 'url_planifier_alertes');
--   (le secret 'cron_secret' est celui déjà créé pour l'outbox)
-- ============================================================
select cron.schedule(
  'planifier-alertes',
  '* * * * *',
  $$
  select net.http_post(
    url     := (select decrypted_secret from vault.decrypted_secrets where name = 'url_planifier_alertes'),
    headers := jsonb_build_object(
                 'content-type', 'application/json',
                 'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
  $$
);

-- Arrêt : select cron.unschedule('planifier-alertes');
