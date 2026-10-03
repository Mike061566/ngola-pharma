# Correspondance spec (anglais) → dépôt (français)

Décision du propriétaire : on **garde les noms français** du dépôt. Les specs gardent leurs noms anglais ;
ce tableau fait foi pour le code. Les clés de `config_routage` sont traduites aussi (la spec dit `wave1_size`, le dépôt `vague1_taille`).

## Tables et vues

| Spec | Dépôt | Remarque |
|---|---|---|
| `drug_catalog` | `medicaments` (+ vue `drug_catalog`, lecture seule) | colonnes ajoutées PR 1 |
| `stock_items` | `stocks` (+ vue `stock_items`, lecture seule) | `statut_stock` ↔ `en_stock` synchronisés par trigger |
| `pharmacy_contacts` | `contacts_pharmacie` | écriture côté serveur uniquement |
| `catalog_classification_validations` | `validations_classification` | pas d'UPDATE ni de DELETE |
| `drug_aliases` | `alias_medicaments` | |
| `catalog_requests` | `demandes_catalogue` | |
| `routing_config` | `config_routage` | |
| `alerts` | `alertes_routage` | `alertes_stock` (site public) inchangée |
| `alert_dispatches` | `envois_alerte` | |
| `alert_responses` | `reponses_alerte` | |
| `notification_outbox` | `notifications_outbox` | |
| `telegram_link_tokens` | `jetons_telegram` | |
| `patient_blocklist` | `patients_bloques` | |
| `pharmacy_alert_view` | `vue_alertes_pharmacie` | pharmacie uniquement, sans donnée patient |
| état d'onboarding | `etat_onboarding_pharmacie` | table à part |

## Colonnes

| Spec | Dépôt |
|---|---|
| `restricted` | `medicaments.restreint` (défaut `true`) |
| `requires_prescription` | `medicaments.ordonnance` |
| `classification_validated_at` | `medicaments.classification_validee_le` |
| `is_demo` | `est_demo` (medicaments, pharmacies) |
| `is_published` | `pharmacies.est_publiee` (+ `publiee_le`) ; CHECK : seulement si `statut = 'verifie'` |
| `status` (catalogue) | `statut_catalogue` (`actif`/`archive`) |
| `is_demo_contact` | `contacts_pharmacie.est_contact_demo` |
| `verification_status = verifie` | `pharmacies.statut = 'verifie'` (+ valeur `suspendu` ajoutée) |

## Clés de configuration (`config_routage`)

`wave1_size`→`vague1_taille`, `wave2_size`→`vague2_taille`, `wave2_delay_min`→`vague2_delai_min`, `escalate_min`→`escalade_min`,
`expire_min`→`expiration_min`, `aggregation_window_s`→`fenetre_agregation_s`, `max_dispatch_per_hour`→`max_envois_par_heure`,
`out_fresh_days`→`rupture_recente_jours`, `score_weights`→`score_poids`, `daily_message_budget`→`budget_messages_jour`,
`urgent_delay_factor`→`facteur_delai_urgent`, `sms_nudge_after_min`→`relance_sms_apres_min`,
`max_telegram_contacts_per_pharmacy`→`max_contacts_telegram_par_pharmacie`, `app_mode`→`mode_application` (`demo`|`production`),
`demo_time_factor`→`facteur_temps_demo`. Ajout : `fournisseur_telegram_reel` (condition (d) du passage en production).

Les **valeurs** de statut (`new`, `routing`, `sent`, `queued`, `telegram`...) restent celles de la spec : ce sont des codes, pas des noms.

## Fonctions et colonnes ajoutées (PR 2 à 4)

| Spec | Dépôt |
|---|---|
| fournisseur de canal (`ChannelProvider`) | `envoyer()` / `modifierMessage()` (`supabase/functions/_shared/fournisseur-mock.js`) |
| `idempotency_key` | `notifications_outbox.cle_idempotence` (`<cle_base>:<canal>:<modele>[:<contact>]`) |
| `template_key` | `notifications_outbox.modele` |
| `contact.blocked` | `contacts_pharmacie.bloque_le` |
| `public_id` | `alertes_routage.id_public` (`NG-XXXXXXXX`) |
| `patient_hash` | `alertes_routage.empreinte_patient` (HMAC du numéro, sinon de l'IP) ; `empreinte_ip` pour la limite par IP |
| `needs_review` (raison) | `alertes_routage.raison_revue` (`restreint`, `non_reconnu`, `classification_non_validee`) |
| `dispatch.short_id` (callback Telegram) | 8 premiers caractères hexadécimaux de `envois_alerte.id` |
| `sms_nudge_after_min` | `config_routage.relance_sms_apres_min` ; `envois_alerte.relance_sms_le` |
| création d'alerte | fonction SQL `creer_alerte_routage` (service role) |
| `planDispatch` | `supabase/functions/_shared/routage.js` |
| `alert_responses.via` | `reponses_alerte.canal` (`telegram`, `link`, `dashboard`, `admin`) |
| `telegram_link_tokens` consommation | fonction SQL `consommer_jeton_telegram` |
| enregistrement d'une réponse | fonction SQL `enregistrer_reponse_alerte` ; depuis l'Espace Pro : `repondre_alerte` |
| activation Telegram / SMS d'une pharmacie | `activer_telegram_pharmacie`, `ajouter_contact_sms`, `changer_abonnement_contact` |
| `opted_out_at` | `contacts_pharmacie.desabonne_le` |
| `/api/admin/alerts` (liste, chronologie) | fonctions SQL `file_alertes_admin`, `chronologie_alerte` |
| `/api/admin/alerts/:id/{dispatch,cancel,close,reroute,approve}` | `admin_transmettre`, `admin_annuler_alerte`, `admin_cloturer_alerte`, `admin_relancer_vague`, `admin_rattacher_medicament` (+ `admin_refuser_alerte`, `admin_retirer_destinataire`, `admin_bloquer_patient`) |
| `/api/admin/routing-config` | table `config_routage` (validation `erreur_valeur_config`, journal `config_routage_journal`) |
| `/api/admin/alerts/metrics` | `indicateurs_alertes`, `etat_budget_messages` |
| journal d'audit admin | `journal_admin_alertes` ; ordres exécutés par le planificateur : `ordres_admin_alertes` |
| `seed/demo_catalog.csv` (`dci, brand_name, strength, form, pack_size, requires_prescription, restricted`) | `supabase/seed/demo_catalog.csv` ; chargé par `src/utils/demo-catalog.js` (`restricted` jamais déduit) |
| `scripts/demo-reset.js` | `scripts/demo-reset.js` + fonction SQL `reinitialiser_demo` (refusée hors démo) |
| `app_mode` lisible par la bannière | fonction publique `mode_public()` |
| `is_demo_contact` géré par l'admin | `admin_marquer_contact_demo`, `admin_activer_telegram_demo`, `admin_liste_contacts` |
| messages `suppressed_demo` visibles | `file_messages_demo` |
