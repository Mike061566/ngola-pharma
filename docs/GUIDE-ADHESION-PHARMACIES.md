# Guide — de la demande d'adhésion à la publication d'une pharmacie

Ce guide décrit le parcours tel que l'application le met en œuvre (SPEC 1 ; migrations `20261011` à `20261016` ; Edge Functions `creer-demande`, `decider-demande`, `repondre-complements`, `activer-compte`, `inviter-pharmacie`).
Il s'adresse à l'administrateur N'Gola et peut être résumé aux pharmaciens (partie 1).

> **Prérequis.** Le parcours ne fonctionne de bout en bout qu'après les phases E (secrets) et F (déploiement des Edge Functions) de `docs/MISE-EN-PRODUCTION.md`. Avant cela, le formulaire ne peut pas être envoyé, les décisions ne peuvent pas être enregistrées et les justificatifs ne peuvent pas être ouverts.

---

## Vue d'ensemble

```
Pharmacie                              Administrateur N'Gola                      Système
─────────                              ─────────────────────                      ───────
1. Formulaire « Devenir partenaire »  ─►                                          contrôles, accusé de réception
                                       2. Démarrer la revue
                                       3. Checklist (5 cases) + justificatifs
                                       4. Décision : approuver / compléments / refuser
   (compléments : lien 14 j) ◄──────── ❓
   (refus : motif)            ◄──────── ⛔
   (approbation : lien 72 h)  ◄──────── ✅                                       pharmacie créée « vérifiée, non publiée »
5. Activation : compte créé, mot de passe
6. Mise en route (6 étapes)                                                       rappels J+1, J+3, J+7
                                                                                  7. Publication automatique
```

**Deux statuts à ne pas confondre :**

| Objet | Valeurs | Où le voir |
|---|---|---|
| La **demande** | Soumise → En revue → Compléments demandés / Refusée / Approuvée | Espace Pro admin → onglet **Demandes** |
| La **pharmacie** | non vérifiée / **vérifiée** ; publiée oui/non | onglet **Pharmacies** ; site public |

« Approuvée » ne veut pas dire « visible » : une pharmacie approuvée est **vérifiée mais non publiée** tant qu'elle n'a pas terminé sa mise en route (étape 6).

---

## Partie 1 — Côté pharmacie

### Étape 1 : la demande (page publique « Devenir pharmacie partenaire »)

Lien en bas de la page d'accueil, ou `/devenir-partenaire.html`.

**Informations demandées**
- Officine : nom, quartier (liste fermée), adresse, **téléphone fixe**.
- Titulaire : nom complet, **numéro d'inscription à l'Ordre**, email, téléphone mobile.
- Position GPS (recommandée), horaires, participation à la garde.
- Deux consentements séparés : conditions d'usage ; réception des demandes de patients.

**Justificatifs** (PDF, JPG ou PNG, 5 Mo maximum chacun)
- Attestation d'inscription à l'Ordre : **obligatoire**.
- Autorisation d'exploitation de l'officine : **obligatoire**.
- Pièce d'identité du titulaire : facultative.

En **mode démo**, le formulaire affiche : « N'envoyez pas de documents réels en mode démo : joignez un fichier fictif ».

**Contrôles automatiques à l'envoi**
- Vérification anti-robot (captcha) et 3 demandes au maximum par jour depuis la même connexion.
- Les fichiers sont vérifiés sur leur contenu réel, pas seulement sur l'extension.
- **Doublons** : même téléphone, même numéro d'Ordre, même nom dans le même quartier, ou position à moins de 30 m d'une pharmacie existante. La demande est quand même enregistrée, mais marquée **« Doublon suspect »** pour l'administrateur.

La pharmacie reçoit un **accusé de réception** par email (`onboarding_recu`).

### Si l'administrateur demande des compléments
La pharmacie reçoit un email avec le **motif** et un **lien personnel valable 14 jours**, sans compte à créer. Elle y écrit un message et joint les pièces demandées. La demande repasse alors automatiquement **« En revue »**.

### Si la demande est refusée
La pharmacie reçoit un email avec le **motif** du refus. La demande est conservée : rien n'est supprimé automatiquement.

### Étape 5 : l'activation (après approbation)
1. La pharmacie reçoit un email d'approbation avec un **lien d'activation valable 72 heures, utilisable une seule fois**.
2. En ouvrant le lien, son **compte est créé** et l'Espace Pro s'ouvre, déjà connecté. Si l'email est déjà utilisé par un autre compte, l'activation est refusée avec un message : contactez-la.
3. Elle définit son **mot de passe** (première étape de la checklist), pour pouvoir se reconnecter ensuite sans lien.

Lien expiré : l'administrateur peut **renvoyer une invitation** (étape 4).

### Étape 6 : la mise en route (Espace Pro → « Mise en route de votre pharmacie »)

