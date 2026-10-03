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
