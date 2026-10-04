# Edge Functions — outbox et worker de notifications (PR 2)

Rien ici n'envoie de message réel : le seul fournisseur existant est `mock` (aucun réseau, journal sans donnée
personnelle). `TELEGRAM_PROVIDER`, `SMS_PROVIDER` et `EMAIL_PROVIDER` valent `mock` par défaut ; toute autre valeur
est refusée tant que les vrais fournisseurs (PR 7) n'existent pas.

## Organisation

| Fichier | Rôle |
|---|---|
| `_shared/modeles.js` | Modèles de messages (SPEC 2 §7) : échappement HTML, SMS en ASCII ≤ 160 car., mention d'ordonnance |
| `_shared/canaux.js` | Canaux, ordre de repli telegram → sms → email, modèles « frères » par canal |
| `_shared/fournisseur-mock.js`, `fournisseurs.js` | Interface `ChannelProvider` + fournisseur `mock` + sélection par variables d'environnement |
| `_shared/chiffrement.js` | AES-256-GCM des adresses (`ENCRYPTION_KEY`, 32 octets base64) |
| `_shared/file-sortie.js` | `enfiler()` : mise en file idempotente (rendu à blanc, adresse chiffrée) |
| `_shared/traitement.js` | Worker : bail, démo, désabonnement, budget, débit, retry, repli |
| `_shared/magasin-supabase.js` | Seul fichier qui connaît les tables |
| `traiter-outbox/index.js` | Point d'entrée HTTP (en-tête `x-cron-secret`) |

Tests : `npm test` (Jest, puis `node --test tests/functions/*.test.mjs`) et pgTAP (`outbox_worker.test.sql`).
Les Edge Functions n'ont pas été exécutées sous Deno dans cette PR : les modules n'utilisent que des API web
standard (`fetch`, `crypto.subtle`, `TextEncoder`) et sont testés sous Node.

## Règles appliquées par le worker (dans l'ordre)

1. Plus de `1 + len(retry_delais_s)` prélèvements -> échec définitif (un message qui plante le worker est borné).
2. **Mode démo** (`mode_application` ≠ `production`, ou absent) : tout destinataire dont `est_destinataire_demo` est faux
   passe en `suppressed_demo`, **sans appel au fournisseur**.
3. Contact désabonné -> `cancelled` ; contact bloqué -> repli.
4. SMS au-delà de `budget_messages_jour` -> `cancelled` (`budget_depasse`), sauf `exempte_budget` (alerte urgente d'une
   pharmacie de garde). Email et Telegram ne sont pas bloqués. Le seuil d'alerte admin à 80 % relève de la console (PR 6).
5. Modèle invalide ou adresse illisible -> échec définitif, sans repli.
6. Débit : 1 message/s par discussion Telegram (report sans compter une tentative), plafond global `debit_global_par_s`.
7. Envoi. Transitoire : relances à +30 s, +2 min, +5 min (`retry_delais_s`) puis échec et repli. Permanent : repli
   immédiat (`bloque` : le contact est marqué `bloque_le`). 429 : report après `retry_after`, sans compter de tentative.

**Repli** (pharmacies seulement) : canal suivant parmi telegram → sms → email, uniquement si un contact actif existe
(non désabonné, non bloqué ; Telegram : vérifié). Une ligne par contact. Les patients n'ont qu'un canal : pas de repli.
La clé d'idempotence est `<cle_base>:<canal>:<modele>:<contact>` (le suffixe contact s'ajoute à la forme de la spec,
`dispatch:canal:modèle`, pour que 3 agents Telegram d'une même pharmacie reçoivent chacun le message).

**Livraison « au moins une fois »** : le prélèvement pose un bail (`worker_bail_s`). Si le worker meurt après l'envoi et
avant l'écriture du statut, le message peut être renvoyé une fois le bail expiré.

**Journaux** : identifiants d'outbox, canal, modèle, code d'erreur. Jamais d'adresse, de texte ni de variables.

## Déploiement (à faire à la main, après relecture)

1. Appliquer `supabase/migrations/20261005000000_outbox_worker.sql`.
2. Secrets de la fonction (Dashboard) : `CRON_SECRET`, `ENCRYPTION_KEY`. Générer la clé : `openssl rand -base64 32`.
   **Sauvegarder la clé hors du dépôt** : sans elle, les adresses en file sont illisibles.
