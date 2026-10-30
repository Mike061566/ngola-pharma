# Audit UI/UX — N'Gola Pharma (étape 0)

> Audit seul : **aucun fichier de l'interface n'a été modifié**. À valider avant toute PR `ui/*`.
> Périmètre : `public/index.html` (site public) et `public/pro.html` (Espace Pro). Date : 30/10/2026.
> Sources : skill *ui-ux-pro-max* (règles accessibilité, interaction, performance, typographie), doc Motion (MCP),
> catalogue 21st.dev (MCP, métadonnées seulement : aucun code payant récupéré), mesures faites sur le dépôt.

## Méthode et limites des mesures

| Mesure | Outil | Limite |
|---|---|---|
| Captures 360 px et 1280 px | Playwright (Chromium), serveur statique local | Appels Supabase et CDN **bloqués** : les listes dynamiques (résultats, quartiers réels) n'apparaissent pas |
| Scores | Lighthouse 12 (mobile, simulation 3G lente) en local | Sans les CDN : `supabase-js` et `xlsx` ne sont **pas comptés**. Les vrais scores de performance seront plus bas. La mesure de référence sera refaite sur l'aperçu Netlify dans la PR 1 |
| Cibles tactiles, champs sans libellé, animations infinies | Script Playwright sur le DOM rendu | Ne voit que l'état initial (pas les modales ni les résultats) |
| Contrastes | Calcul WCAG 2.x (luminance relative) | Couleurs relevées dans le CSS, pas sur chaque pixel |
| Poids de Motion | `npm install motion@14.8.0` puis bundle esbuild minifié, gzip -9 | Le CDN jsDelivr n'est pas joignable depuis le conteneur : poids mesuré sur le paquet npm, pas sur la réponse du CDN |

### Référence mesurée (« avant »)

| Page | Performance | Accessibilité | Bonnes pratiques | FCP / LCP | CLS | Poids (hors CDN) |
|---|---|---|---|---|---|---|
| `index.html` | 92 | **86** | 96 | 2,7 s / 2,7 s | 0 | 247 Ko |
| `pro.html` | 97 | **89** | 96 | 2,2 s / 2,2 s | 0 | 212 Ko (+ ≈ 315 Ko gzip de `xlsx`, non compté) |

Audits d'accessibilité Lighthouse en échec : `button-name`, `color-contrast`, `heading-order`, `landmark-one-main`, `label-content-name-mismatch` (index) ; `color-contrast`, `landmark-one-main` (pro).

Captures « avant » : `docs/design/captures/avant-index-mobile.png`, `avant-index-bureau.png`, `avant-pro-mobile.png`.

---

## 1. Problèmes classés par gravité

### Bloquant (à corriger avant la présentation aux pharmaciens ou le lancement public)

| # | Problème | Preuve | Principe |
|---|---|---|---|
| B1 | **Chiffres et promotions écrits en dur, présentés comme réels.** « Disponibilité en temps réel · 52 pharmacies », « 8 pharmacies ouvertes », « DISPONIBLES 24/7 », « 15 médicaments en promotion · Jusqu'à dimanche 23:59 », « −25 % », « 3ᵉ médicament offert », compteurs de quartier (12 + 8 + 15 + 10 + 5 + 1 = 51, pas 52). | `index.html` l. 1367, 1404–1431, 1455–1500, 1539–1560, bandeau `.promo-banner` | Confiance (heuristique n° 1 : visibilité de l'état réel). Contredit le bandeau « MODE DÉMO — aucune disponibilité réelle n'est garantie » (SPEC 2 §4.0bis). |
| B2 | **Cartes cliquables inaccessibles au clavier.** 6 cartes de quartier et toutes les cartes de résultat sont des `<div onclick>` sans `tabindex` ni rôle. | Mesure DOM : 6 `div[onclick]` sans clavier ; `renderPharmacyCard` (l. 2330) | WCAG 2.1.1 Clavier (A) |
| B3 | **Bouton de recherche sans nom accessible** : seule une icône SVG. Le lecteur d'écran annonce « bouton ». | `#searchBtn` l. 1371 ; Lighthouse `button-name` | WCAG 4.1.2 Nom, rôle, valeur (A) |
| B4 | **Contrastes insuffisants** sur le texte secondaire : `#999` sur blanc 2,85:1 (15 usages), `#888` 3,54:1 (9 usages), `#999` sur `#F8F9FA` 2,70:1 ; texte blanc sur vert `#28a745` 3,13:1. | Calcul, Lighthouse `color-contrast` | WCAG 1.4.3 Contraste (AA, 4,5:1) |
| B5 | **Animations en boucle non désactivables** : bandeau promo défilant (28 s, infini), deux pastilles pulsantes infinies. `index.html` n'a qu'un bloc `prefers-reduced-motion` (bandeau seulement). `pro.html` n'en a aucun. | Mesure : `pulse`, `scroll`, `qaPulse` infinis | WCAG 2.2.2 Mettre en pause (A), 2.3.3 ; contrainte du prompt (« pas d'animation en boucle ») |

