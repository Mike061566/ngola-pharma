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