3. `supabase functions deploy traiter-outbox`.
4. `supabase/ops/planifier_outbox.sql` (planification toutes les minutes).

## Moteur de routage (PR 3) — `_shared/routage.js`

`planDispatch(alerte, pharmacies, config, now)` est une **fonction pure** : aucun réseau, base, horloge ni aléa, entrées
jamais modifiées, même entrée = même plan (départages compris). Elle renvoie des **actions** que le planificateur
(PR 4) exécutera : `needs_review`, `envoyer_vague`, `aucun_candidat`, `escalader`, `expirer`, avec l'audit complet
(`detail_score` par critère, rang, pharmacies exclues et raisons) destiné à `envois_alerte.detail_score`.

Interprétations à connaître (la spec ne tranche pas) :
- **Horaires inconnus** (`{}`, absents, illisibles) : jamais « ouverte » ; seule une pharmacie de garde est alors candidate.
  `ouv = fer` : fermé. `fer < ouv` : horaire de nuit (passe minuit). Fuseau : `decalage_horaire_min` (60, UTC+1).
- **Ligne `rupture` ancienne** (≥ 3 j) : incluse « à confirmer », notée comme un stock périmé (+10).
  Ligne `archive` : équivaut à « aucun enregistrement ». Stock `faible` : compté comme en stock.
- **Bonus de garde** (+10) : pharmacie de garde dont les horaires ne couvrent pas l'instant (ou sont inconnus).
- **Quartier adjacent** : liste `alerte.quartiers_adjacents` (aucune table d'adjacence n'existe) ou distance ≤ `rayon_adjacent_km`
  quand les deux positions GPS sont connues.
- **« Rayon élargi » de la vague 2** : non modélisé, car tous les candidats éligibles de la ville sont déjà classés ; la vague 2
  prend simplement les 5 suivants (hors pharmacies déjà sollicitées), réévalués à l'instant T+10 min.
- **Aucun candidat en vague 1** : action `aucun_candidat` + escalade immédiate (personne à solliciter).
- **Urgence** : tous les délais (vague 2, escalade, expiration) sont multipliés par `facteur_delai_urgent` (0,5).
  `facteur_temps_demo` divise les délais **en mode démo seulement**.
- Le garde-fou (`raisonNonRoutable`) reproduit la fonction SQL `medicament_routable` ; `verifierDemarrageRoutage` porte le
  refus de démarrer (production + `ALERT_AUTO_ROUTING=true` + aucune validation pharmacien).

## Création d'alertes et planificateur (PR 4)

| Fichier | Rôle |
|---|---|
| `creer-alerte/index.js` + `_shared/creation-alerte.js` | `POST` public : feature flag, validation en liste blanche, captcha, empreintes HMAC, création atomique |
| `suivi-alerte/index.js` + `_shared/suivi-alerte.js` | `GET ?id=NG-XXXXXXXX` : état de suivi, sans donnée patient |
| `planifier-alertes/index.js` + `_shared/planificateur.js` | Chaque minute : exécute les décisions de `planDispatch` |
| `_shared/captcha.js`, `_shared/http.js`, `_shared/magasin-alertes.js` | Turnstile (ou mock en démo), CORS/IP, accès base |
| `public/alerte.html` (+ `alerte-utils.js`, `alerte-config.js`) | Page patient : formulaire, suivi rafraîchi toutes les 15 s (`/alerte/:id` via `netlify.toml`) |

**Variables d'environnement** (secrets de fonction, jamais dans le dépôt) : `ALERT_AUTO_ROUTING` (`true` pour activer),
`SIGNING_SECRET` (≥ 16 car., HMAC des empreintes), `ENCRYPTION_KEY`, `CAPTCHA_PROVIDER` (`mock` par défaut | `turnstile`),
`CAPTCHA_SECRET`, `ALLOWED_ORIGINS` (origines du site, séparées par des virgules), `APP_BASE_URL`, `TELEGRAM_BOT_USERNAME`,
`ADMIN_ALERT_EMAIL`, `CRON_SECRET`. La clé de SITE Turnstile (publique) se met dans `public/alerte-config.js`.

