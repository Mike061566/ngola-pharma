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
