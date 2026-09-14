# 🏥 N'Gola Pharma API

> API REST pour N'Gola Pharma — Trouvez vos médicaments à Yaoundé, Cameroun.

## Stack technique

- **Runtime** : Node.js ≥ 18 + Express
- **Base de données** : Supabase (PostgreSQL + PostGIS)
- **Auth** : Supabase Auth (JWT)
- **CI** : GitHub Actions

## Démarrage rapide

```bash
# 1. Cloner le dépôt
git clone https://github.com/votre-org/ngola-pharma-api.git
cd ngola-pharma-api

# 2. Installer les dépendances
npm install

# 3. Configurer les variables d'environnement
cp .env.example .env
# → Renseigner SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_KEY

# 4. Appliquer le schéma Supabase
# Exécuter supabase/migrations/001_schema.sql dans le SQL Editor de Supabase

# 5. Peupler la base
npm run seed

# 6. Lancer le serveur
npm run dev
```

## Endpoints API

### Santé

| Méthode | Route | Description |
|---------|-------|-------------|
| `GET` | `/api/health` | Health check |

### Quartiers

| Méthode | Route | Description |
|---------|-------|-------------|
| `GET` | `/api/quartiers` | Liste des 7 quartiers |
| `GET` | `/api/quartiers/:slug` | Détail + pharmacies du quartier |

### Pharmacies

| Méthode | Route | Description |
|---------|-------|-------------|
| `GET` | `/api/pharmacies` | Liste paginée (filtres: `quartier`, `statut`, `garde`, `q`) |
| `GET` | `/api/pharmacies/proches` | Recherche géographique (`lat`, `lng`, `rayon`) |
| `GET` | `/api/pharmacies/:id` | Détail + stock de la pharmacie |

### Médicaments

| Méthode | Route | Description |
|---------|-------|-------------|
| `GET` | `/api/medicaments` | Liste paginée (filtres: `q`, `categorie`, `ordonnance`) |
| `GET` | `/api/medicaments/categories` | Liste des catégories |
| `GET` | `/api/medicaments/:id` | Détail + disponibilité par pharmacie |

### Stocks

| Méthode | Route | Description |
|---------|-------|-------------|
| `GET` | `/api/stocks` | Recherche de prix (filtres: `medicament`, `pharmacie_id`, `tri`) |
| `GET` | `/api/stocks/meilleurs-prix` | Meilleur prix par médicament |

## Structure du projet

```
ngola-pharma-api/
├── src/
│   ├── index.js              # Point d'entrée Express
│   ├── config/
│   │   └── supabase.js       # Client Supabase
│   ├── routes/
│   │   ├── pharmacies.js     # CRUD pharmacies + géolocalisation
│   │   ├── medicaments.js    # Catalogue médicaments
│   │   ├── quartiers.js      # Quartiers de Yaoundé
│   │   └── stocks.js         # Prix et disponibilité
│   ├── middleware/
│   │   ├── auth.js           # Auth JWT Supabase
│   │   └── errorHandler.js   # Gestion centralisée des erreurs
│   └── utils/
│       └── seed.js           # Import CSV → Supabase
├── supabase/
│   ├── migrations/
│   │   └── 001_schema.sql    # Schéma complet (PostGIS, RLS)
│   └── seed/
│       ├── seed.sql           # Script SQL alternatif
│       ├── quartiers.csv
│       ├── pharmacies.csv
│       └── medicaments.csv
├── .env.example
├── .github/workflows/ci.yml
└── package.json
```

## Données

- **7 quartiers** : Centre-Ville, Bastos, Essos, Mvan, Ngousso, Odza, Nlongkak
- **52 pharmacies** avec coordonnées GPS, horaires, téléphone
- **20 médicaments** essentiels (paracétamol, antibiotiques, antipaludéens…)
- **Statuts** : `non_verifie` → `verifie` → `partenaire`

## Licence

MIT — N'Gola Pharma