**Création** (`creer_alerte_routage`, SQL atomique, service role seulement) : liste de blocage → consentement SMS → fusion
(même patient + même médicament < 30 min) → limite de 5 alertes / 24 h par numéro et par IP (la 6e est refusée) → insertion.
Médicament inconnu, restreint ou non routable : statut `needs_review`, jamais routé. Aucun champ d'ordonnance n'est accepté.
Le numéro est chiffré (AES-GCM) ; seules des empreintes HMAC servent à la limitation ; ni numéro ni IP ne sont journalisés.

**Planificateur** : appelle `planDispatch` puis exécute : `needs_review` (message `restricted_attente` si restreint, expiration à
`expire_le`), vagues 1 et 2, escalade (message d'attente au patient + email admin), expiration (message seulement si personne n'a
répondu), agrégation des réponses (fenêtre de 120 s, 3 pharmacies au plus par prix croissant puis distance, un 2e message court
au plus), SMS de relance des alertes `urgent` (jamais `normal`). Idempotent : relancer ne duplique rien.

**À savoir**
- Le canal Telegram du patient n'est utilisable qu'après son `/start` (PR 5) : d'ici là, il suit sa demande sur la page `/alerte/:id`.
- La file `needs_review` est l'ensemble des alertes de ce statut ; les actions admin (rattacher, transmettre, refuser) sont en PR 6.
- Le captcha `mock` n'est accepté qu'en mode démo ; en production il faut `CAPTCHA_PROVIDER=turnstile`.
- Planification : `supabase/ops/planifier_alertes.sql` (à exécuter à la main, après `planifier_outbox.sql`).

## Réponses des pharmacies (PR 5)

| Fichier | Rôle |
|---|---|
| `webhook-telegram/index.js` + `_shared/reponses.js` | Webhook du bot : boutons ✅/❌, `/start <jeton>`, `/stop`, `/aide`, fichiers refusés |
| `repondre-lien/index.js` + `public/reponse.html` | Lien `/r/<code>` (SMS, email, « Préciser le prix ») : GET informations, POST réponse |
| `tester-contact/index.js` + `_shared/test-contact.js` | Test d'envoi vers un contact de SA pharmacie (jeton de session du pharmacien) |
| migration `20261008000000` | `enregistrer_reponse_alerte` (atomique, idempotent), `repondre_alerte`, activation Telegram, réglage des canaux |
| `public/pro.html` (onglet Alertes) | Demandes en attente (prix pré-rempli), historique, temps moyen, canaux : Telegram (lien + QR), SMS, désabonnement, test |

**Une seule porte pour répondre** : `enregistrer_reponse_alerte`. Une réponse = une ligne `reponses_alerte` (contrainte d'unicité par envoi),
l'envoi passe en `responded`, le stock est mis à jour dans la même transaction (Disponible : `en_stock`, prix si saisi, date de confirmation ;
Indisponible : `rupture`), la 1re réponse positive passe l'alerte en `answered`. Rejouer, ou répondre depuis un autre canal, renvoie la
réponse déjà comptée (`deja_traitee`) sans rien modifier. Après expiration : refus. Prix : entier de 1 à `prix_max_fcfa`.
- Disponible **sans prix** et sans ligne de stock : la réponse est comptée, mais aucune ligne n'est créée (le prix est obligatoire).
- Indisponible sans ligne de stock : une ligne `rupture` est créée avec `prix_fcfa = 0` (= inconnu) pour exclure la pharmacie 3 jours (§4.1).

**Webhook Telegram** — variables : `TELEGRAM_WEBHOOK_SECRET` (comparé à `X-Telegram-Bot-Api-Secret-Token`, sinon 401), `ENCRYPTION_KEY`, `SIGNING_SECRET`.
Un clic n'est accepté que si le chat est un contact **vérifié, actif** d'une pharmacie et si le bouton désigne un envoi de CETTE pharmacie.
Sinon : ignoré et journalisé (sans identifiant). Le message cliqué perd ses boutons (« Réponse enregistrée à HH:MM : … ») ; les messages des
collègues passent à « Déjà traitée par un collègue à HH:MM » (jusqu'à 3 agents par pharmacie, la première réponse l'emporte).
`/start <jeton>` : jeton à usage unique et haché (SQL atomique), 72 h pour une pharmacie ; le `chat_id` est lié au contact (plafond de 3 comptes)
ou, pour un patient, enregistré **chiffré** avec son consentement. `/stop` : contacts de pharmacie désabonnés, alertes du patient détachées.
Photo ou document : jamais conservés ni journalisés ; réponse « aucune ordonnance n'est à envoyer ». Groupes : ignorés. Rejeu d'une même mise à jour
(`update_id`) : aucune réponse dupliquée. Les réponses du bot passent par l'outbox (liste blanche de la démo respectée).
`setWebhook` (avec `secret_token`) est un acte d'exploitation de la **PR 7** : rien n'est enregistré auprès de Telegram par cette PR.

