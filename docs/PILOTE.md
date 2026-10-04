# Pilote MVP avec les pharmaciens — état, déploiement, protocole

Ce document fait le point avant le test avec les pharmaciens (sans SMS : l'adaptateur Orange est reporté). Rien ci-dessous n'a été exécuté en production par Claude.

## 1. Périmètre livré / reporté
| Domaine | État |
|---|---|
| Correctifs de sécurité (profils, colonnes protégées, alertes_stock), baseline, CI | livré, **appliqué en prod** (par le propriétaire) |
| Fusion des doublons de fiches (`20261003100000`) | livré, **à exécuter par le propriétaire en premier**, avec son conseiller |
| Catalogue + classification, stocks, contacts, alertes, verrou de production | livré (migrations 20261004…) |
| Alertes patient → routage en vagues → Telegram → réponse pharmacie → stocks mis à jour | livré (mock ou Telegram réel) |
| Console admin (supervision, revue des médicaments restreints, réglages, indicateurs) | livré |
| Mode démo (bannière, étiquettes, liste blanche, remise à zéro) | livré |
| Telegram réel (`@ngola_pharma_Bot`), email ZeptoMail | livré, **jamais exécuté contre les vrais services** : à valider au premier envoi de test |
| SMS Orange | **reporté** (après le pilote) ; SMS = `mock` |
| Classification des 20 DCI | **décision du propriétaire / pharmacien validateur** (`demo_classification.csv`) |
| Archivage des anciennes fiches de test | script prêt (`supabase/ops/archiver_anciennes_fiches_test*.sql`), à exécuter par le propriétaire |
| Pré-inscription publique, justificatifs, doublons, file de vérification + checklist, décisions, invitation 72 h, compléments (SPEC 1 §3–4, activation §5) | livré (étape 1 d'onboarding), non encore joué en production |
| Checklist d'onboarding dans l'Espace Pro, « Je confirme mes stocks », code couleur de fraîcheur, règle de publication automatique (SPEC 1 §5, §5.2, §1) | livré (étape 2), non encore joué en production |
| Import CSV/Excel guidé : lecture tolérante, rapprochement avec le catalogue, aperçu et corrections, validation atomique, annulation 24 h, historique (SPEC 1 §5.1) | livré (étape 3), remplace l'ancien écran d'import ; non encore joué en production |
| Rappels J+1/J+3/J+7 et statut `dormante`, création en masse des 52 pharmacies (SPEC 1 §5.3, §4) | **à venir** |

Conséquence pour le pilote : pas de parcours d'inscription autonome des pharmacies. Seule une pharmacie `verifie` est éligible au routage.

## 2. Ordre de déploiement (propriétaire, jamais en CI)
1. Sauvegarde de la base. Exécuter la fusion des doublons (`20261003100000`), puis la requête de vérification.
2. Appliquer les migrations suivantes dans l'ordre (`supabase db push` sur le projet, après relecture).
3. Archivage des 20 anciennes fiches (simulation d'abord, puis `COMMIT`).
4. Secrets de fonctions (voir `supabase/functions/README.md`) : `CRON_SECRET`, `ENCRYPTION_KEY`, `SIGNING_SECRET`, `CAPTCHA_PROVIDER`/secret (Turnstile) et `turnstileSiteKey` dans `public/alerte-config.js`, `ALLOWED_ORIGINS`, `APP_BASE_URL`, `TELEGRAM_PROVIDER=telegram`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET`, `TELEGRAM_BOT_USERNAME=ngola_pharma_Bot`, `ADMIN_ALERT_EMAIL` ; email : `EMAIL_PROVIDER=zeptomail` + `ZEPTOMAIL_TOKEN`, `EMAIL_FROM_ADDRESS` (facultatif au début : email = mock).
5. Déployer les 7 Edge Functions ; `node scripts/telegram-set-webhook.js --confirmer`.
6. Planificateurs `supabase/ops/planifier_outbox.sql` puis `planifier_alertes.sql` (secrets dans Vault).
7. Classification : le pharmacien validateur relit, le propriétaire commite `demo_classification.csv`, puis validation dans la console (n° d'Ordre saisi dans le formulaire). Relecture à chaque ajout au catalogue + trimestrielle.
8. Rester en `mode_application = demo` pendant le pilote : envois réels uniquement vers les comptes de la liste blanche. `ALERT_AUTO_ROUTING=true` en dernier.

## 3. Journée de test avec les pharmaciens
- Avant : remise à zéro (`node scripts/demo-reset.js --confirmer`), chaque participant a démarré le bot (`/start`) et est ajouté à la liste blanche (console → Comptes de test).
- Scénario : voir `docs/DEMO.md` (demande non restreinte, sans réponse, restreinte, pharmacie hors liste blanche).
- À observer : délai de réception Telegram, lisibilité du message, boutons ✅/❌, mise à jour du stock, message patient. À noter par les pharmaciens : médicaments manquants, mentions d'ordonnance, fréquence acceptable des demandes.
- Arrêt d'urgence : console → désactiver le routage automatique (`routage_manuel`) ou `ALERT_AUTO_ROUTING=false`.

## 4. Avant de passer en production réelle (après le pilote)
SMS Orange (couverture MTN/Orange confirmée), parcours d'onboarding SPEC 1, webhook de rebonds email, `cout_estime` réel, décisions ouvertes de SPEC 1 §11, bascule `production` via la liste de contrôle de la console.
