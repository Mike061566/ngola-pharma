# Runbook — Déploiement N'Gola Pharma pour un nouveau client pharmacie

> **Statut** : ce runbook est basé sur la lecture complète du code du dépôt
> [Mike061566/ngola-pharma](https://github.com/Mike061566/ngola-pharma) (audit du 2026-09-22).
> `supabase/setup_consolide.sql` a été **exécuté avec succès sur le projet Supabase réel**
> (`ueycknsdwthmtmpzptqp`) le 2026-09-22, puis **validé de bout en bout** : login pharmacien
> sans erreur de récursion, profil + pharmacie liée chargés correctement, isolation RLS
> vérifiée (un pharmacien ne peut pas modifier le stock d'une autre pharmacie — tentative
> testée et bloquée silencieusement par Postgres, 0 ligne affectée). Alertes de stock
> validées de bout en bout (inscription publique email + WhatsApp → visible côté admin).
>
> **Faille critique trouvée et corrigée le 2026-09-22** : la policy `profils_insert` d'origine
> ne restreignait pas la valeur du champ `role` — n'importe quel compte authentifié (y compris
> via signup public, avec la seule clé anon publique) pouvait s'auto-attribuer `role: 'admin'`
> en un seul appel `profils.upsert()`. Le même trou existait sur `profils_update` (changer son
> propre rôle après coup). Corrigé par `supabase/fix_role_escalation.sql`, appliqué sur
> `ueycknsdwthmtmpzptqp` et re-testé : la tentative échoue maintenant avec "new row violates
> row-level security policy". Le correctif est aussi intégré dans `setup_consolide.sql` pour
> les futurs déploiements clients.

**Contexte** : l'architecture MVP est "1 client = 1 projet Supabase" (pas de multi-tenant réel
pour l'instant). Ce runbook se répète donc intégralement pour chaque nouvelle pharmacie/chaîne
qui signe.

---

## 0. Pré-requis

- [ ] Un compte Supabase (le tier gratuit suffit pour un MVP/démo)
- [ ] Node.js ≥ 18 installé en local (si le backend Express est utilisé — voir note ⚠️ étape 8)
- [ ] Accès en écriture au dépôt du client (fork ou nouveau repo à partir de `ngola-pharma`)
- [ ] Le nom du quartier/de la ville et les infos réelles des pharmacies du client (nom, adresse,
      téléphone, coordonnées GPS) — remplacer les données de démo de Yaoundé

⚠️ **Le dossier `supabase/` local ne contenait à l'origine que `001_schema.sql`** (avec le bug
de récursion RLS non corrigé). Le script consolidé recommandé, `supabase/setup_consolide.sql`,
a été ajouté localement (voir étape 3) et couvre tout ce qu'il faut pour un déploiement neuf.
Si le chemin historique (scripts multiples) est nécessaire à la place, récupérer depuis GitHub
les fichiers absents du dossier local : `setup_complet.sql`, `fix_rls_recursion.sql`,
`create_alertes_stock.sql`, `alter_alertes_add_phone.sql`, `set_verified_pharmacies.sql`, ainsi
que `public/pro.html` et `netlify.toml` (également absents localement, nécessaires dans tous
les cas pour le frontend pharmacien et le déploiement Netlify).

---

## 1. Créer le projet Supabase du client