**Lien de réponse** : le code (10 caractères aléatoires, ~50 bits) est le secret ; il n'est valable que jusqu'à l'expiration de l'alerte ;
un code inconnu et un code mal formé donnent la même réponse 404. Aucune donnée patient n'est renvoyée. Après une réponse par le lien, les
boutons des messages Telegram de la pharmacie sont retirés.

**Limites connues**
- Une réponse donnée dans l'Espace Pro (appel direct à la base) ne retire pas immédiatement les boutons Telegram des autres agents : un clic
  ultérieur affichera « déjà traitée ». Le SMS de relance, lui, s'arrête dès la réponse.
- Les réponses du bot (activation, `/stop`...) partent au prochain passage du worker (≤ 1 min).
- Un jeton d'activation consommé alors que le plafond de comptes est atteint doit être régénéré.
- `/c/:token` (« Confirmer mes stocks ») n'est pas dans cette PR.

## Console admin des alertes (PR 6)

Onglet « 🛰️ Console alertes » de l'Espace Pro (**rôle admin seulement**, `public/admin-alertes.js` + `admin-utils.js`) et migration
`20261009000000`. Aucune Edge Function nouvelle : la console appelle des **fonctions SQL réservées à l'admin** (`file_alertes_admin`,
`chronologie_alerte`, `indicateurs_alertes`, `etat_budget_messages`, `admin_*`), qui vérifient le rôle (42501 sinon) et journalisent dans
`journal_admin_alertes` (identifiants et compteurs uniquement, jamais de contact).

| Besoin (SPEC 2) | Réalisation |
|---|---|
| File en temps réel | `file_alertes_admin`, rafraîchie toutes les 15 s ; alertes à examiner en tête |
| Chronologie (vagues, destinataires, scores, réponses, coûts) | `chronologie_alerte` : **chaque consultation est journalisée** (§11) ; aucun contact ni empreinte renvoyés |
| Revue `needs_review` (§4.0) | `admin_rattacher_medicament` (routable → repart en `new`, restreint → reste en revue), `admin_transmettre`, `admin_refuser_alerte` |
| Actions §4.5 | ajouter une pharmacie / transmettre, `admin_retirer_destinataire`, `admin_relancer_vague`, `admin_cloturer_alerte`, `admin_annuler_alerte`, `admin_bloquer_patient` (empreintes) |
| Réglages `routing_config` | table `config_routage` éditable ; **valeurs validées par la base** (types, bornes, clés connues, critères de score), changements journalisés (avant / après) ; `mode_application` reste sous le verrou de production |
| Indicateurs §10 | `indicateurs_alertes(jours)` : délai médian, part < 15 min, taux de réponse par pharmacie, activation Telegram, échecs et repli SMS, coût, mises à jour de stock |
| Budget (§6.2) | bandeau à 80 % / 100 % ; le planificateur envoie un email admin (`ADMIN_ALERT_EMAIL`) une fois par jour et par niveau |

**Transmission manuelle et refus** : la base dépose un ordre (`ordres_admin_alertes`) que le **planificateur** exécute dans la minute (il est
seul à détenir la clé de chiffrement : le navigateur ne manipule jamais de contact chiffré). Une alerte transmise passe en `routing` avec
`routage_manuel = true` : **plus aucune vague automatique**, même pour un médicament restreint (le moteur le garantit : `planDispatch`).
Les ordres sont exécutés **même si `ALERT_AUTO_ROUTING` est désactivé** : c'est le « dispatch manuel par l'admin » du comportement actuel.
Seules sont acceptées les pharmacies vérifiées avec un contact actif (et, en production, non « démo ») ; les refus sont motivés.

