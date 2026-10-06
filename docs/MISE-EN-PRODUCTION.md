# Liste de contrôle de mise en production (pilote en mode démo)

> **Qui fait quoi.** Tout ce document s'exécute **par vous**, à la main. Claude n'exécute rien en production et n'a accès à aucune clé.
> **Ce qu'il couvre** : mettre en ligne tout le travail de la PR #4 (migrations, fonctions, planificateurs, bot Telegram, site) et lancer le **pilote avec les pharmaciens en mode démo** (`mode_application = demo` : envois réels uniquement vers les comptes de la liste blanche).
> **Ce qu'il ne couvre pas** : le passage en mode `production` (voir la phase K) ni les SMS Orange (reportés).
> Cochez chaque case ; à la moindre case en échec, **arrêtez-vous** (colonne « Si ça échoue »). Notez le journal de l'opération (modèle en fin de document).

Commit à déployer : **le dernier de la branche `claude/friendly-albattani-4yd1y8` dont la CI est verte** (`git log -1 --format=%h`). Notez-le : `__________`

---

## Phase A — Préparation (la veille ou au moins 1 h avant)

- [ ] **A1. Sauvegarde fraîche et restaurable.** Dashboard Supabase → Database → Backups (ou point de restauration PITR si votre offre l'inclut), sinon `pg_dump` complet. Notez la date/heure et la taille. **Aucune migration sans sauvegarde de moins d'une heure.** *Si ça échoue : ne rien exécuter.*
- [ ] **A2. Gel.** Aucune autre modification de la base ni du site pendant l'opération. Prévoir 2 h sans interruption.
- [ ] **A3. CI verte** sur le commit à déployer (3 jobs : Node 20, Node 22, Base de données). Le job « Base de données » rejoue **toutes** les migrations sur un vrai Supabase local et le script de vérification de la phase D.
- [ ] **A4. Extensions.** `postgis` et `pg_trgm` (déjà présentes). Pour la phase G : `pg_cron`, `pg_net` et **Vault** (Dashboard → Database → Extensions).
- [ ] **A5. État de la production = baseline.** (lecture seule)
  1. SQL Editor : coller `supabase/diagnostics/schema_inventory.sql`, exporter la colonne `ligne` en CSV (`prod_inventory.csv`).
  2. `git show 941f4fe:supabase/baseline/inventory.expected.txt > /tmp/attendu_baseline.txt`
  3. `node scripts/compare-schema.js prod_inventory.csv /tmp/attendu_baseline.txt`
  4. **Attendu** : aucun objet manquant ni différent (les « en trop » et les contraintes `NOT VALID` sont des informations).
  *Si ça échoue : la production n'est pas dans l'état supposé ; ne pas migrer, me renvoyer le résultat.*
- [ ] **A6. Ne jamais rejouer** : `20261003000000_baseline.sql` (déjà en production), `supabase/legacy/*`, `supabase/applied/*`.
- [ ] **A7. Domaines connus** : URL du projet Supabase `https://<ref>.supabase.co`, URL publique du site (Netlify ou domaine personnalisé) : `__________`.

## Phase B — Catalogue de test : repartir d'un catalogue unique (décision du propriétaire : pas de fusion)

**État constaté en production (06/10/2026) :** 40 lignes dans `medicaments` = 20 médicaments × 2 exécutions du seed (12/09 et 22/09), 24 fiches référencées par des stocks. L'unicité des migrations (`uq_medicaments_nom_dosage`) échouerait sur ces doublons.
**Choix retenu : pas de fusion.** Les 40 fiches de test sont retirées, puis le catalogue de 236 fiches est chargé (phase I). La migration de fusion `20261003100000` reste dans la chaîne (historique versionné) mais ne fait **rien** sur un catalogue sans doublon (vérifié : 0 fiche supprimée).
**Elle s'exécute AVANT les migrations de la phase C.**

- [ ] **B0. `supabase/ops/remplacer_catalogue_test.sql`** — d'abord en **simulation** (aucune écriture), relire le rapport : attendu **40 fiches supprimées**, `fiches_restantes` = les fiches qui ne viennent pas du seed (souvent 0). Les stocks liés (données de test) sont supprimés ; les demandes patient `alertes_stock` sont **détachées** (le nom saisi est conservé). Une sauvegarde complète va dans le schéma `sauvegarde_remplacement`. Le script s'arrête sans rien modifier au-delà de 40 correspondances. Si les stocks concernent de **vraies** pharmacies, ne pas continuer. Puis remplacer `ROLLBACK` par `COMMIT`. Retour : bloc en fin de fichier (valable tant que la phase C n'a pas commencé).
- [ ] **B1.** `supabase/migrations/20261003100000_fusion_doublons_medicaments.sql` (une transaction). Avec un catalogue sans doublon, le rapport doit afficher `fiches supprimées = 0`. Il ne reste plus rien à fusionner.
- [ ] **B2.** `supabase/diagnostics/fusion_doublons_verification.sql` : toutes les lignes `ok = true`.
- [ ] **B3. Point de non-retour partiel.** Le retour arrière de B0 **n'est valable qu'avant** la phase C. Ensuite, le seul retour arrière est la **restauration de la sauvegarde** (A1).
- [ ] **B4.** Les schémas `sauvegarde_remplacement` et `sauvegarde_fusion` ne sont purgés (`DROP SCHEMA … CASCADE;`) qu'après la fin du pilote.

## Phase C — Migrations 20261004 → 20261016 (une par une, dans l'ordre)

Méthode : SQL Editor, **un fichier à la fois**, en collant le contenu intégral (chaque fichier contient son propre `BEGIN … COMMIT` : en cas d'erreur, il n'a rien changé). Après **chaque** fichier : lancer `supabase/diagnostics/verification_post_migrations.sql` — les contrôles du fichier qui vient de passer doivent être `true` (les suivants sont `false` tant qu'ils ne sont pas appliqués : normal).

| # | Fichier | Ce qu'il fait | À savoir |
|---|---|---|---|
| 1 | `20261004000000_catalogue_classification` | colonnes de classification, validations, alias, vue `drug_catalog` | **Marque toutes les fiches actuelles `est_demo = true` et `restreint = true`** (voulu : rien n'est routable avant validation par un pharmacien) |
| 2 | `20261004010000_stocks_pharmacies_contacts` | statut détaillé des stocks, publication, contacts de messagerie | **Met à jour toutes les lignes de `stocks`** (`statut_stock`, `confirme_le`) ; une pharmacie ne peut être publiée que si elle est vérifiée |
| 3 | `20261004020000_alertes_routage` | alertes, envois, réponses, outbox, configuration, **verrou du passage en production** | `mode_application = demo` par défaut |
| 4 | `20261005000000_outbox_worker` | prélèvement de l'outbox, budget de messages | n'envoie rien |
| 5 | `20261006000000_routage_parametres` | seuils du moteur de routage | ne remplace jamais une valeur modifiée |
| 6 | `20261007000000_creation_alertes` | création d'alertes (serveur seulement) | n'envoie rien |
| 7 | `20261008000000_reponses_alertes` | réponses des pharmacies, activation Telegram | n'envoie rien |
| 8 | `20261009000000_console_admin_alertes` | console admin, indicateurs, journal | admin seul |
| 9 | `20261010000000_mode_demo` | bannière, liste blanche, remise à zéro de la démo | voir la mise en garde sur `reinitialiser_demo` (phase I) |
| 10 | `20261011000000_onboarding_demandes` | pré-inscription, justificatifs (bucket **privé**), checklist, activation | crée le bucket `documents-demandes` |
| 11 | `20261012000000_onboarding_checklist` | checklist de l'Espace Pro, règle de publication | remplace `admin_detail_demande` |
| 12 | `20261013000000_import_stocks` | import guidé des stocks | **remesurer la durée d'un import de 500 lignes** sur le vrai catalogue |
| 13 | `20261014000000_rappels_onboarding` | rappels J+1/J+3/J+7 | n'envoie rien tant que le planificateur n'est pas créé |
| 14 | `20261015000000_conditionnement_depublication` | colonne `conditionnement`, unicité nom + dosage + conditionnement, dépublication à l'annulation d'import | **recrée l'index `uq_medicaments_nom_dosage`** (plus permissif) ; ne touche à aucune classification |
| 15 | `20261016000000_pharmacies_en_masse` | création en masse, vérification imposée, invitation | remplace `reinitialiser_demo` et `consommer_jeton_activation_interne`, rend `jetons_activation.demande_id` facultatif |

- [ ] **C1.** Les 15 fichiers appliqués, sans erreur, dans l'ordre.
- [ ] **C2.** Si un fichier échoue : **ne pas passer au suivant**, ne pas « corriger à la main ». Copier le message d'erreur exact (sans valeur sensible) et me l'envoyer. Les fichiers déjà passés restent valables.
- [ ] **C3. Aucun retour arrière par script** n'existe pour ces 15 migrations (elles sont additives ; seule la fusion en a un). Retour arrière = **restauration de la sauvegarde A1** (perte des écritures faites depuis). À décider *avant* de commencer : durée maximale acceptée ____ min, personne qui décide ____.

## Phase D — Vérifications après migrations

- [ ] **D1.** `supabase/diagnostics/verification_post_migrations.sql` : la ligne **BILAN** doit afficher « **0 contrôle(s) en échec** » (≈ 298 contrôles : tables, RLS, fonctions, droits `anon`/`authenticated`, bucket privé, valeurs par défaut sûres). Les lignes « info » ne sont pas des échecs : relever `mode_application` (attendu `"demo"`), le nombre de fiches (attendu : toutes restreintes, 0 validée), les conditions de passage en production non remplies (attendu : `validation_pharmacien`, `pharmacie_reelle_verifiee`, `fournisseur_telegram_reel`).
- [ ] **D2.** Comparaison structurelle complète : `schema_inventory.sql` → CSV → `node scripts/compare-schema.js prod_inventory2.csv` (cette fois **sans** 2ᵉ argument : le fichier courant `inventory.expected.txt` décrit le schéma après toutes les migrations). Attendu : aucun manquant, aucune différence.
- [ ] **D3. Le site actuel fonctionne encore** (les migrations sont rétro-compatibles) : recherche publique, connexion à l'Espace Pro (compte pharmacien et compte admin), « Mes Stocks ».
- [ ] **D4.** Bannière « MODE DÉMO » visible sur le site : **attendu pendant tout le pilote**.
- [ ] **D5. Garde-fou réglementaire** : dans la console admin → Classification, **aucune fiche** n'est non restreinte (c'est à votre pharmacien validateur de décider, jamais à l'application).

## Phase E — Secrets et configuration (jamais dans le dépôt ni dans le chat)

Dashboard → Edge Functions → Secrets. Les valeurs vont dans votre gestionnaire de mots de passe, **pas ailleurs**.

| Variable | Rôle | Génération / remarque |
|---|---|---|
| `CRON_SECRET` | authentifie les appels des planificateurs | `openssl rand -base64 32` ; **même valeur** dans Vault (`cron_secret`) |
| `ENCRYPTION_KEY` | chiffre les adresses de contact (AES-256-GCM) | `openssl rand -base64 32` ; **sauvegardez-la** : sans elle les adresses chiffrées sont illisibles ; ne la changez jamais sans migrer les données |
| `SIGNING_SECRET` | empreintes (HMAC) des numéros et IP | `openssl rand -base64 48` ; le changer invalide les limites et la liste de blocage existantes |
| `CAPTCHA_PROVIDER` | `turnstile` | le captcha simulé est **refusé** hors mode démo, mais accepté en démo : mettre `turnstile` dès le pilote public |
| `CAPTCHA_SECRET` | secret Cloudflare Turnstile | + **clé de site** (publique) dans `public/alerte-config.js` → `turnstileSiteKey` (à commiter avant la phase H) |
| `ALLOWED_ORIGINS` | origines autorisées (CORS) | `https://<site>` séparées par des virgules ; sans slash final |
| `APP_BASE_URL` | liens des emails et messages | `https://<site>` sans slash final |
| `TELEGRAM_PROVIDER` | `telegram` | absent = mock (rien ne part) |
| `TELEGRAM_BOT_TOKEN` | jeton du bot (BotFather) | `@ngola_pharma_Bot` ; en cas de fuite : le révoquer chez BotFather |
| `TELEGRAM_WEBHOOK_SECRET` | secret du webhook | 16 à 256 caractères parmi `A-Za-z0-9_-` |
| `TELEGRAM_BOT_USERNAME` | `ngola_pharma_Bot` | public |
| `ADMIN_ALERT_EMAIL` | destinataire des alertes admin | **voir la mise en garde sur les emails en mode démo** |
| `ALERT_AUTO_ROUTING` | interrupteur du routage automatique | **`false` jusqu'au GO (phase J)**, puis `true` |
| `EMAIL_PROVIDER` | `zeptomail` (ou absent = mock) | |
| `ZEPTOMAIL_TOKEN`, `EMAIL_FROM_ADDRESS`, `EMAIL_FROM_NAME`, `ZEPTOMAIL_HOST` | email transactionnel | domaine d'envoi **vérifié (SPF/DKIM)** chez ZeptoMail ; `ZEPTOMAIL_HOST` selon la région du compte |
| `SMS_PROVIDER` | **laisser absent** (mock) | adaptateur Orange reporté |
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | fournies par Supabase | ne jamais les copier ailleurs |

- [ ] **E1.** Toutes les variables posées (celles marquées « absent = mock » peuvent attendre).
- [ ] **E2.** Supabase Auth → URL Configuration → **Redirect URLs** : ajouter `<APP_BASE_URL>/pro.html` (sinon le lien de connexion après activation de compte est refusé).
- [ ] **E3.** Storage : le bucket `documents-demandes` existe et est **privé** (déjà contrôlé en D1).
- [ ] **E4.** Cloudflare Turnstile : site créé pour votre domaine ; clé de site renseignée (voir ci-dessus).

## Phase F — Déploiement des 14 Edge Functions et du webhook Telegram

Toutes ont `verify_jwt = false` dans `supabase/config.toml` (l'authentification est faite dans le code).

```
supabase functions deploy <nom> --project-ref <ref>
```

| Accès | Fonctions |
|---|---|
| public (captcha, jeton signé, code) | `creer-alerte`, `suivi-alerte`, `repondre-lien`, `creer-demande`, `repondre-complements`, `activer-compte`, `webhook-telegram` (secret du webhook) |
| admin (jeton de session vérifié) | `decider-demande`, `url-document`, `inviter-pharmacie` |
| pharmacien (jeton de session) | `tester-contact` |
| planificateurs (`x-cron-secret`) | `traiter-outbox`, `planifier-alertes`, `rappels-onboarding` |

- [ ] **F1.** Les 14 fonctions déployées.
- [ ] **F2. Fumée sans secret** (aucun accès ne doit être possible) : `curl -i -X POST https://<ref>.supabase.co/functions/v1/<nom>` →
  `traiter-outbox`, `planifier-alertes`, `rappels-onboarding`, `webhook-telegram` : **401** ; `decider-demande`, `url-document`, `inviter-pharmacie` : **403** ; `tester-contact` : **401** ; `creer-alerte`, `creer-demande`, `activer-compte`, `repondre-complements` : **400** (requête invalide) ; une requête `GET` sur les fonctions en POST : **405**.
- [ ] **F3. Webhook Telegram** (depuis votre poste, secrets en variables d'environnement) :
  1. `WEBHOOK_URL=https://<ref>.supabase.co/functions/v1/webhook-telegram node scripts/telegram-set-webhook.js` → **simulation**, rien n'est envoyé ;
  2. relire, puis `… node scripts/telegram-set-webhook.js --confirmer`.
- [ ] **F4. Bot** : ouvrir `@ngola_pharma_Bot`, `/start` sans jeton → message d'aide du bot (aucune action).

## Phase G — Planificateurs (pg_cron + pg_net, secrets dans Vault)

Rien n'est lancé tant que vous n'exécutez pas ces scripts. **Ordre** :

- [ ] **G1.** Vault (SQL Editor, valeurs saisies à la main) : `select vault.create_secret('<URL>/functions/v1/traiter-outbox', 'url_traiter_outbox');`, idem `url_planifier_alertes` et `url_rappels_onboarding`, et `select vault.create_secret('<valeur de CRON_SECRET>', 'cron_secret');`.
- [ ] **G2.** `supabase/ops/planifier_outbox.sql` (chaque minute).
- [ ] **G3.** `supabase/ops/planifier_alertes.sql` (chaque minute ; **répond « inactif » tant que `ALERT_AUTO_ROUTING` n'est pas `true`**).
- [ ] **G4.** `supabase/ops/planifier_rappels_onboarding.sql` (une fois par jour, 07:00 UTC = 08:00 à Yaoundé).
- [ ] **G5.** `select jobname, schedule, active from cron.job;` → 3 lignes actives ; 2 minutes plus tard, `select status, return_message from cron.job_run_details order by start_time desc limit 6;` → statuts `succeeded`.
- [ ] **G6. Arrêt d'urgence** : `select cron.unschedule('traiter-outbox');` (et `planifier-alertes`, `rappels-onboarding`) ; ou `ALERT_AUTO_ROUTING=false` ; ou console admin → routage manuel.

## Phase H — Site (Netlify)

**À faire en dernier** : le site appelle les fonctions SQL des phases C–G ; un site déployé avant elles afficherait des erreurs dans l'Espace Pro.

- [ ] **H1.** `public/alerte-config.js` : `turnstileSiteKey` renseignée, `telegramBot: 'ngola_pharma_Bot'`, URL et clé « anon » du projet (la clé anon est publique par conception ; **jamais** la clé service).
- [ ] **H2.** Fusionner la PR #4 → déploiement Netlify automatique. Noter l'identifiant du déploiement (pour revenir en arrière : Netlify → Deploys → déploiement précédent → *Publish deploy*).
- [ ] **H3.** Pages à ouvrir : `/` (bannière démo), `/alerte.html`, `/devenir-partenaire.html`, `/activer.html` (sans jeton : message « lien invalide »), `/complements.html` (idem), `/pro.html` (connexion, onglets).
- [ ] **H4.** `/alerte/NG-XXXXXXXX` et `/r/<code>` : redirections du `netlify.toml` (page de suivi, page de réponse).

## Phase I — Données de départ (mode démo)

- [ ] **I1. Archivage des anciennes fiches de test** : **sans objet si B0 a été fait** (les 40 fiches ont déjà été retirées). Sinon : `supabase/ops/archiver_anciennes_fiches_test.sql` — **d'abord en simulation** (le rapport affiche fiches, stocks et alertes liés), puis remplacer `ROLLBACK` par `COMMIT`. Retour : `archiver_anciennes_fiches_test_retour.sql`.
- [ ] **I2. Catalogue de démonstration** : `node scripts/demo-reset.js --confirmer --catalogue supabase/seed/demo_catalog.csv` (variables `SUPABASE_URL` et `SUPABASE_SERVICE_KEY` **dans votre terminal uniquement**).
  ⚠️ **Mise en garde `reinitialiser_demo` / bouton « Remettre la démo à zéro »** : elle efface alertes, messages, jetons et liste de blocage et rétablit les stocks des pharmacies de démonstration. Elle refuse hors mode démo et ne touche pas aux pharmacies réelles ni aux comptes de test, mais **ne la lancez plus une fois le pilote commencé** sans l'avoir décidé.
- [ ] **I3. Classification** : votre pharmacien validateur remplit `supabase/seed/demo_classification.csv` (`restricted`, `requires_prescription`) ; **vous** le commitez ; puis console → « Classification du catalogue » (n° d'Ordre saisi dans le formulaire, jamais dans le dépôt). Sans cela, **aucune alerte n'est routable** (comportement voulu). Relecture : à chaque ajout au catalogue + chaque trimestre.
- [ ] **I4. Comptes de test** : chaque participant ouvre `@ngola_pharma_Bot` via son lien d'activation (Espace Pro → Alertes) ; vous les ajoutez à la liste blanche (console → Comptes de test). Sans `/start`, le bot ne peut pas écrire.
- [ ] **I5. Pharmacies** : création en masse (onglet Pharmacies) si besoin ; vérification une par une (5 cases) ; invitation.

## Phase J — Test de bout en bout (avant d'inviter les pharmaciens) et GO du pilote

- [ ] **J1. Alerte non restreinte** (scénario de `docs/DEMO.md`) : demande patient → message Telegram sur votre compte de test → « Disponible » → stock mis à jour → message au patient. Mettre `ALERT_AUTO_ROUTING=true` seulement pour ce test, après D5/I3.
- [ ] **J2. Alerte sans réponse** : vague 2, puis escalade (réglage `facteur_temps_demo` pour accélérer).
- [ ] **J3. Médicament restreint** : l'alerte part en revue admin, le patient reçoit le message d'attente ; **aucun** envoi à une pharmacie.
- [ ] **J4. Pharmacie hors liste blanche** : message « aurait été envoyé » (jamais envoyé en vrai).
- [ ] **J5. Parcours d'onboarding complet avec une demande fictive** : pré-inscription (fichiers fictifs), revue (5 cases), approbation → **le lien d'activation s'affiche pour vous** (mode démo), activation, checklist, import d'un fichier, confirmation, **publication automatique** ; puis annulation d'import → dépublication auditée.
- [ ] **J6. Rappels** : en mode démo ils passent par l'outbox ; vérifier dans la console (Comptes de test → « aurait été envoyé »).
- [ ] **J7. Surveillance de départ** : console → indicateurs ; `select statut, count(*) from notifications_outbox group by 1;` (aucun message `failed` inattendu) ; journaux des fonctions (Dashboard → Edge Functions → Logs) sans erreur répétée.
- [ ] **J8. GO / NO-GO.** GO si J1–J7 sont verts, si la sauvegarde A1 est conservée et si la personne et le canal d'alerte pour le pilote sont désignés.

### ⚠️ Mise en garde : les emails réels ne sont PAS vérifiables en mode démo

En mode démo, **tout destinataire hors liste blanche est supprimé** (statut `suppressed_demo`, aucun appel au fournisseur) — **y compris les emails au titulaire d'une demande et les alertes à `ADMIN_ALERT_EMAIL`**. Les adaptateurs **Telegram** sont donc testables avec la liste blanche, mais **ZeptoMail ne sera jamais appelé pendant le pilote** : le premier vrai email partira au passage en production. Décision à prendre avant la production : ajouter une exception « admin » (test d'envoi vers `ADMIN_ALERT_EMAIL`), ou accepter ce risque. *(Je peux l'implémenter si vous le souhaitez.)*

## Phase K — Passage en mode `production` (plus tard, pas pour le pilote)

Le verrou de la base refuse le passage tant que les 5 conditions ne sont pas remplies (console → « Classification du catalogue » → liste de contrôle) : 1) au moins une validation de pharmacien enregistrée ; 2) plus aucune fiche de démonstration active ; 3) plus aucune pharmacie de démonstration publiée ; 4) au moins une pharmacie réelle vérifiée ; 5) fournisseur Telegram réel déclaré configuré.

- [ ] Sauvegarde fraîche ; test d'un envoi réel d'email (voir la mise en garde) ; adaptateur SMS décidé ; décision sur les points ouverts de la SPEC 1 §11 ; revue de cette liste.

---

## Retours arrière (récapitulatif)

| Quoi | Comment | Perte |
|---|---|---|
| Fusion des doublons (avant la phase C seulement) | `supabase/rollback/20261003100000_…_rollback.sql` | modifications de stock faites depuis sur les lignes concernées |
| Une migration de la phase C | **restauration de la sauvegarde A1** (aucun script) | toutes les écritures depuis la sauvegarde |
| Fonctions | redéployer la version précédente (`git checkout <commit> -- supabase/functions` puis `supabase functions deploy`) | aucune |
| Planificateurs | `select cron.unschedule('<nom>');` | aucune |
| Routage automatique | `ALERT_AUTO_ROUTING=false` (interrupteur immédiat) ou routage manuel (console) | aucune |
| Webhook Telegram | `https://api.telegram.org/bot<TOKEN>/deleteWebhook` (depuis votre poste) | le bot ne reçoit plus les clics |
| Site | Netlify → déploiement précédent → *Publish deploy* | aucune |
| Archivage des fiches de test | `archiver_anciennes_fiches_test_retour.sql` | aucune |

## Journal de l'opération (à remplir)

| Heure | Action (phase/case) | Résultat (OK / erreur exacte) | Qui |
|---|---|---|---|
| | A1 sauvegarde (heure, taille) | | |
| | | | |

## Ce qui n'est PAS vérifié par le dépôt (à savoir avant de vous lancer)

- Aucune migration n'a tourné sur **votre** base de production : elles ont tourné sur Postgres local et sur le Supabase local de la CI (même schéma de base, **pas vos données**). Les données réelles (catalogue de test retiré, pharmacies, stocks, profils) peuvent révéler un cas non prévu : d'où la sauvegarde et le « une par une ».
- Aucun envoi **réel** Telegram ni ZeptoMail n'a été exécuté, ni aucun appel réel à Cloudflare Turnstile.
- La durée d'un import de 500 lignes n'a été mesurée que sur un catalogue synthétique (≈ 4 s) ; à remesurer (limite de durée des requêtes des utilisateurs connectés).
- L'interface n'a été jouée qu'avec une fausse base (navigateur automatisé) : à parcourir vous-même en phase J.
