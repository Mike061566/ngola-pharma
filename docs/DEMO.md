# Mode démo — guide de la présentation

Objectif (SPEC 2 §4.0bis) : montrer le produit de bout en bout avec le catalogue de test, **sans contourner le garde-fou réglementaire** :
un médicament restreint reste bloqué, démo ou non. Rien de réel n'est envoyé à quelqu'un qui n'est pas sur la liste blanche.

## Ce qui est en place
| Élément | Où |
|---|---|
| Bannière « MODE DÉMO — données fictives » | site public, page patient, page de réponse, Espace Pro, console (`public/demo-banner.js`, lit `mode_public`) |
| Étiquette « Données de démonstration » | cartes et fiches de pharmacies, meilleurs prix (colonne `est_demo`) |
| Liste blanche des comptes de test | console → « Comptes de test » (`admin_marquer_contact_demo`, `admin_activer_telegram_demo`) |
| Messages « aurait été envoyé » | console → « Comptes de test » (statut `suppressed_demo`) et chronologie de chaque alerte |
| Remise à zéro rejouable | `node scripts/demo-reset.js --confirmer` ou bouton de la console (fonction SQL `reinitialiser_demo`) |
| Fiche fictive « Exemple restreint (démo) » | recréée à chaque remise à zéro, **restreinte**, jamais routée |
| Catalogue de démonstration | `supabase/seed/demo_catalog.csv` (voir plus bas) |

## Avant la présentation
1. **Mode** : la console doit afficher « MODE DÉMO » (réglage `mode_application = demo`, valeur par défaut).
2. **Catalogue** : le fichier `supabase/seed/demo_catalog.csv` ne contient pour l'instant QUE la fiche fictive. Le catalogue de test réel est à fournir
   par le propriétaire avec, pour chaque médicament, `restricted` = `true` ou `false` **écrit explicitement** (vide ou illisible = restreint, par sécurité).
   Chargement : `node scripts/demo-reset.js --confirmer --catalogue supabase/seed/demo_catalog.csv`.
   La classification d'une fiche existante se règle aussi dans la console → « Classification du catalogue ». Claude ne la décide jamais.
3. **Comptes de test** : chacun (propriétaire et pharmaciens participants) ouvre le bot Telegram et appuie sur « Démarrer » via un lien d'activation :
   - pharmacien participant : Espace Pro → Alertes → « Activer Telegram » ; puis console → « Comptes de test » → **Ajouter** (liste blanche) ;
   - propriétaire : console → « Créer mon compte de test Telegram » (compte déjà en liste blanche) ; ce compte peut aussi jouer le patient.
   Le bot ne peut écrire à quelqu'un qu'après son `/start` : sans cela, rien ne part.
4. **Remise à zéro** juste avant : `node scripts/demo-reset.js --confirmer`. Elle affiche une **empreinte** de l'état (identique à chaque exécution) et
   des **avertissements** (aucun médicament non restreint, aucun compte de test…).
   Elle rétablit 6 pharmacies de démonstration (vérifiées, publiées, ouvertes 24 h/24) et leurs stocks ; elle conserve comptes de test et classification.
5. Secrets de déploiement posés (voir `supabase/functions/README.md`) et planificateurs actifs (`supabase/ops/*.sql`) ; `ALERT_AUTO_ROUTING=true` ;
   réglage `facteur_temps_demo` (ex. 10) pour accélérer vagues et escalade.

## Scénario rejouable (SPEC 2 §4.0bis)
1. **Demande non restreinte** : le patient (page `/alerte.html`, captcha simulé `mock-ok` en démo) demande un médicament non restreint ; le téléphone d'un
   pharmacien participant reçoit la demande sur Telegram ; il répond « Disponible » : le stock et la date se mettent à jour ; le patient reçoit le message
   (avec la mention d'ordonnance si besoin).
2. **Sans réponse** : une demande sans réponse déclenche la vague 2, puis l'escalade (accélérées par `facteur_temps_demo`).
3. **Restreint** : une demande sur « Exemple restreint (démo) » part en revue admin (console → À examiner) avec le message d'attente au patient.
4. **Pharmacie non participante** : le message destiné à une pharmacie hors liste blanche apparaît comme « aurait été envoyé ».
Entre deux répétitions : remise à zéro.

## Garanties
- La remise à zéro **refuse** de s'exécuter hors mode démo (contrôlé en base) ; sans `--confirmer`, le script n'écrit rien.
- Elle ne modifie ni les pharmacies réelles ni leurs stocks, ne supprime aucun contact, ne change aucune classification.
- Elle n'envoie aucun message. Aucune clé n'est lue ailleurs que dans les variables d'environnement (`SUPABASE_URL`, `SUPABASE_SERVICE_KEY`).
- Pas de formulaire de pré-inscription dans ce périmètre (SPEC 1) : la mention « N'envoyez pas de documents réels en mode démo » sera ajoutée avec lui.

## Passage en production
Le mode passe à `production` uniquement via la liste de contrôle de la console (validation pharmacien, plus aucune fiche ni pharmacie de démonstration
active, pharmacie réelle vérifiée, fournisseur Telegram réel). La bannière disparaît alors d'elle-même.