**À savoir**
- Le coût moyen par alerte vaut 0 tant que le fournisseur ne renseigne pas `cout_estime` (le mock ne le fait pas) ; le nombre de messages payants est exact.
- « Mises à jour de stock issues des alertes » = réponses enregistrées sur un médicament reconnu.
- L'activation Telegram est mesurée sur les pharmacies **publiées** ayant au moins un compte vérifié et actif.

## Mode démo (PR 6bis)

Migration `20261010000000`, `public/demo-banner.js`, `scripts/demo-reset.js`, `src/utils/demo-catalog.js` et le guide `docs/DEMO.md`.
Le mode démo ne contourne jamais le garde-fou : un médicament restreint reste bloqué. `restricted` du catalogue de démonstration est écrit
par le propriétaire dans le CSV (jamais déduit ; vide = restreint). La remise à zéro est une fonction SQL refusée hors mode démo,
rejouable (même empreinte d'état), qui conserve contacts, liste blanche et classification.

## PR 7 — Telegram réel (SMS et email : à brancher)

- `_shared/fournisseur-telegram.js` : Bot API (`sendMessage`, `editMessageText`, `answerCallbackQuery`). 429 → `limite_debit` (`retry_after`) ; 403 / « chat not found » → permanente + contact bloqué ; 5xx/réseau → transitoire. Jeton, adresse et texte ne figurent jamais dans les erreurs. Tests avec `fetch` factice uniquement (aucun réseau).
- Activation (par le propriétaire, jamais en CI) : secrets `TELEGRAM_PROVIDER=telegram`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET`, `TELEGRAM_BOT_USERNAME` ; puis `WEBHOOK_URL=… node scripts/telegram-set-webhook.js --confirmer` (sans `--confirmer` : simulation).
- SMS et email : `SMS_PROVIDER` / `EMAIL_PROVIDER` n'acceptent que `mock` tant que les fournisseurs ne sont pas choisis (valeur inconnue = erreur explicite).
- Bascule en production : `ALERT_AUTO_ROUTING` seulement après validation de la classification par un pharmacien (SPEC 2) ; en mode démo, envois réels limités aux contacts `est_contact_demo`.

### PR 7 — email (ZeptoMail) et décisions du propriétaire

- Email réel : `EMAIL_PROVIDER=zeptomail` + secrets `ZEPTOMAIL_TOKEN`, `EMAIL_FROM_ADDRESS` (domaine vérifié chez ZeptoMail), `EMAIL_FROM_NAME`, `ZEPTOMAIL_HOST` (région du compte, défaut `api.zeptomail.com`). Adaptateur : `_shared/fournisseur-zeptomail.js` (tests sans réseau). **À vérifier sur votre compte** avant l'activation : codes d'erreur réels (la doc ZeptoMail n'était pas consultable ici) ; les erreurs 4xx sont traitées « permanentes sans blocage du contact », les rebonds définitifs viendront d'un webhook de rebond (non fait).
- SMS (Orange API) : **non branché** tant que la couverture MTN/Orange n'est pas confirmée par le propriétaire ; budget fixé à 50 SMS/jour (réglage existant de la console admin). `SMS_PROVIDER` n'accepte que `mock` d'ici là.
- Bot Telegram public : `@ngola_pharma_Bot` (`telegramBot` dans `public/alerte-config.js`, secret `TELEGRAM_BOT_USERNAME=ngola_pharma_Bot`). Le jeton n'est jamais dans le dépôt.
- Validation de la classification : validateur = Admin (n° d'Ordre saisi dans le formulaire « Classification du catalogue », jamais dans le dépôt) ; relecture à chaque ajout au catalogue + chaque trimestre. `supabase/seed/demo_classification.csv` est commité par le propriétaire après validation.
- Archivage des 20 anciennes fiches de test : `supabase/ops/archiver_anciennes_fiches_test.sql` (simulation par défaut, `COMMIT` à la main, après sauvegarde) et `..._retour.sql` pour revenir en arrière. Testé en local (simulation sans écriture, archivage, retour).

## Onboarding des officines — étape 1 : pré-inscription, vérification, décisions, activation (SPEC 1 §3–5)

Migration `20261011000000_onboarding_demandes.sql` (à exécuter à la main, après `20261010000000`) ; 5 Edge Functions ; pages `devenir-partenaire.html`, `activer.html`, `complements.html` ; onglet admin « Demandes ».

| Élément | Rôle |
|---|---|
| `creer-demande` (public) | multipart : champ `donnees` (JSON) + justificatifs `ordre_attestation`, `autorisation_exploitation` (PDF/JPG/PNG, 5 Mo, type vérifié sur les octets). Captcha, liste blanche de champs, **3 demandes/jour/IP** (empreinte HMAC, verrou en base), doublons marqués `doublon_suspect` (téléphone, n° d'Ordre, nom normalisé dans le quartier, GPS < 30 m). Accusé de réception `onboarding_recu` par email (outbox). |
| `decider-demande` (admin) | `approve` (checklist de **5 cases obligatoire** ; crée la pharmacie `verifie`, **non publiée**, + invitation 72 h), `reject` / `request_info` (motif obligatoire), `resend_invite`. Jeton de session vérifié côté serveur **et** rôle contrôlé en base. |
| `url-document` (admin) | URL signée de 5 min d'un justificatif (bucket privé `documents-demandes`) ; chaque consultation est journalisée. |
| `activer-compte` (public) | jeton d'invitation (72 h, usage unique, haché en base, dans le fragment `#t=` de l'URL) -> crée le compte Auth, lie le profil `pharmacien`, renvoie un lien de connexion court. Refuse d'écraser un admin ou le compte d'une autre pharmacie. Le jeton n'est consommé que par un clic sur la page (les scanners d'email ne l'« usent » pas). |
| `repondre-complements` (public) | réponse (message + document) via le lien signé de 14 jours, sans compte ; la demande repasse en revue. |

À configurer par le propriétaire (aucune valeur dans le dépôt) :
- Supabase Auth → URL Configuration → **Redirect URLs** : `<APP_BASE_URL>/pro.html` (sinon le lien de connexion court est refusé).
- Secrets déjà utilisés : `ENCRYPTION_KEY`, `SIGNING_SECRET`, `CAPTCHA_PROVIDER`/`CAPTCHA_SECRET`, `ALLOWED_ORIGINS`, `APP_BASE_URL`.
- En **mode démo**, les emails du candidat ne partent pas en vrai (destinataire hors liste blanche : « aurait été envoyé ») ; la console renvoie alors à l'admin le lien d'activation / de compléments pour rejouer le parcours. En production, jamais.

Limites connues de cette étape : pas de repère déplaçable sur carte (bouton « Utiliser ma position » seulement) ; SLA calculé en heures calendaires ; pas de SMS (adaptateur SMS reporté) ; pièce d'identité du titulaire non demandée (point ouvert SPEC 1 §11) ; pas de rappels J+1/J+3/J+7 (étape suivante).

## Onboarding des officines — étape 2 : checklist de l'Espace Pro et règle de publication (SPEC 1 §1, §5, §5.2)

Migration `20261012000000_onboarding_checklist.sql` (à exécuter à la main, après `20261011000000`). Aucune Edge Function : tout passe par des fonctions SQL qui vérifient le rôle.

| Fonction | Rôle |
|---|---|
| `etat_onboarding_mien()` | état calculé en base (6 tâches) de MA pharmacie ; refusé à tout autre rôle |
| `onboarding_marquer(cle, valeur)` | marqueurs déclaratifs : `mot_de_passe_defini`, `gps_confirme` (confirme la position, ne la modifie jamais : le GPS reste réservé à l'admin), `sans_telegram` (annulable) |
| `confirmer_mes_stocks()` | « Je confirme mes stocks » : `confirme_le = now()` sur les lignes non archivées de MA pharmacie, sans toucher aux prix ni aux statuts |
| `reevaluer_ma_publication()` | appelée après un ajout ou un import de stock |
| `admin_etat_onboarding(id)` | état de n'importe quelle pharmacie ; affiché dans le détail d'une demande approuvée |

**Règle de publication** (une seule fonction, `evaluer_publication_interne`, la seule à écrire `est_publiee`) : publiée si `statut = 'verifie'` **et** les 6 tâches faites **et** au moins `publication_min_items_frais` (10) stocks confirmés depuis moins de `publication_fraicheur_jours` (7). Les deux réglages sont modifiables dans la console (validés par `erreur_valeur_config`). Une pharmacie non vérifiée n'est jamais publiée, même avec 6/6. Un pharmacien ne peut pas se publier lui-même (colonne protégée, testé).

Choix à connaître :
- Tâche « Importer mes stocks » : critère **provisoire** = au moins un stock enregistré (import ou ajout manuel). Elle passera à « au moins un import validé » avec l'import guidé (étape suivante).
- Pas de dépublication automatique quand les stocks vieillissent : les rappels et le statut `dormante` (SPEC 1 §5.3) arrivent plus tard ; en attendant, l'admin dépublie à la main.
- La date de dernière mise à jour des stocks est colorée (vert ≤ 3 j, orange ≤ 7 j, rouge au-delà).
- Le mot de passe est défini par `supabase.auth.updateUser` (10 caractères au moins, contrôle côté navigateur ; la politique de Supabase Auth s'applique en plus). Le marqueur n'est qu'un repère d'avancement.

## Onboarding des officines — étape 3 : import guidé des stocks (SPEC 1 §5.1)

Migration `20261013000000_import_stocks.sql` (à exécuter à la main, après `20261012000000`). Aucune Edge Function : lecture du fichier dans le navigateur (`public/import-utils.js`), puis fonctions SQL réservées à MA pharmacie.

Flux : `import_creer_lot` -> `import_ajouter_lignes` (paquets de 200 côté navigateur, 500 maximum côté serveur : limite de durée des requêtes) -> `import_finaliser_lot` -> aperçu (`import_lire_lot`, filtres) et corrections (`import_corriger_ligne` : accepter / mapper / ignorer ; `import_chercher_catalogue` ; `import_demander_ajout`) -> `import_valider_lot` (une seule transaction) -> `import_annuler_lot` (24 h) ; `import_historique`, `import_abandonner_lot`.

- **Lecture tolérante** : séparateur `;` `,` ou tabulation, UTF-8 ou Windows-1252, prix « 5 400 », « 5400 FCFA », « 5.400 », « 1 250,50 », booléens oui/non/yes/no/1/0/vrai/faux. Limites : 5 Mo, 5 000 lignes. Modèle CSV et Excel téléchargeables.
- **Rapprochement** : alias exact ou nom exact + dosage compatible = 1,0 (« reconnu », pré-accepté) ; similarité trigramme ≥ 0,80 = suggestion pré-acceptée ; 0,50–0,79 = **à confirmer** (jamais écrit sans confirmation) ; < 0,50 = non reconnu (bouton « Demander l'ajout au catalogue », jamais d'ajout automatique). Le dosage corrige le score (« Doliprane 500 » -> fiche 500mg ; un dosage en conflit fait chuter la confiance). **Ambiguïté** : si deux fiches sont à moins de 0,05 l'une de l'autre, la ligne est « à confirmer » même avec un score élevé. Seules les fiches `actif` sont proposées.
- **Règles** : bloquant (ligne ignorée, le lot continue) : nom absent, prix absent / non numérique / ≤ 0 / > 500 000, valeur en_stock illisible. Avertissements : doublon dans le fichier (la dernière ligne l'emporte), prix à plus de 50 % de la médiane des autres pharmacies (si au moins 5 en ont). Un médicament restreint est importé normalement dans le stock ; le routage, lui, ne l'utilise jamais.
- **Modes** : « Mettre à jour » (défaut, ne touche pas aux absents) ou « Remplacer tout mon stock » (confirmation explicite ; les absents passent en `archive`, rien n'est supprimé).
- **Annulation (24 h)** : restaure prix, statut, disponibilité, date de mise à jour et de confirmation à l'identique ; supprime les stocks créés par l'import ; désarchive ceux du mode « Remplacer ». **Une ligne modifiée depuis la validation n'est jamais écrasée** (elle est comptée dans `modifies_depuis`). Si l'import avait déclenché la publication de la pharmacie, l'annulation ne la dépublie pas (pas de dépublication automatique : l'admin dépublie à la main).
- **Tâche d'onboarding « Importer mes stocks »** : désormais « au moins un import validé et non annulé » (le critère provisoire « un stock existe » disparaît).
- **Conditionnement** : lu et affiché, mais le catalogue n'a pas de colonne de conditionnement : il n'intervient pas dans le rapprochement et n'est pas enregistré.
- **Performance** : environ 4 s pour 500 lignes contre un catalogue synthétique de 2 000 fiches aux noms très proches (cas défavorable) ; d'où des paquets de 200. À remesurer sur Supabase avec le vrai catalogue.
