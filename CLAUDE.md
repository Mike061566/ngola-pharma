# N'Gola Pharma — instructions pour Claude Code

> Si le dépôt contient déjà un `CLAUDE.md`, **ajoutez ce bloc à la fin** au lieu de le remplacer.

## Contexte
Annuaire de pharmacies à Yaoundé (comparaison de prix, disponibilités, alertes patients). MVP en **mode démo** pour une présentation à des pharmaciens, puis lancement réel.

## Documents de référence (lire avant de coder)
- `docs/specs/SPEC-1-onboarding-pharmacies.md` : onboarding, import de stocks, catalogue, mode démo.
- `docs/specs/SPEC-2-routage-alertes.md` : alertes, routage, Telegram/SMS/email, garde-fou réglementaire, mode démo (4.0bis).

## Règles non négociables
1. **Inspecte le dépôt avant de proposer ou de coder** ; si le dépôt diffère des hypothèses des specs, signale-le et adapte-toi au dépôt.
2. Une branche et une PR par étape, dans l'ordre indiqué dans chaque spec. Pas de gros changement transversal en une seule PR.
3. **Aucun envoi réel de message en dev/test** : fournisseur `mock/console` par défaut. En mode démo, envois réels uniquement vers les contacts `is_demo_contact=true`.
4. **Ne décide jamais de la classification réglementaire** (médicament restreint ou non) : elle vient du propriétaire (démo) ou d'un pharmacien (production). Ne remplis aucune liste de stupéfiants/psychotropes de ta propre initiative.
5. **Aucune ordonnance** n'est collectée, stockée ou vérifiée (ni photo, ni scan, ni numéro).
6. Aucune donnée personnelle de patient visible par une pharmacie. Contacts chiffrés ; jamais dans les logs.
7. Secrets (jeton Telegram, clés SMS/email, clé de signature) uniquement en variables d'environnement, jamais dans le dépôt ni dans la conversation.
8. Pas de framework frontend ajouté (HTML/CSS/JS vanilla). Textes d'interface en français.
9. Migrations SQL versionnées et rétro-compatibles ; tests obligatoires pour le moteur de routage, la validation d'import et les règles RLS.
10. Avant de déclarer une étape terminée, exécute les tests et passe en revue les critères d'acceptation de la section correspondante.