1. [supabase.com/dashboard](https://supabase.com/dashboard) → **New project**
2. Nom : `ngola-pharma-<nom-client>` (ex : `ngola-pharma-pharmaplus`)
3. Choisir une région proche du Cameroun (Europe la plus proche si pas d'option Afrique)
4. Noter le mot de passe DB généré (coffre-fort du projet, pas dans le repo)
5. Attendre la fin du provisioning (~2 min)

## 2. Récupérer les clés

Dans **Project Settings → API** :

| Variable | Où la trouver | Usage |
|---|---|---|
| `SUPABASE_URL` | "Project URL" | Backend + frontend |
| `SUPABASE_ANON_KEY` | "anon public" | Frontend (clé publique, protégée par RLS) |
| `SUPABASE_SERVICE_KEY` | "service_role" | Backend uniquement — **ne jamais** la mettre dans un fichier servi au navigateur |

## 3. Exécuter le script SQL

### Chemin recommandé — projet Supabase neuf

Utiliser **`supabase/setup_consolide.sql`** (nouveau, écrit le 2026-09-22 à partir de cet
audit) : un seul script idempotent qui fusionne `setup_complet.sql` + `fix_rls_recursion.sql`
+ `create_alertes_stock.sql` + `alter_alertes_add_phone.sql`, avec les policies `profils`
correctes (non récursives) posées dès la création — plus besoin de script de correctif après
coup. Il se termine par un bloc de vérification qui affiche un `WARNING` si les policies
`profils` ne sont pas au nombre attendu.

Coller son contenu dans **SQL Editor → New query** et l'exécuter en une fois. Sa section
"ÉTAPE 6 : DONNÉES DE DÉMO" contient un jeu de données minimal de Yaoundé pour tester le
flux — à commenter/remplacer par les vraies données du client (voir étape 5 plus bas).

*Validé de bout en bout le 2026-09-22 sur le projet `ueycknsdwthmtmpzptqp` : exécution sans
erreur, login pharmacien fonctionnel, isolation RLS entre pharmacies confirmée (voir bandeau
de statut en haut de ce document).*

### Chemin historique — si un projet client a déjà tourné avec les anciens scripts

Si un environnement existant a déjà été monté avec les scripts d'origine (partiellement ou en
totalité), ne pas rejouer `setup_consolide.sql` sans vérifier d'abord l'état réel des tables.
Dans ce cas, l'ordre d'origine était :

1. `supabase/setup_complet.sql` — tables + RLS de base (⚠️ laisse `profils` sans policy)
2. `supabase/fix_rls_recursion.sql` — **obligatoire**, pose les policies manquantes sur `profils`
   via la fonction `auth_role()` (SECURITY DEFINER, anti-récursion)
3. `supabase/create_alertes_stock.sql` — table `alertes_stock`
4. `supabase/alter_alertes_add_phone.sql` — colonnes téléphone/canal (après le script 3)
5. *(Optionnel démo)* `supabase/set_verified_pharmacies.sql` — adapter les `slug` aux
   pharmacies réelles du client avant exécution

*Ne jamais exécuter `001_schema.sql` seul : sa policy `profils` d'origine est récursive et
provoque une erreur Postgres dès la première requête authentifiée.*

### Vérification après l'étape 3

Dans le SQL Editor, exécuter :

```sql
select tablename, policyname, cmd
from pg_policies
where schemaname = 'public'
order by tablename, cmd;
```

Contrôler que `profils` a bien 3 lignes (`profils_select`, `profils_update`, `profils_insert`)
— si la table `profils` n'apparaît pas du tout dans le résultat, le script 2 n'a pas été
exécuté ou a échoué : **ne pas continuer, corriger avant de passer à l'étape 4.**

## 4. Créer les comptes utilisateurs

1. **Authentication → Users → "Add user" → "Create new user"** (bien ce sous-menu précis,
   **pas "Send invitation"**, sinon aucun mot de passe n'est défini et le login échoue
   silencieusement avec un message générique "Invalid login credentials"). **Cocher "Auto
   confirm user?"** — sans ça, l'email doit être confirmé (lien envoyé) avant que le login par
   mot de passe fonctionne, et un lien de confirmation/récupération expire vite (piège vécu
   pendant les tests : redirige en plus vers `localhost:3000` si le "Site URL" n'est pas
   reconfiguré, voir avertissement plus bas). Créer un compte pour :
   - Un compte **admin** (l'équipe N'Gola Pharma / vous)
   - Un compte **pharmacien** par pharmacie participante côté client
2. Pour chaque compte créé, insérer la ligne `profils` correspondante (le trigger ne le fait
   pas automatiquement) :

```sql
insert into profils (id, nom_complet, role, pharmacie_id)
values (
  '<uuid-auth-user>',   -- copié depuis Authentication → Users (champ "User UID")
  'Nom du pharmacien',
  'pharmacien',          -- ou 'admin'
  '<uuid-pharmacie>'     -- null si role = 'admin'
)
on conflict (id) do update set role = excluded.role, pharmacie_id = excluded.pharmacie_id;
```

3. **Test immédiat** : se connecter sur `pro.html` avec ce compte avant d'aller plus loin.
   Si le login échoue avec "Email ou mot de passe incorrect", revoir le point 1 (compte créé
   via "Send invitation" au lieu de "Create new user", ou "Auto confirm user?" pas coché).
   Si l'écran reste bloqué sur "Connexion..." après un login réussi ou affiche une erreur de
   récursion Postgres, revenir à l'étape 3 — ne pas continuer tant que le login ne fonctionne
   pas.

## 5. Remplacer les données de démo par celles du client

Deux options :

- **Petit volume (< 30 pharmacies)** : adapter et rejouer la section "ÉTAPE 4 : DONNÉES DE
  SEED" de `setup_complet.sql` avec les vraies pharmacies/médicaments du client.
- **Volume important** : utiliser `npm run seed` (`src/utils/seed.js`), qui importe les CSV
  `supabase/seed/*.csv` — remplacer leur contenu par les données réelles avant de lancer.
  Nécessite `SUPABASE_SERVICE_KEY` dans `.env`.

Ne pas oublier de supprimer les pharmacies de démo de Yaoundé si le client est ailleurs
(`delete from pharmacies where source = 'admin' and ...` — vérifier avant de supprimer que ça
ne casse pas de `stocks` liés, la contrainte `ON DELETE CASCADE` s'en charge).

## 6. Corriger le Site URL (bug découvert en test — impacte les vrais utilisateurs)

Dans **Authentication → URL Configuration**, le "Site URL" est laissé par défaut sur
`http://localhost:3000` (reste de config de développement). Tant que ce n'est pas corrigé,
**tout lien envoyé par email par Supabase** (récupération de mot de passe, confirmation,
magic link) redirige vers une page morte (`ERR_CONNECTION_REFUSED` en local, ou un domaine
qui n'existe pas pour un vrai utilisateur) — testé et reproduit pendant l'audit.

Remplacer par l'URL réelle du site déployé (ex. `https://<client>.netlify.app`), et ajouter
la même URL (suffixée `/**`) dans "Redirect URLs" juste en dessous. À faire **avant** toute
démo où un vrai pharmacien pourrait avoir besoin de réinitialiser son mot de passe.

*Corrigé le 2026-09-22 sur le projet `ueycknsdwthmtmpzptqp` : Site URL réglé sur
`https://ngola-pharma.netlify.app`, Redirect URLs sur `https://ngola-pharma.netlify.app/**`.
Login pharmacien re-testé directement sur ce site en production après correctif — fonctionne
à l'identique du test local, aucune régression.*

## 7. Brancher le frontend sur le nouveau projet Supabase

⚠️ **Point non évident** : `SUPABASE_URL` et `SUPABASE_ANON_KEY` sont **codés en dur** dans
`public/index.html` (~ligne 1858) et `public/pro.html` (~ligne 404-405), pas lus depuis une
variable d'environnement. Pour chaque nouveau client, éditer ces deux fichiers et remplacer
les deux constantes par les valeurs du nouveau projet (étape 2). Oublier cette étape = le
frontend du nouveau client continue de parler au projet Supabase d'un autre client.

## 8. Déploiement

**Frontend (Netlify)** — c'est le chemin confirmé par `netlify.toml` (`publish = "public"`,
site statique, pas de build) :
1. Nouveau site Netlify pointant sur le repo du client, dossier `public/`
2. Domaine : `<client>.ngolapharma.cm` ou sous-domaine Netlify pour la démo

⚠️ **Backend Express (`src/index.js`) — statut à clarifier avant de suivre une procédure ici.**
L'audit a confirmé qu'aucune page (`index.html`, `pro.html`) n'appelle les routes `/api/...` :
le frontend statique parle directement à Supabase. Donc soit ce backend n'est pas utilisé en
production actuellement (site statique Netlify), soit il est déployé ailleurs sans lien
documenté avec ce repo. **Vérifier lequel des deux cas est vrai avant la démo** — sinon on
présente un backend "actif" au client qui en réalité ne sert à rien, ou inversement on oublie
de déployer un composant nécessaire.

## 9. Répétition à blanc obligatoire avant démo

Sur un projet Supabase de test (pas celui du vrai client), dérouler les étapes 1 à 8
entièrement et valider chaque point de cette checklist :

- [ ] Recherche publique d'un médicament fonctionne (`index.html`)
- [ ] Filtre "pharmacies de garde" fonctionne
- [ ] Recherche géographique "pharmacies proches" fonctionne (si utilisée)
- [x] Inscription à une alerte de stock (email ET téléphone) réussit sans erreur RLS — **validé 2026-09-22**
- [x] Login pharmacien sur `pro.html` réussit sans erreur de récursion — **validé 2026-09-22**
- [x] Le pharmacien voit uniquement le stock de **sa** pharmacie — **validé 2026-09-22**
- [ ] Le pharmacien peut modifier un prix / marquer en rupture, et ça se reflète côté public
- [x] Le pharmacien ne peut PAS modifier le stock d'une autre pharmacie — **validé 2026-09-22**
      (tentative directe testée sur `stocks.pharmacie_id` d'une autre pharmacie : 0 ligne
      affectée, RLS a bloqué silencieusement)
- [x] Login admin voit bien la liste des alertes de stock — **validé 2026-09-22**
- [ ] Un lien de récupération de mot de passe envoyé par email redirige vers une page valide
      (après correctif de l'étape 6)
- [x] Un compte non-admin ne peut pas s'auto-attribuer le rôle admin/pharmacien —
      **validé 2026-09-22** (tentative testée et bloquée par RLS après application de
      `fix_role_escalation.sql`)

## 10. En cas de blocage — pièges déjà rencontrés

| Symptôme | Cause probable | Fix |
|---|---|---|
| "infinite recursion detected in policy for relation profils" | `001_schema.sql` exécuté seul, sans `fix_rls_recursion.sql` | Exécuter `fix_rls_recursion.sql` (ou directement `setup_consolide.sql`) |
| Login pharmacien reste bloqué, pas d'erreur visible | `setup_complet.sql` exécuté seul, table `profils` sans aucune policy | Exécuter `fix_rls_recursion.sql` (ou `setup_consolide.sql`) |
| "Email ou mot de passe incorrect" alors que le mot de passe est correct | Compte créé via "Send invitation" (pas de mot de passe défini), ou "Auto confirm user?" pas coché | Supprimer le compte, le recréer via "Add user" → **"Create new user"**, cocher "Auto confirm user?" |
| Lien de récupération de mot de passe → page inaccessible (`ERR_CONNECTION_REFUSED`, `localhost:3000`) | "Site URL" resté sur `http://localhost:3000` dans Authentication → URL Configuration | Voir étape 6 |
| `otp_expired` en cliquant un lien de récupération | Lien envoyé il y a trop longtemps (durée de validité limitée) | Renvoyer un lien frais ("Send password recovery") et le cliquer rapidement, ou recréer le compte avec Auto Confirm |
| Alerte stock refusée (erreur RLS sur insert) | `create_alertes_stock.sql` non exécuté, ou table `alertes_stock` absente | Exécuter les scripts 3 et 4 dans l'ordre (ou `setup_consolide.sql`) |
| Le pharmacien connecté voit les données d'un autre client/pharmacie | `index.html`/`pro.html` pointent encore sur l'ancien projet Supabase | Vérifier étape 7 |
| N'importe quel compte peut devenir admin en s'auto-modifiant `role` | Policies `profils_insert`/`profils_update` d'origine ne restreignent pas la valeur de `role` | Exécuter `fix_role_escalation.sql` (déjà intégré dans `setup_consolide.sql` pour les nouveaux déploiements) |

---

*Document à tenir à jour à chaque changement de schéma. Si un jour les scripts SQL sont
consolidés en un seul fichier idempotent, remplacer les étapes 3.1–3.4 par ce fichier unique
et supprimer ce tableau de pièges devenu obsolète.*
