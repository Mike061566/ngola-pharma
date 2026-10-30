-- ============================================================
-- N'Gola Pharma — VÉRIFICATION APRÈS LES MIGRATIONS (LECTURE SEULE) — docs/MISE-EN-PRODUCTION.md, phase D.
-- À exécuter dans le SQL Editor de PRODUCTION après les migrations 20261004000000 à 20261016000000 (peut être relancé après chacune : les contrôles
-- des migrations pas encore appliquées valent alors false, sans erreur). Un seul résultat : la ligne BILAN, puis une ligne par contrôle (colonne `ok`,
-- tout doit être true), puis des lignes d'INFORMATION (ok vide) qui ne sont pas des échecs. Ne modifie RIEN : transaction en lecture seule, ROLLBACK final.
-- Contrôles générés à partir des fichiers de supabase/migrations/ (tables, RLS, fonctions, droits d'exécution) puis complétés à la main (valeurs par
-- défaut, déclencheurs, bucket privé, mode démo). Complément indispensable : la comparaison structurelle complète (schema_inventory.sql + scripts/compare-schema.js).
-- ============================================================
BEGIN READ ONLY;

WITH controles(migration, controle, ok) AS (
    SELECT '20261003100000', 'fusion : index unique uq_medicaments_nom_dosage présent', (to_regclass('public.uq_medicaments_nom_dosage') IS NOT NULL)
    UNION ALL
    SELECT '20261004000000', 'table validations_classification présente', (to_regclass('public.validations_classification') IS NOT NULL)
    UNION ALL
    SELECT '20261004000000', 'table validations_classification : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.validations_classification')), false))
    UNION ALL
    SELECT '20261004000000', 'table alias_medicaments présente', (to_regclass('public.alias_medicaments') IS NOT NULL)
    UNION ALL
    SELECT '20261004000000', 'table alias_medicaments : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.alias_medicaments')), false))
    UNION ALL
    SELECT '20261004000000', 'table demandes_catalogue présente', (to_regclass('public.demandes_catalogue') IS NOT NULL)
    UNION ALL
    SELECT '20261004000000', 'table demandes_catalogue : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.demandes_catalogue')), false))
    UNION ALL
    SELECT '20261004000000', 'fonction medicaments_reset_validation présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'medicaments_reset_validation'))
    UNION ALL
    SELECT '20261004000000', 'fonction valider_classification présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'valider_classification'))
    UNION ALL
    SELECT '20261004000000', 'colonne medicaments.restreint présente', (EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='medicaments' AND column_name='restreint'))
    UNION ALL
    SELECT '20261004000000', 'colonne medicaments.restreint : défaut true (comportement sûr)', ((SELECT column_default FROM information_schema.columns WHERE table_schema='public' AND table_name='medicaments' AND column_name='restreint') = 'true')
    UNION ALL
    SELECT '20261004000000', 'colonne medicaments.classification_validee_le présente', (EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='medicaments' AND column_name='classification_validee_le'))
    UNION ALL
    SELECT '20261004010000', 'table etat_onboarding_pharmacie présente', (to_regclass('public.etat_onboarding_pharmacie') IS NOT NULL)
    UNION ALL
    SELECT '20261004010000', 'table etat_onboarding_pharmacie : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.etat_onboarding_pharmacie')), false))
    UNION ALL
    SELECT '20261004010000', 'table contacts_pharmacie présente', (to_regclass('public.contacts_pharmacie') IS NOT NULL)
    UNION ALL
    SELECT '20261004010000', 'table contacts_pharmacie : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.contacts_pharmacie')), false))
    UNION ALL
    SELECT '20261004010000', 'fonction stocks_sync_statut présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'stocks_sync_statut'))
    UNION ALL
    SELECT '20261004010000', 'pharmacies : publiée seulement si vérifiée (contrainte)', (EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pharmacies_publiee_verifiee'))
    UNION ALL
    SELECT '20261004020000', 'table config_routage présente', (to_regclass('public.config_routage') IS NOT NULL)
    UNION ALL
    SELECT '20261004020000', 'table config_routage : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.config_routage')), false))
    UNION ALL
    SELECT '20261004020000', 'table alertes_routage présente', (to_regclass('public.alertes_routage') IS NOT NULL)
    UNION ALL
    SELECT '20261004020000', 'table alertes_routage : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.alertes_routage')), false))
    UNION ALL
    SELECT '20261004020000', 'table envois_alerte présente', (to_regclass('public.envois_alerte') IS NOT NULL)
    UNION ALL
    SELECT '20261004020000', 'table envois_alerte : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.envois_alerte')), false))
    UNION ALL
    SELECT '20261004020000', 'table reponses_alerte présente', (to_regclass('public.reponses_alerte') IS NOT NULL)
    UNION ALL
    SELECT '20261004020000', 'table reponses_alerte : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.reponses_alerte')), false))
    UNION ALL
    SELECT '20261004020000', 'table notifications_outbox présente', (to_regclass('public.notifications_outbox') IS NOT NULL)
    UNION ALL
    SELECT '20261004020000', 'table notifications_outbox : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.notifications_outbox')), false))
    UNION ALL
    SELECT '20261004020000', 'table jetons_telegram présente', (to_regclass('public.jetons_telegram') IS NOT NULL)
    UNION ALL
    SELECT '20261004020000', 'table jetons_telegram : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.jetons_telegram')), false))
    UNION ALL
    SELECT '20261004020000', 'table patients_bloques présente', (to_regclass('public.patients_bloques') IS NOT NULL)
    UNION ALL
    SELECT '20261004020000', 'table patients_bloques : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.patients_bloques')), false))
    UNION ALL
    SELECT '20261004020000', 'fonction mode_application présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'mode_application'))
    UNION ALL
    SELECT '20261004020000', 'fonction medicament_routable présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'medicament_routable'))
    UNION ALL
    SELECT '20261004020000', 'fonction pharmacie_eligible_routage présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pharmacie_eligible_routage'))
    UNION ALL
    SELECT '20261004020000', 'fonction conditions_passage_production présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'conditions_passage_production'))
    UNION ALL
    SELECT '20261004020000', 'fonction conditions_passage_production : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'conditions_passage_production' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261004020000', 'fonction config_routage_verrou présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'config_routage_verrou'))
    UNION ALL
    SELECT '20261004020000', 'fonction config_routage_interdit_suppression_mode présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'config_routage_interdit_suppression_mode'))
    UNION ALL
    SELECT '20261004020000', 'verrou du passage en production (déclencheur sur config_routage)', (to_regclass('public.config_routage') IS NOT NULL AND EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = to_regclass('public.config_routage') AND NOT t.tgisinternal AND pg_get_triggerdef(t.oid) ILIKE '%config_routage_verrou%'))
    UNION ALL
    SELECT '20261004020000', 'mode_application = demo (état attendu avant le passage en production)', (CASE WHEN to_regclass('public.config_routage') IS NOT NULL THEN COALESCE((xpath('/row/v/text()', query_to_xml('SELECT valeur::text AS v FROM public.config_routage WHERE cle = ''mode_application''', false, true, '')))[1]::text, '') = '"demo"' ELSE false END)
    UNION ALL
    SELECT '20261004020000', 'conditions de passage en production : 5 conditions listées', (CASE WHEN to_regprocedure('public.conditions_passage_production()') IS NOT NULL THEN COALESCE((xpath('/row/v/text()', query_to_xml('SELECT count(*) AS v FROM public.conditions_passage_production()', false, true, '')))[1]::text, '0') = '5' ELSE false END)
    UNION ALL
    SELECT '20261005000000', 'fonction pharmacie_eligible_routage présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pharmacie_eligible_routage'))
    UNION ALL
    SELECT '20261005000000', 'fonction reclamer_notifications présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'reclamer_notifications'))
    UNION ALL
    SELECT '20261005000000', 'fonction compter_messages_payants_du_jour présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'compter_messages_payants_du_jour'))
    UNION ALL
    SELECT '20261007000000', 'fonction creer_alerte_routage présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'creer_alerte_routage'))
    UNION ALL
    SELECT '20261007000000', 'fonction donnees_routage_pharmacies présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'donnees_routage_pharmacies'))
    UNION ALL
    SELECT '20261008000000', 'fonction enregistrer_reponse_alerte présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'enregistrer_reponse_alerte'))
    UNION ALL
    SELECT '20261008000000', 'fonction repondre_alerte présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'repondre_alerte'))
    UNION ALL
    SELECT '20261008000000', 'fonction trouver_envoi_court présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'trouver_envoi_court'))
    UNION ALL
    SELECT '20261008000000', 'fonction consommer_jeton_telegram présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'consommer_jeton_telegram'))
    UNION ALL
    SELECT '20261008000000', 'fonction lier_contact_telegram présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'lier_contact_telegram'))
    UNION ALL
    SELECT '20261008000000', 'fonction desabonner_telegram présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'desabonner_telegram'))
    UNION ALL
    SELECT '20261008000000', 'fonction activer_telegram_pharmacie présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'activer_telegram_pharmacie'))
    UNION ALL
    SELECT '20261008000000', 'fonction ajouter_contact_sms présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'ajouter_contact_sms'))
    UNION ALL
    SELECT '20261008000000', 'fonction changer_abonnement_contact présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'changer_abonnement_contact'))
    UNION ALL
    SELECT '20261009000000', 'table journal_admin_alertes présente', (to_regclass('public.journal_admin_alertes') IS NOT NULL)
    UNION ALL
    SELECT '20261009000000', 'table journal_admin_alertes : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.journal_admin_alertes')), false))
    UNION ALL
    SELECT '20261009000000', 'table ordres_admin_alertes présente', (to_regclass('public.ordres_admin_alertes') IS NOT NULL)
    UNION ALL
    SELECT '20261009000000', 'table ordres_admin_alertes : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.ordres_admin_alertes')), false))
    UNION ALL
    SELECT '20261009000000', 'fonction exiger_admin présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'exiger_admin'))
    UNION ALL
    SELECT '20261009000000', 'fonction journaliser_admin présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'journaliser_admin'))
    UNION ALL
    SELECT '20261009000000', 'fonction erreur_valeur_config présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'erreur_valeur_config'))
    UNION ALL
    SELECT '20261009000000', 'fonction config_routage_valider présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'config_routage_valider'))
    UNION ALL
    SELECT '20261009000000', 'fonction config_routage_journal présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'config_routage_journal'))
    UNION ALL
    SELECT '20261009000000', 'fonction file_alertes_admin présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'file_alertes_admin'))
    UNION ALL
    SELECT '20261009000000', 'fonction chronologie_alerte présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'chronologie_alerte'))
    UNION ALL
    SELECT '20261009000000', 'fonction etat_budget_messages présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'etat_budget_messages'))
    UNION ALL
    SELECT '20261009000000', 'fonction indicateurs_alertes présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'indicateurs_alertes'))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_rattacher_medicament présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_rattacher_medicament'))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_rattacher_medicament : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_rattacher_medicament' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_transmettre présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_transmettre'))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_transmettre : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_transmettre' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_refuser_alerte présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_refuser_alerte'))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_refuser_alerte : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_refuser_alerte' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_relancer_vague présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_relancer_vague'))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_relancer_vague : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_relancer_vague' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_cloturer_alerte présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_cloturer_alerte'))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_cloturer_alerte : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_cloturer_alerte' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261009000000', 'fonction annuler_alerte_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'annuler_alerte_interne'))
    UNION ALL
    SELECT '20261009000000', 'fonction annuler_alerte_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'annuler_alerte_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261009000000', 'fonction annuler_alerte_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'annuler_alerte_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_annuler_alerte présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_annuler_alerte'))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_annuler_alerte : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_annuler_alerte' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_retirer_destinataire présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_retirer_destinataire'))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_retirer_destinataire : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_retirer_destinataire' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_bloquer_patient présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_bloquer_patient'))
    UNION ALL
    SELECT '20261009000000', 'fonction admin_bloquer_patient : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_bloquer_patient' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261010000000', 'fonction mode_public présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'mode_public'))
    UNION ALL
    SELECT '20261010000000', 'fonction admin_liste_contacts présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_liste_contacts'))
    UNION ALL
    SELECT '20261010000000', 'fonction admin_liste_contacts : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_liste_contacts' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261010000000', 'fonction admin_marquer_contact_demo présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_marquer_contact_demo'))
    UNION ALL
    SELECT '20261010000000', 'fonction admin_marquer_contact_demo : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_marquer_contact_demo' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261010000000', 'fonction admin_activer_telegram_demo présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_activer_telegram_demo'))
    UNION ALL
    SELECT '20261010000000', 'fonction admin_activer_telegram_demo : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_activer_telegram_demo' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261010000000', 'fonction file_messages_demo présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'file_messages_demo'))
    UNION ALL
    SELECT '20261010000000', 'fonction reinitialiser_demo présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'reinitialiser_demo'))
    UNION ALL
    SELECT '20261011000000', 'table demandes_partenaire présente', (to_regclass('public.demandes_partenaire') IS NOT NULL)
    UNION ALL
    SELECT '20261011000000', 'table demandes_partenaire : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.demandes_partenaire')), false))
    UNION ALL
    SELECT '20261011000000', 'table documents_demande présente', (to_regclass('public.documents_demande') IS NOT NULL)
    UNION ALL
    SELECT '20261011000000', 'table documents_demande : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.documents_demande')), false))
    UNION ALL
    SELECT '20261011000000', 'table checklist_demande présente', (to_regclass('public.checklist_demande') IS NOT NULL)
    UNION ALL
    SELECT '20261011000000', 'table checklist_demande : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.checklist_demande')), false))
    UNION ALL
    SELECT '20261011000000', 'table evenements_onboarding présente', (to_regclass('public.evenements_onboarding') IS NOT NULL)
    UNION ALL
    SELECT '20261011000000', 'table evenements_onboarding : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.evenements_onboarding')), false))
    UNION ALL
    SELECT '20261011000000', 'table jetons_activation présente', (to_regclass('public.jetons_activation') IS NOT NULL)
    UNION ALL
    SELECT '20261011000000', 'table jetons_activation : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.jetons_activation')), false))
    UNION ALL
    SELECT '20261011000000', 'fonction normaliser_nom_pharmacie présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'normaliser_nom_pharmacie'))
    UNION ALL
    SELECT '20261011000000', 'fonction chiffres_telephone présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'chiffres_telephone'))
    UNION ALL
    SELECT '20261011000000', 'fonction journaliser_onboarding présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'journaliser_onboarding'))
    UNION ALL
    SELECT '20261011000000', 'fonction soumettre_demande_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'soumettre_demande_interne'))
    UNION ALL
    SELECT '20261011000000', 'fonction soumettre_demande_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'soumettre_demande_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction soumettre_demande_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'soumettre_demande_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction admin_lister_demandes présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_lister_demandes'))
    UNION ALL
    SELECT '20261011000000', 'fonction admin_lister_demandes : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_lister_demandes' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction admin_detail_demande présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_detail_demande'))
    UNION ALL
    SELECT '20261011000000', 'fonction admin_detail_demande : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_detail_demande' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction admin_demarrer_revue présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_demarrer_revue'))
    UNION ALL
    SELECT '20261011000000', 'fonction admin_demarrer_revue : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_demarrer_revue' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction admin_basculer_checklist présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_basculer_checklist'))
    UNION ALL
    SELECT '20261011000000', 'fonction admin_basculer_checklist : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_basculer_checklist' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction decider_demande_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'decider_demande_interne'))
    UNION ALL
    SELECT '20261011000000', 'fonction decider_demande_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'decider_demande_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction decider_demande_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'decider_demande_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction definir_jeton_complements_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'definir_jeton_complements_interne'))
    UNION ALL
    SELECT '20261011000000', 'fonction definir_jeton_complements_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'definir_jeton_complements_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction definir_jeton_complements_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'definir_jeton_complements_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction deposer_complements_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'deposer_complements_interne'))
    UNION ALL
    SELECT '20261011000000', 'fonction deposer_complements_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'deposer_complements_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction deposer_complements_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'deposer_complements_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction creer_jeton_activation_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'creer_jeton_activation_interne'))
    UNION ALL
    SELECT '20261011000000', 'fonction creer_jeton_activation_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'creer_jeton_activation_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction creer_jeton_activation_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'creer_jeton_activation_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction consommer_jeton_activation_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'consommer_jeton_activation_interne'))
    UNION ALL
    SELECT '20261011000000', 'fonction consommer_jeton_activation_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'consommer_jeton_activation_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction consommer_jeton_activation_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'consommer_jeton_activation_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction marquer_invitation_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'marquer_invitation_interne'))
    UNION ALL
    SELECT '20261011000000', 'fonction marquer_invitation_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'marquer_invitation_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction marquer_invitation_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'marquer_invitation_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction lier_profil_pharmacien_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'lier_profil_pharmacien_interne'))
    UNION ALL
    SELECT '20261011000000', 'fonction lier_profil_pharmacien_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'lier_profil_pharmacien_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction lier_profil_pharmacien_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'lier_profil_pharmacien_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction utilisateur_par_email_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'utilisateur_par_email_interne'))
    UNION ALL
    SELECT '20261011000000', 'fonction utilisateur_par_email_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'utilisateur_par_email_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'fonction utilisateur_par_email_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'utilisateur_par_email_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261011000000', 'bucket documents-demandes présent et PRIVÉ', (CASE WHEN to_regclass('storage.buckets') IS NOT NULL THEN COALESCE((xpath('/row/v/text()', query_to_xml('SELECT (NOT public)::text AS v FROM storage.buckets WHERE id = ''documents-demandes''', false, true, '')))[1]::text, 'false') = 'true' ELSE false END)
    UNION ALL
    SELECT '20261012000000', 'fonction erreur_valeur_config présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'erreur_valeur_config'))
    UNION ALL
    SELECT '20261012000000', 'fonction calculer_onboarding présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'calculer_onboarding'))
    UNION ALL
    SELECT '20261012000000', 'fonction evaluer_publication_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'evaluer_publication_interne'))
    UNION ALL
    SELECT '20261012000000', 'fonction evaluer_publication_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'evaluer_publication_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261012000000', 'fonction evaluer_publication_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'evaluer_publication_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261012000000', 'fonction exiger_pharmacien_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'exiger_pharmacien_interne'))
    UNION ALL
    SELECT '20261012000000', 'fonction exiger_pharmacien_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'exiger_pharmacien_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261012000000', 'fonction exiger_pharmacien_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'exiger_pharmacien_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261012000000', 'fonction etat_onboarding_mien présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'etat_onboarding_mien'))
    UNION ALL
    SELECT '20261012000000', 'fonction onboarding_marquer présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'onboarding_marquer'))
    UNION ALL
    SELECT '20261012000000', 'fonction confirmer_mes_stocks présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'confirmer_mes_stocks'))
    UNION ALL
    SELECT '20261012000000', 'fonction reevaluer_ma_publication présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'reevaluer_ma_publication'))
    UNION ALL
    SELECT '20261012000000', 'fonction admin_etat_onboarding présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_etat_onboarding'))
    UNION ALL
    SELECT '20261012000000', 'fonction admin_etat_onboarding : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_etat_onboarding' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261012000000', 'fonction admin_detail_demande présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_detail_demande'))
    UNION ALL
    SELECT '20261012000000', 'fonction admin_detail_demande : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_detail_demande' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261012000000', 'réglages de publication présents (10 stocks frais, 7 jours)', (CASE WHEN to_regclass('public.config_routage') IS NOT NULL THEN COALESCE((xpath('/row/v/text()', query_to_xml('SELECT count(*) AS v FROM public.config_routage WHERE cle IN (''publication_min_items_frais'', ''publication_fraicheur_jours'')', false, true, '')))[1]::text, '0') = '2' ELSE false END)
    UNION ALL
    SELECT '20261013000000', 'table lots_import présente', (to_regclass('public.lots_import') IS NOT NULL)
    UNION ALL
    SELECT '20261013000000', 'table lots_import : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.lots_import')), false))
    UNION ALL
    SELECT '20261013000000', 'table lignes_import présente', (to_regclass('public.lignes_import') IS NOT NULL)
    UNION ALL
    SELECT '20261013000000', 'table lignes_import : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.lignes_import')), false))
    UNION ALL
    SELECT '20261013000000', 'table lots_import_archives présente', (to_regclass('public.lots_import_archives') IS NOT NULL)
    UNION ALL
    SELECT '20261013000000', 'table lots_import_archives : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.lots_import_archives')), false))
    UNION ALL
    SELECT '20261013000000', 'fonction normaliser_texte_medicament présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'normaliser_texte_medicament'))
    UNION ALL
    SELECT '20261013000000', 'fonction jeton_dosage présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'jeton_dosage'))
    UNION ALL
    SELECT '20261013000000', 'fonction dosages_compatibles présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'dosages_compatibles'))
    UNION ALL
    SELECT '20261013000000', 'fonction lot_du_pharmacien présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'lot_du_pharmacien'))
    UNION ALL
    SELECT '20261013000000', 'fonction libelle_fiche présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'libelle_fiche'))
    UNION ALL
    SELECT '20261013000000', 'fonction import_creer_lot présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_creer_lot'))
    UNION ALL
    SELECT '20261013000000', 'fonction import_creer_lot : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_creer_lot' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction import_ajouter_lignes présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_ajouter_lignes'))
    UNION ALL
    SELECT '20261013000000', 'fonction import_ajouter_lignes : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_ajouter_lignes' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction dedoublonner_lot_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'dedoublonner_lot_interne'))
    UNION ALL
    SELECT '20261013000000', 'fonction dedoublonner_lot_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'dedoublonner_lot_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction dedoublonner_lot_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'dedoublonner_lot_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction import_compter_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_compter_interne'))
    UNION ALL
    SELECT '20261013000000', 'fonction import_compter_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_compter_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction import_compter_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_compter_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction import_finaliser_lot présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_finaliser_lot'))
    UNION ALL
    SELECT '20261013000000', 'fonction import_finaliser_lot : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_finaliser_lot' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction import_lire_lot présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_lire_lot'))
    UNION ALL
    SELECT '20261013000000', 'fonction import_lire_lot : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_lire_lot' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction import_corriger_ligne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_corriger_ligne'))
    UNION ALL
    SELECT '20261013000000', 'fonction import_corriger_ligne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_corriger_ligne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction import_chercher_catalogue présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_chercher_catalogue'))
    UNION ALL
    SELECT '20261013000000', 'fonction import_chercher_catalogue : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_chercher_catalogue' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction import_demander_ajout présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_demander_ajout'))
    UNION ALL
    SELECT '20261013000000', 'fonction import_demander_ajout : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_demander_ajout' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction import_abandonner_lot présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_abandonner_lot'))
    UNION ALL
    SELECT '20261013000000', 'fonction import_abandonner_lot : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_abandonner_lot' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction import_valider_lot présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_valider_lot'))
    UNION ALL
    SELECT '20261013000000', 'fonction import_valider_lot : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_valider_lot' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction import_annuler_lot présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_annuler_lot'))
    UNION ALL
    SELECT '20261013000000', 'fonction import_annuler_lot : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_annuler_lot' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction import_historique présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_historique'))
    UNION ALL
    SELECT '20261013000000', 'fonction import_historique : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_historique' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261013000000', 'fonction calculer_onboarding présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'calculer_onboarding'))
    UNION ALL
    SELECT '20261014000000', 'table rappels_onboarding présente', (to_regclass('public.rappels_onboarding') IS NOT NULL)
    UNION ALL
    SELECT '20261014000000', 'table rappels_onboarding : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.rappels_onboarding')), false))
    UNION ALL
    SELECT '20261014000000', 'fonction candidats_rappels_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'candidats_rappels_interne'))
    UNION ALL
    SELECT '20261014000000', 'fonction candidats_rappels_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'candidats_rappels_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261014000000', 'fonction candidats_rappels_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'candidats_rappels_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261014000000', 'fonction enregistrer_rappel_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'enregistrer_rappel_interne'))
    UNION ALL
    SELECT '20261014000000', 'fonction enregistrer_rappel_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'enregistrer_rappel_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261014000000', 'fonction enregistrer_rappel_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'enregistrer_rappel_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261014000000', 'fonction admin_pharmacies_en_retard présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_pharmacies_en_retard'))
    UNION ALL
    SELECT '20261014000000', 'fonction admin_pharmacies_en_retard : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_pharmacies_en_retard' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261015000000', 'fonction jetons_nombres présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'jetons_nombres'))
    UNION ALL
    SELECT '20261015000000', 'fonction conditionnements_compatibles présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'conditionnements_compatibles'))
    UNION ALL
    SELECT '20261015000000', 'fonction avertissement_conditionnement présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'avertissement_conditionnement'))
    UNION ALL
    SELECT '20261015000000', 'fonction libelle_fiche présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'libelle_fiche'))
    UNION ALL
    SELECT '20261015000000', 'fonction import_ajouter_lignes présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_ajouter_lignes'))
    UNION ALL
    SELECT '20261015000000', 'fonction import_ajouter_lignes : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_ajouter_lignes' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261015000000', 'fonction import_corriger_ligne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_corriger_ligne'))
    UNION ALL
    SELECT '20261015000000', 'fonction import_corriger_ligne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_corriger_ligne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261015000000', 'fonction evaluer_depublication_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'evaluer_depublication_interne'))
    UNION ALL
    SELECT '20261015000000', 'fonction evaluer_depublication_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'evaluer_depublication_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261015000000', 'fonction evaluer_depublication_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'evaluer_depublication_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261015000000', 'fonction import_annuler_lot présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_annuler_lot'))
    UNION ALL
    SELECT '20261015000000', 'fonction import_annuler_lot : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'import_annuler_lot' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261015000000', 'colonne medicaments.conditionnement présente', (EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='medicaments' AND column_name='conditionnement'))
    UNION ALL
    SELECT '20261015000000', 'index uq_medicaments_nom_dosage : inclut le conditionnement', (COALESCE((SELECT indexdef ILIKE '%conditionnement%' AND indexdef ILIKE '%UNIQUE%' FROM pg_indexes WHERE schemaname='public' AND indexname='uq_medicaments_nom_dosage'), false))
    UNION ALL
    SELECT '20261016000000', 'table lots_pharmacies présente', (to_regclass('public.lots_pharmacies') IS NOT NULL)
    UNION ALL
    SELECT '20261016000000', 'table lots_pharmacies : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.lots_pharmacies')), false))
    UNION ALL
    SELECT '20261016000000', 'table lignes_lots_pharmacies présente', (to_regclass('public.lignes_lots_pharmacies') IS NOT NULL)
    UNION ALL
    SELECT '20261016000000', 'table lignes_lots_pharmacies : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.lignes_lots_pharmacies')), false))
    UNION ALL
    SELECT '20261016000000', 'table identites_pharmacies présente', (to_regclass('public.identites_pharmacies') IS NOT NULL)
    UNION ALL
    SELECT '20261016000000', 'table identites_pharmacies : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.identites_pharmacies')), false))
    UNION ALL
    SELECT '20261016000000', 'table checklist_verification_pharmacie présente', (to_regclass('public.checklist_verification_pharmacie') IS NOT NULL)
    UNION ALL
    SELECT '20261016000000', 'table checklist_verification_pharmacie : RLS activée', (COALESCE((SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.checklist_verification_pharmacie')), false))
    UNION ALL
    SELECT '20261016000000', 'fonction garde_verification_pharmacie présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'garde_verification_pharmacie'))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_creer_lot présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_creer_lot'))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_creer_lot : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_creer_lot' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction lot_pharmacies_admin présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'lot_pharmacies_admin'))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_ajouter_lignes présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_ajouter_lignes'))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_ajouter_lignes : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_ajouter_lignes' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_compter_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_compter_interne'))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_compter_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_compter_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_compter_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_compter_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_finaliser_lot présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_finaliser_lot'))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_finaliser_lot : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_finaliser_lot' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_lire_lot présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_lire_lot'))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_lire_lot : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_lire_lot' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_corriger_ligne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_corriger_ligne'))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_corriger_ligne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_corriger_ligne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_valider_lot présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_valider_lot'))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_valider_lot : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_valider_lot' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_annuler_lot présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_annuler_lot'))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_annuler_lot : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_annuler_lot' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_abandonner_lot présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_abandonner_lot'))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_abandonner_lot : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_abandonner_lot' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_historique présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_historique'))
    UNION ALL
    SELECT '20261016000000', 'fonction pm_historique : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'pm_historique' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction admin_pharmacies_a_verifier présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_pharmacies_a_verifier'))
    UNION ALL
    SELECT '20261016000000', 'fonction admin_pharmacies_a_verifier : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_pharmacies_a_verifier' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction admin_pharmacies_a_inviter présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_pharmacies_a_inviter'))
    UNION ALL
    SELECT '20261016000000', 'fonction admin_pharmacies_a_inviter : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_pharmacies_a_inviter' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction admin_detail_verification présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_detail_verification'))
    UNION ALL
    SELECT '20261016000000', 'fonction admin_detail_verification : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_detail_verification' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction admin_basculer_checklist_pharmacie présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_basculer_checklist_pharmacie'))
    UNION ALL
    SELECT '20261016000000', 'fonction admin_basculer_checklist_pharmacie : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_basculer_checklist_pharmacie' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction admin_verifier_pharmacie présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_verifier_pharmacie'))
    UNION ALL
    SELECT '20261016000000', 'fonction admin_verifier_pharmacie : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'admin_verifier_pharmacie' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction inviter_pharmacie_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'inviter_pharmacie_interne'))
    UNION ALL
    SELECT '20261016000000', 'fonction inviter_pharmacie_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'inviter_pharmacie_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction inviter_pharmacie_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'inviter_pharmacie_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction consommer_jeton_activation_interne présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'consommer_jeton_activation_interne'))
    UNION ALL
    SELECT '20261016000000', 'fonction consommer_jeton_activation_interne : fermée à anon', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'consommer_jeton_activation_interne' AND has_function_privilege('anon', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction consommer_jeton_activation_interne : réservée au serveur (fermée aux utilisateurs connectés)', (NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'consommer_jeton_activation_interne' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')))
    UNION ALL
    SELECT '20261016000000', 'fonction reinitialiser_demo présente', (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'reinitialiser_demo'))
    UNION ALL
    SELECT '20261016000000', 'garde de vérification des pharmacies créées en masse (déclencheur)', (EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_pharmacies_garde_verification' AND tgrelid = to_regclass('public.pharmacies')))
    UNION ALL
    SELECT '20261016000000', 'jetons_activation : cible = demande OU pharmacie (contrainte)', (EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'jetons_activation_cible'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur notifications_outbox', (to_regclass('public.notifications_outbox') IS NOT NULL AND NOT has_table_privilege('anon', 'public.notifications_outbox', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur alertes_routage', (to_regclass('public.alertes_routage') IS NOT NULL AND NOT has_table_privilege('anon', 'public.alertes_routage', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur envois_alerte', (to_regclass('public.envois_alerte') IS NOT NULL AND NOT has_table_privilege('anon', 'public.envois_alerte', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur reponses_alerte', (to_regclass('public.reponses_alerte') IS NOT NULL AND NOT has_table_privilege('anon', 'public.reponses_alerte', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur jetons_telegram', (to_regclass('public.jetons_telegram') IS NOT NULL AND NOT has_table_privilege('anon', 'public.jetons_telegram', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur patients_bloques', (to_regclass('public.patients_bloques') IS NOT NULL AND NOT has_table_privilege('anon', 'public.patients_bloques', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur demandes_partenaire', (to_regclass('public.demandes_partenaire') IS NOT NULL AND NOT has_table_privilege('anon', 'public.demandes_partenaire', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur documents_demande', (to_regclass('public.documents_demande') IS NOT NULL AND NOT has_table_privilege('anon', 'public.documents_demande', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur checklist_demande', (to_regclass('public.checklist_demande') IS NOT NULL AND NOT has_table_privilege('anon', 'public.checklist_demande', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur evenements_onboarding', (to_regclass('public.evenements_onboarding') IS NOT NULL AND NOT has_table_privilege('anon', 'public.evenements_onboarding', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur jetons_activation', (to_regclass('public.jetons_activation') IS NOT NULL AND NOT has_table_privilege('anon', 'public.jetons_activation', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur lots_import', (to_regclass('public.lots_import') IS NOT NULL AND NOT has_table_privilege('anon', 'public.lots_import', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur lignes_import', (to_regclass('public.lignes_import') IS NOT NULL AND NOT has_table_privilege('anon', 'public.lignes_import', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur lots_pharmacies', (to_regclass('public.lots_pharmacies') IS NOT NULL AND NOT has_table_privilege('anon', 'public.lots_pharmacies', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur lignes_lots_pharmacies', (to_regclass('public.lignes_lots_pharmacies') IS NOT NULL AND NOT has_table_privilege('anon', 'public.lignes_lots_pharmacies', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur identites_pharmacies', (to_regclass('public.identites_pharmacies') IS NOT NULL AND NOT has_table_privilege('anon', 'public.identites_pharmacies', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur checklist_verification_pharmacie', (to_regclass('public.checklist_verification_pharmacie') IS NOT NULL AND NOT has_table_privilege('anon', 'public.checklist_verification_pharmacie', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur rappels_onboarding', (to_regclass('public.rappels_onboarding') IS NOT NULL AND NOT has_table_privilege('anon', 'public.rappels_onboarding', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur journal_admin_alertes', (to_regclass('public.journal_admin_alertes') IS NOT NULL AND NOT has_table_privilege('anon', 'public.journal_admin_alertes', 'SELECT'))
    UNION ALL
    SELECT 'sécurité', 'anon : aucun droit de lecture sur ordres_admin_alertes', (to_regclass('public.ordres_admin_alertes') IS NOT NULL AND NOT has_table_privilege('anon', 'public.ordres_admin_alertes', 'SELECT'))
)
SELECT 0 AS n, 'BILAN' AS migration,
       count(*) FILTER (WHERE NOT ok)::text || ' contrôle(s) en échec sur ' || count(*)::text AS controle,
       (count(*) FILTER (WHERE NOT ok) = 0) AS ok
  FROM controles
UNION ALL
SELECT row_number() OVER (ORDER BY migration, controle), migration, controle, ok FROM controles
UNION ALL
SELECT 10000, 'info', 'mode_application : ' || (CASE WHEN to_regclass('public.config_routage') IS NOT NULL THEN COALESCE((xpath('/row/v/text()', query_to_xml('SELECT valeur::text AS v FROM public.config_routage WHERE cle = ''mode_application''', false, true, '')))[1]::text, '?') ELSE 'config_routage absente' END), NULL::boolean
UNION ALL
SELECT 10001, 'info', 'fiches du catalogue : total / restreintes / non restreintes / archivées : ' || (CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='medicaments' AND column_name='restreint') AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='medicaments' AND column_name='statut_catalogue') THEN COALESCE((xpath('/row/v/text()', query_to_xml('SELECT count(*) || '' / '' || count(*) FILTER (WHERE restreint) || '' / '' || count(*) FILTER (WHERE NOT restreint) || '' / '' || count(*) FILTER (WHERE statut_catalogue = ''archive'') AS v FROM public.medicaments', false, true, '')))[1]::text, '?') ELSE 'migration 20261004000000 pas encore appliquée' END), NULL::boolean
UNION ALL
SELECT 10002, 'info', 'fiches avec classification validée par un pharmacien : ' || (CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='medicaments' AND column_name='classification_validee_le') THEN COALESCE((xpath('/row/v/text()', query_to_xml('SELECT count(*) AS v FROM public.medicaments WHERE classification_validee_le IS NOT NULL', false, true, '')))[1]::text, '?') ELSE 'n/a' END), NULL::boolean
UNION ALL
SELECT 10003, 'info', 'pharmacies : total / vérifiées / publiées / de démonstration : ' || (CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='pharmacies' AND column_name='est_publiee') AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='pharmacies' AND column_name='est_demo') THEN COALESCE((xpath('/row/v/text()', query_to_xml('SELECT count(*) || '' / '' || count(*) FILTER (WHERE statut = ''verifie'') || '' / '' || count(*) FILTER (WHERE est_publiee) || '' / '' || count(*) FILTER (WHERE est_demo) AS v FROM public.pharmacies', false, true, '')))[1]::text, '?') ELSE 'migration 20261004010000 pas encore appliquée' END), NULL::boolean
UNION ALL
SELECT 10004, 'info', 'conditions de passage en production non remplies : ' || (CASE WHEN to_regprocedure('public.conditions_passage_production()') IS NOT NULL THEN COALESCE(NULLIF((xpath('/row/v/text()', query_to_xml('SELECT string_agg(cle, '', '') AS v FROM public.conditions_passage_production() WHERE NOT ok', false, true, '')))[1]::text, ''), 'aucune') ELSE 'n/a' END), NULL::boolean
UNION ALL
SELECT 10005, 'info', 'comptes de test (liste blanche) / contacts Telegram activés : ' || (CASE WHEN to_regclass('public.contacts_pharmacie') IS NOT NULL THEN COALESCE((xpath('/row/v/text()', query_to_xml('SELECT count(*) FILTER (WHERE est_contact_demo) || '' / '' || count(*) FILTER (WHERE canal = ''telegram'' AND verifie_le IS NOT NULL) AS v FROM public.contacts_pharmacie', false, true, '')))[1]::text, '?') ELSE 'n/a' END), NULL::boolean
ORDER BY 1;

ROLLBACK;