| # | Étape | Terminée quand… |
|---|---|---|
| 1 | Définir mon mot de passe | le mot de passe est enregistré |
| 2 | Compléter « Ma Pharmacie » | horaires renseignés **et** position de l'officine confirmée |
| 3 | Activer Telegram | le lien du bot a été ouvert et `/start` envoyé (jusqu'à 3 agents) ; ou « Je n'utilise pas Telegram » |
| 4 | Importer mes stocks | au moins un médicament enregistré (import ou ajout manuel) |
| 5 | Confirmer mes stocks | bouton « Je confirme mes stocks » pressé |
| 6 | Seuil de publication | au moins **10 médicaments confirmés depuis moins de 7 jours** |

Le seuil (10) et la fenêtre (7 jours) se règlent dans la console admin.

---

## Partie 2 — Côté administrateur (Espace Pro → onglet « Demandes »)

### Étape 2 : prendre la demande en charge
- La liste se filtre par statut (Soumises, En revue, Compléments demandés, Approuvées, Refusées, Doublons suspects).
- Une demande en attente depuis plus de **48 heures** porte le signe ⚠.
- Ouvrez la demande, puis cliquez sur **« ▶ Démarrer la revue »**. Le statut passe à « En revue ». La checklist ne se coche **qu'à partir de ce moment**.

### Étape 3 : vérifier
**Justificatifs** : bouton « Ouvrir ». Le fichier s'ouvre par un **lien temporaire de 5 minutes**, car le stockage est privé et n'a jamais d'adresse publique. Chaque ouverture est enregistrée.

**Checklist (les 5 cases sont obligatoires pour approuver)**, chacune horodatée et attribuée à vous :
1. Numéro d'Ordre cohérent avec le nom du titulaire et l'attestation.
2. Autorisation d'exploitation lisible et valide.
3. **Rappel téléphonique au numéro fixe de l'officine** : le numéro répond et confirme le nom de l'officine.
4. Adresse et position GPS cohérentes sur la carte.
5. Aucun doublon avec une pharmacie existante. Regardez en particulier les demandes marquées « Doublon suspect ».

### Étape 4 : décider
| Bouton | Condition | Effet |
|---|---|---|
| **✅ Approuver** | demande « En revue » **et** 5 cases cochées | crée la pharmacie (**vérifiée, non publiée**) et envoie l'invitation (lien 72 h) ; le compte est créé quand la pharmacie ouvre ce lien |
| **❓ Demander des compléments** | **motif obligatoire** (envoyé au demandeur) | statut « Compléments demandés », lien de réponse de 14 jours |
| **⛔ Refuser** | **motif obligatoire** (envoyé au demandeur) | statut « Refusée » |
| **Renvoyer une invitation** | demande déjà approuvée | nouveau lien de 72 h (si le précédent a expiré) |

La base de données refuse elle-même une approbation sans les 5 cases, même hors de l'interface.

**En mode démo**, aucun email réel ne part vers le demandeur (fictif) : après « Approuver » ou « Demander des compléments », l'écran affiche « Mode démo — lien à ouvrir vous-même ». Vous pouvez ainsi jouer le rôle de la pharmacie pendant une présentation.

### Suivi après approbation : « Pharmacies en cours de mise en route »
- Avancement « x / 6 » et nombre de jours depuis l'approbation.
- Rappels automatiques à la pharmacie à **J+1, J+3 et J+7**, avec un lien vers l'étape bloquante.
- Au-delà de **30 jours** sans publication, la pharmacie est signalée **« Dormante »** et vous recevez une alerte. Rien n'est supprimé.

---

## Étape 7 : la publication (automatique)

La pharmacie devient **publiée** dès que les trois conditions sont réunies :
1. statut **vérifiée** (approbation ou vérification admin) ;
2. les **6 étapes** de la mise en route terminées ;
3. au moins **10 médicaments confirmés depuis moins de 7 jours**.

Publiée = **éligible au routage des demandes de patients**. Aucun bouton ne permet de publier à la main : seule la base de données positionne cet état.

---

## Cas particulier : les pharmacies déjà présentes dans l'annuaire

Les 52 pharmacies existantes, ou celles créées par import CSV, n'ont pas de demande. Leur parcours se fait dans l'onglet **Pharmacies** :
1. **Pharmacies à vérifier** → « Vérifier » → dossier et **mêmes 5 cases** → « Marquer comme vérifiée ». La base refuse la vérification sans les 5 cases.
2. **Pharmacies vérifiées à inviter** → « ✉️ Inviter le titulaire » : lien d'activation de 72 h envoyé à l'email du titulaire. **Sans email du titulaire, l'invitation est impossible** : complétez d'abord le dossier.
3. Ensuite, même mise en route (étape 6) et même règle de publication (étape 7).

Ces pharmacies ne reçoivent pas les rappels J+1, J+3 et J+7, réservés aux demandes approuvées.

---

## Ce que l'application ne fait jamais
- Elle ne collecte, ne stocke et ne vérifie **aucune ordonnance**.
- Elle ne décide **jamais** de la classification réglementaire d'un médicament : c'est votre pharmacien validateur qui la fait.
- Elle ne montre **aucune donnée de patient** à une pharmacie.
- Elle n'envoie **aucun message réel en mode démo**, sauf aux comptes de test de la liste blanche.

## Durées et seuils (récapitulatif)
| Élément | Valeur |
|---|---|
| Demandes par jour depuis une même connexion | 3 |
| Taille d'un justificatif | 5 Mo |
| Délai cible de traitement d'une demande | 48 h (signe ⚠ au-delà) |
| Lien de compléments | 14 jours |
| Lien d'activation | 72 heures, usage unique |
| Lien d'ouverture d'un justificatif | 5 minutes |
| Rappels de mise en route | J+1, J+3, J+7 |
| Pharmacie « dormante » | 30 jours après l'approbation sans publication |
| Seuil de publication | 10 médicaments confirmés depuis moins de 7 jours (réglable) |