### Important

| # | Problème | Preuve | Principe |
|---|---|---|---|
| I1 | **Cibles tactiles trop petites** : 21 éléments interactifs sur 30 font moins de 44 px sur mobile. Exemples : boutons FR/EN 37×22, « Espace Pro » 84×28, liens « Recherches populaires » 15 px de haut, bouton « Itinéraire » ≈ 26 px. | Mesure Playwright 360 px | WCAG 2.5.8 (AA, 24 px min.) ; règle du prompt et du skill : 44 px |
| I2 | **Pas de repère `<main>`**, ordre des titres sauté (h1 → h3 dans les cartes, h4 pour les quartiers). | Lighthouse `landmark-one-main`, `heading-order` | WCAG 1.3.1, 2.4.1 |
| I3 | **Combobox de recherche non conforme** : pas de `role="combobox"`, `aria-expanded`, `aria-controls` ni `aria-activedescendant`. Les suggestions ne sont pas annoncées. Le champ n'a pas de libellé, seulement un placeholder. | `#searchInput` l. 1370 ; 1 champ sans libellé | WCAG 1.3.1, 4.1.2 ; motif ARIA APG Combobox |
| I4 | **États de chargement, vide et erreur minimalistes et non annoncés** : spinner seul, texte gris `#999`, « Erreur de connexion » rouge sans bouton « Réessayer ». Pas d'`aria-live`, pas d'état hors ligne. | `fullSearch`, `showQuartier`, `showBestPrices` (l. 2216–2600) | Heuristique n° 9 (aider à récupérer d'une erreur) ; WCAG 4.1.3 Messages d'état |
| I5 | **Tokens absents** : 66 couleurs hexadécimales distinctes, 3 `var(--…)` seulement dans `index.html`. `pro.html` a déjà `--primary`, `--accent`, `--success`, `--danger`, `--warning`. | Comptage | Cohérence (heuristique n° 4) |
| I6 | **Filigrane PNG de 89 Ko encodé en base64 dans `:root`** (`--bg-pills`). Il fait 37 % du poids de la page et est téléchargé avant tout rendu, sans cache séparé. | `index.html` l. 16 | Performance 3G : budget du premier rendu |
| I7 | **Librairie Excel (`xlsx` 0.18.5, 862 Ko, ≈ 315 Ko gzip) chargée dès l'écran de connexion** de `pro.html`, alors qu'elle ne sert qu'à l'import. | `pro.html` l. 587 | Performance : chargement à la demande |
| I8 | **Couleur seule pour l'état** : le statut de garde utilise du vert, comme « disponible ». La pastille 🟢 n'a pas d'équivalent textuel partout. Le statut du stock est souvent une couleur de fond. | `.badge-garde`, `.badge-garde-confirmee` | WCAG 1.4.1 Utilisation de la couleur |
| I9 | **Emoji utilisés comme icônes** (📍 🏥 💊 🟢 📥 🛡️…). Le rendu varie selon l'Android, ils sont lus par les lecteurs d'écran et ne s'alignent pas avec les SVG déjà présents (logo, quartiers). | En-têtes de `pro.html`, cartes de résultat | Skill : « SVG icons, no emoji » ; cohérence |
| I10 | **Textes traduits en dur dans le JS** (`currentLang === 'en' ? … : …`) au lieu des dictionnaires `T.fr` / `T.en`. Une même chaîne peut diverger entre les deux. | 97 occurrences dans `index.html` | Contrainte i18n du prompt |

### Confort

| # | Problème | Preuve |
|---|---|---|
| C1 | Hero : l'action secondaire « Pharmacies de garde près de moi » est en vert sur bleu, avec pastille animée. Elle concurrence visuellement la recherche. | Capture mobile |
| C2 | Sur mobile, le bouton de recherche or passe **sous** le champ, en pleine largeur : il double la hauteur de la barre. | Capture mobile |
| C3 | Les prix ne sont pas en chiffres tabulaires : les colonnes de comparaison ne s'alignent pas. | Aucun `tabular-nums` dans `index.html` (1 seul dans `pro.html`) |
| C4 | Tailles de police très petites : 9 px (×2), 11 px (×7), 12 px (×22). | Comptage CSS |
| C5 | `pro.html` : onglets en `<button>` sans `role="tablist"` / `aria-selected`. Pas de `<h1>`. 10 champs sans libellé associé (formulaires masqués compris). | Mesure DOM |
| C6 | Le mode démo (bandeau ambre `#B26A00`, blanc 4,24:1) est **sous le seuil AA** pour un texte de 13 px. | Calcul |
| C7 | Liens de pied de page « Blog », « Carrières » : ils ouvrent des modales probablement vides pour un MVP. | Pied de page l. 1600+ |

**Ce qui marche déjà et doit rester** : la hiérarchie du hero (un seul titre, une barre de recherche dominante), le logo SVG léger, `lang="fr"` et le viewport correct, aucun débordement horizontal à 360 px, CLS = 0, les badges existants « Vérifié N'Gola », « Données de démonstration » et de fraîcheur du stock (`freshnessBadge`), le bandeau démo en `role="status"`.

---

## 2. Mini système de design (variables CSS)

Il **part de l'existant** : bleu marine `#003366` (identité, logo, 41 usages) et or `#FFD700` (logo, bouton de recherche) sont conservés. Les noms de `pro.html` (`--primary`, `--accent`, `--success`, `--danger`, `--warning`) restent valables comme alias, pour ne rien casser. Tous les couples texte/fond ci-dessous ont été calculés.

```css
:root {
  /* ── Couleurs de marque (inchangées) ───────────────────────── */
  --ng-marine:        #003366;  /* blanc dessus : 12,61:1 */
  --ng-marine-clair:  #004488;
  --ng-or:            #FFD700;  /* uniquement avec --ng-marine dessus : 8,99:1 (jamais de texte blanc : 1,40:1) */

  /* ── Rôles ─────────────────────────────────────────────────── */
  --ng-action:        #0F6E68;  /* « santé » bleu-vert, boutons secondaires et liens : blanc 6,09:1, sur blanc 6,09:1 */
  --ng-garde:         #B42318;  /* RÉSERVÉ aux pharmacies de garde : blanc 6,57:1 */
  --ng-garde-fond:    #FEE4E2;

  /* ── Statuts du stock (toujours couleur + icône + texte) ───── */
  --ng-dispo:         #166534;  --ng-dispo-fond:   #DCFCE7;  /* 6,49:1 */
  --ng-faible:        #854D0E;  --ng-faible-fond:  #FEF3C7;  /* 6,15:1 */
  --ng-rupture:       #374151;  --ng-rupture-fond: #F3F4F6;  /* 9,37:1 — gris neutre : le rouge reste à la garde */
  --ng-verifie:       #0C5460;  --ng-verifie-fond: #D1ECF1;  /* 6,92:1 (badge existant) */
  --ng-demo:          #8A4B00;  /* bandeau démo : blanc 6,80:1 (actuel #B26A00 : 4,24:1, insuffisant) */

  /* ── Texte et surfaces ─────────────────────────────────────── */
  --ng-texte:         #1F2937;  /* 14,68:1 sur blanc */
  --ng-texte-2:       #4B5563;  /* 7,56:1 sur blanc, 7,17:1 sur --ng-fond — remplace #999/#888 */
  --ng-texte-3:       #6B7280;  /* 4,83:1 : minimum pour du texte, à réserver aux métadonnées ≥ 14 px */
  --ng-fond:          #F8F9FA;
  --ng-surface:       #FFFFFF;
  --ng-bord:          #E5E7EB;  /* décoratif */
  --ng-bord-champ:    #6B7280;  /* bord de champ : 4,83:1, au-dessus de 3:1 (WCAG 1.4.11) */
  --ng-focus:         #1D4ED8;  /* anneau de focus 3 px : 6,70:1 sur blanc ; sur fond marine utiliser --ng-or (8,99:1) */

  /* ── Typographie : police système (0 octet téléchargé) ─────── */
  --ng-police: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Noto Sans", sans-serif;
  --ng-t-xs:  0.8125rem;  /* 13 px : plancher absolu (mentions, badges) */
  --ng-t-sm:  0.875rem;   /* 14 px : métadonnées */
  --ng-t-md:  1rem;       /* 16 px : corps, champs (évite le zoom iOS) */
  --ng-t-lg:  1.125rem;   /* 18 px : prix, titres de carte */
  --ng-t-xl:  1.375rem;   /* 22 px : titres de section */
  --ng-t-2xl: clamp(1.75rem, 1.2rem + 2.5vw, 2.5rem); /* titre du hero */
  --ng-interligne: 1.5;
  --ng-chiffres: tabular-nums; /* à appliquer à tous les prix et compteurs */

  /* ── Espacements (base 4 px) ───────────────────────────────── */
  --ng-e-1: 4px; --ng-e-2: 8px; --ng-e-3: 12px; --ng-e-4: 16px; --ng-e-5: 24px; --ng-e-6: 32px; --ng-e-7: 48px;
  --ng-cible: 44px; /* hauteur et largeur minimales d'un élément tactile */

  /* ── Rayons et ombres ──────────────────────────────────────── */
  --ng-r-sm: 6px; --ng-r-md: 10px; --ng-r-lg: 16px; --ng-r-pilule: 999px;
  --ng-ombre-1: 0 1px 2px rgb(16 24 40 / .06), 0 1px 3px rgb(16 24 40 / .10);
  --ng-ombre-2: 0 4px 12px rgb(16 24 40 / .10);

  /* ── Mouvement ─────────────────────────────────────────────── */
  --ng-d-rapide: 120ms;   /* retour tactile, survol */
  --ng-d-moyen:  200ms;   /* apparition d'un élément */
  --ng-d-lent:   300ms;   /* plafond : panneau, modale (sortie ≈ 70 % de l'entrée) */
  --ng-courbe-sortie: cubic-bezier(.2, 0, 0, 1);  /* entrée d'élément */
  --ng-courbe-entree: cubic-bezier(.3, 0, 1, 1);  /* sortie d'élément */
}
@media (prefers-reduced-motion: reduce) {
  :root { --ng-d-rapide: 0ms; --ng-d-moyen: 0ms; --ng-d-lent: 0ms; }
}
```

Le préfixe `--ng-` évite toute collision avec les variables de `pro.html`. Dans la PR 1, les anciennes variables pointent vers les nouvelles (`--primary: var(--ng-marine)`), puis on remplace les valeurs en dur fichier par fichier.

---

## 3. Recommandations du prompt : garder, adapter ou écarter

### A. Système de design

| Recommandation | Verdict | Justification |
|---|---|---|
| Tokens de couleur, primaire « santé » vert ou bleu-vert | **Adapter** | La marque reste le marine `#003366`, déjà identitaire. Le bleu-vert `#0F6E68` sert de couleur d'action « santé », sans rebranding. |
| Couleur d'urgence réservée à la garde | **Garder** | `#B42318` exclusif à la garde. La rupture passe en gris neutre pour éviter deux rouges. |
| Statuts sans couleur seule (icône + texte) | **Garder** | Corrige I8, WCAG 1.4.1. |
| Hiérarchie typographique, prix en `tabular-nums` | **Garder** | Coût nul (police système), gain direct sur la comparaison. |
| Hero : une action principale, une secondaire claire | **Adapter** | Déjà presque le cas. Il suffit de calmer le bouton « garde » (contour, sans pulsation) et de garder le bouton de recherche dans la barre sur mobile. |
| Cartes pharmacie (nom, quartier, ouverture, prix, statut, Appeler / Itinéraire) | **Garder** | Ajouter « Appeler » en bouton de 44 px (aujourd'hui le téléphone est un lien de 12 px). |
| Distance sur la carte | **Adapter** | Seulement quand la géolocalisation est acceptée (déjà calculée dans `renderPharmacyCardWithDistance`), jamais demandée d'office. |
| États chargement / vide / erreur / hors ligne | **Garder** | Corrige I4. Squelettes réservant la hauteur (CLS = 0), « Réessayer », `aria-live="polite"`. |
| Badges vérifiée, date de mise à jour, mode démo | **Garder (existe déjà)** | Les badges existent. Il faut les rendre lisibles (contraste, texte), afficher la date sur chaque prix et corriger le contraste du bandeau démo. |
| `pro.html` : stepper d'import, erreurs ligne par ligne, tableau tablette | **Adapter** | L'import guidé (SPEC 1) a déjà correspondance, aperçu, erreurs par ligne et validation. On l'habille en stepper sans toucher à la logique (`import-ui.js`, `import-utils.js`). |

### B. Micro-interactions

| Recommandation | Verdict | Justification |
|---|---|---|
| Cascade des cartes (`stagger`, ≤ 300 ms) | **Adapter : CSS pur** | Une `transition-delay` calculée (`--i`) suffit. Jamais au-delà des 6 premières cartes. Le contenu est inséré visible, l'animation ne fait que l'adoucir. |
| `inView` pour les sections, une seule fois | **Adapter : `IntersectionObserver` natif** | `inView` de Motion n'est qu'un enrobage d'`IntersectionObserver` (501 o gzip mesurés). 10 lignes natives font la même chose sans dépendance. Le contenu reste visible si le JS échoue (classe ajoutée par JS seulement). |
| Retour tactile (`scale` au toucher), puces sélectionnées | **Garder, en CSS** | `:active { transform: scale(.97) }` sur 120 ms. Zéro JS. |
| Transition du panneau ou de la modale de résultats | **Garder** | `opacity` + `translateY(8px)`, 200 ms ; focus déplacé dans la modale et rendu à la fermeture. |
| Animation de l'icône à l'abonnement à une alerte | **Garder** | Une coche qui se dessine (stroke-dashoffset, 300 ms) dans un toast `role="status"`. |
| Focus animé de la recherche, suggestions sans saut | **Garder** | Anneau de focus en `box-shadow`, liste en `position:absolute` (pas de saut de mise en page). |
| Interdits : boucles, défilement détourné, > 400 ms | **Garder** | Impose de supprimer le bandeau défilant et les deux pulsations (B5). |
| Module `motion` partagé + garde `prefers-reduced-motion` | **Adapter** | Voir l'encadré ci-dessous : module **`public/ui-mouvement.js` sans Motion** au départ ; Motion seulement si un besoin réel l'exige. |

> **Poids de Motion 14.8.0 (mesuré, bundle minifié, gzip -9)** : `animate` complet **25,2 Ko** ; `animate` + `inView` + `stagger` **25,8 Ko** ; `animate` version *mini* (`motion/mini`) **3,3 Ko** ; `inView` seul 0,5 Ko ; `stagger` seul 0,9 Ko.
> 25 Ko gzip, c'est environ 0,5 s de plus en 3G lente, pour des effets que CSS et `IntersectionObserver` couvrent entièrement ici. Ce n'est pas raisonnable pour cette page.
> **Proposition** : la PR 3 se fait **en CSS pur + `IntersectionObserver`** (0 Ko de dépendance). Si un effet ne peut vraiment pas se faire en CSS (ressort physique, interruption fluide), on charge `motion/mini` (3,3 Ko) en ESM version figée, **à la demande** (`import()` au premier usage), jamais dans le chemin critique. Je vérifierai l'URL et le poids réellement servis par le CDN depuis l'aperçu Netlify : le CDN n'est pas joignable d'ici.

### C. Composants inspirés de 21st.dev (réécrits en vanilla)

Recherches faites sur 21st.dev (métadonnées gratuites seulement). Le code React n'est ni récupéré ni importé : il est payant au détail, et seul le **motif** nous intéresse. Il sera réécrit à la main, en partant du motif ARIA officiel quand il existe.

| Composant | Verdict | Inspiration 21st.dev | Base de réécriture |
|---|---|---|---|
| Recherche avec suggestions | **Garder** | « Autocomplete » (cubby-ui), « Combobox » (shugar, halaska-studio) | Motif APG *Combobox with listbox popup* : `role="combobox"`, `aria-expanded`, `aria-controls`, `aria-activedescendant`, ↑/↓/Entrée/Échap |
| Carte de résultat avec badges | **Garder** | (motif générique, pas de composant pertinent retenu) | `<article>` contenant un vrai `<a>` ou `<button>` pour le détail, plus deux boutons « Appeler » / « Itinéraire » |
| Puces / filtres défilables | **Adapter** | — | Les quartiers sont aujourd'hui une grille de cartes. Sur mobile, proposer une rangée de puces défilable (`scroll-snap`), avec boutons `aria-pressed` |
| Squelettes et états vides | **Garder** | « Card Skeleton » (uiable), « Skeleton » (shadcn) | CSS seul. Hauteur identique à la carte réelle. Le shimmer est désactivé en mouvement réduit (c'est une boucle, donc seulement pendant le chargement) |
| Toast de confirmation | **Garder** | — | `role="status"`, 4 s, fermable, sans empiler plus de 2 toasts |
| Zone de dépôt (glisser-déposer + bouton) | **Garder** | « File Dropzone » (joyco), « UploadThing Dropzone » | Un `<input type="file">` réel avec `<label>` (le glisser-déposer n'est qu'un bonus) |
| Stepper d'import | **Adapter** | « Illos Upload Dropzone » écarté (illustration animée lourde) | `<ol>` d'étapes avec `aria-current="step"`, branché sur les étapes déjà existantes de l'import guidé |
| « Halo Dropzone » (bordure animée lumineuse) | **Écarter** | cult-ui | Effet décoratif en boucle, contraire au ton sobre demandé |

---

## 4. Écarts entre le prompt et le dépôt ou `CLAUDE.md` (à trancher)

1. **« Deux fichiers statiques »** : c'est inexact. `public/` contient aussi `devenir-partenaire.html`, `activer.html`, `complements.html`, `alerte.html`, `reponse.html` et une dizaine de scripts (`import-ui.js`, `admin-*.js`, `demo-banner.js`…). Les tokens devront être partagés : je propose un fichier `public/ui-tokens.css` (statique, sans build), sinon le `:root` sera dupliqué dans 7 pages.
2. **Motion via CDN** : le prompt l'autorise, et la règle 8 de `CLAUDE.md` n'interdit que les *frameworks*. Vu le poids mesuré, je recommande de **ne pas** l'ajouter au départ (voir B). C'est votre décision.
3. **Offres et promotions (B1)** : le prompt demande de les animer (« révéler les sections offres »). Ce sont des promotions fictives de médicaments. En mode démo, elles contredisent le bandeau « données fictives ». En production, elles engagent la plateforme sur des prix et des remises qu'aucune pharmacie n'a déclarés. **Je ne tranche pas le cadre réglementaire de la publicité sur les médicaments** (même esprit que la règle 4) : la décision de garder la section, de l'étiqueter « exemple » ou de la retirer vous revient, après avis du pharmacien validateur.
4. **Branches** : la session impose de travailler sur `claude/friendly-albattani-4yd1y8` (PR [#4](https://github.com/Mike061566/ngola-pharma/pull/4), onboarding, non fusionnée). Le prompt et la règle 2 de `CLAUDE.md` demandent une branche et une PR par étape (`ui/tokens`, …). Il faut votre accord explicite pour créer ces branches. Il faut aussi savoir si elles partent de `main` (sans l'onboarding) ou de la PR #4 (qui modifie déjà `pro.html`). Mon avis : **attendre la fusion de la PR #4**, puis partir de `main`, sinon chaque PR `ui/*` sera en conflit sur `pro.html`.
5. **« Ne modifie pas `src/` »** : compatible, aucune des PR ne touche `src/`.

---

## 5. Découpage en PR proposé

Ordre du prompt conservé. Chaque PR inclut captures avant/après (360 et 1280 px, Playwright), Lighthouse mobile comparé à `main`, test clavier et mouvement réduit, et la preuve qu'aucun appel Supabase n'est modifié (diff vide sur les `.from(` / `.rpc(`).

| PR | Branche | Contenu | Corrige | Risque |
|---|---|---|---|---|
| 0 *(proposée)* | `ui/contenus-reels` | **Avant tout le reste** : remplacer les chiffres en dur par des valeurs lues (ou les retirer), et traiter la section offres selon votre décision (point 4.3). Ce sont uniquement des textes et des dictionnaires i18n. | B1 | Faible ; décision de contenu requise |
| 1 | `ui/tokens` | `public/ui-tokens.css` + alias des anciennes variables ; contrastes corrigés (`#999`/`#888` → `--ng-texte-2`) ; plancher 13 px ; `tabular-nums` sur les prix ; anneau de focus global ; filigrane base64 sorti en fichier `.webp` mis en cache (ou supprimé) ; suppression des boucles (B5) et bloc `prefers-reduced-motion` global. Mise en page inchangée. | B4, B5, I5, I6, C3, C4, C6 | Faible (visuel seulement) |
| 2 | `ui/recherche-resultats` | `<main>` et ordre des titres ; combobox APG ; bouton de recherche nommé ; cartes en `<article>` focusables avec « Appeler » / « Itinéraire » de 44 px ; squelettes, états vide / erreur avec « Réessayer » / hors ligne, `aria-live` ; chaînes déplacées dans les dictionnaires i18n. | B2, B3, I1, I2, I3, I4, I10 | Moyen : touche au rendu des résultats (fonctions `render*`), sans toucher aux requêtes |
| 3 | `ui/motion` | `public/ui-mouvement.js` (CSS + `IntersectionObserver`, garde mouvement réduit) ; cascade ≤ 300 ms ; retour tactile ; transitions de la modale ; toast d'alerte. Motion seulement si vous le décidez (point 4.2). | — | Faible |
| 4 | `ui/garde-confiance` | Couleur garde exclusive + icône SVG + texte ; badges « Vérifiée » et statut du stock en couleur + icône + texte ; date de mise à jour sur chaque prix ; emoji remplacés par des SVG en ligne. | I8, I9 | Faible |
| 5 | `ui/espace-pro` | `pro.html` : `<h1>`, `<main>`, onglets ARIA (`tablist`) ; stepper sur l'import guidé existant ; zone de dépôt accessible ; tableau de stocks lisible sur tablette ; **`xlsx` chargé à la demande** à l'ouverture de l'import. | I7, C5 | Moyen : à faire après fusion de la PR #4 (même fichier) |

---

## Décisions du propriétaire (validées le 30/10/2026)

| # | Question | Décision | Conséquence pour les PR |
|---|---|---|---|
| 1 | Section « Offres », bandeau promo, promotions fictives | **Garder, avec une étiquette « Exemple »** | PR 0 : étiquette « Exemple » visible (texte, pas seulement couleur) sur chaque offre et sur le bandeau, ajoutée aux dictionnaires FR/EN. Le défilement en boucle du bandeau reste supprimé en PR 1 (interdit par le prompt et WCAG 2.2.2) : le bandeau devient statique ou défilable à la main. |
| 2 | Motion | **Aucune dépendance au départ** | PR 3 en CSS + `IntersectionObserver`, 0 Ko ajouté. Motion n'est réévalué que si un effet ne peut pas se faire en CSS, avec une nouvelle validation. |
| 3 | Couleur « santé » | **Bleu-vert `#0F6E68` pour les boutons d'action, marine `#003366` conservé comme marque** | Tokens de la section 2 adoptés tels quels. |
| 4 | Branches | **`ui/*` à partir de `main`, après la fusion de la PR #4** | Aucune branche `ui/*` créée tant que la PR #4 n'est pas fusionnée. |
| 5 | PR 0 « contenus réels » | **En tête, avant tout travail de design** (ou fondue dans la PR 2) | PR 0 en premier : `ui/contenus-reels`. |

**Périmètre retenu pour la PR 0 (« textes seulement »)** : les chiffres en dur (« 52 pharmacies », « 8 pharmacies ouvertes », « DISPONIBLES 24/7 », « 15 médicaments en promotion », « Jusqu'à dimanche 23:59 », compteurs de quartier) sont remplacés par des **formulations sans chiffre** (par exemple « Pharmacies de Yaoundé », « Voir les pharmacies ouvertes maintenant »). Ils ne sont **pas** remplacés par des valeurs lues dans Supabase : cela ajouterait des requêtes, contraire à « ne touche pas à la logique Supabase ». Si vous voulez de vrais compteurs, ce sera une PR séparée, à valider. Changements limités au HTML et aux dictionnaires `T.fr` / `T.en`, sans mise en page ni JS de logique.
