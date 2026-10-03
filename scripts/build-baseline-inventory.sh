#!/usr/bin/env bash
# Régénère supabase/baseline/inventory.expected.txt à partir d'une base JETABLE (Supabase local
# ou Postgres + PostGIS avec les rôles anon/authenticated/service_role et auth.uid()).
#
#   DATABASE_URL=postgresql://... scripts/build-baseline-inventory.sh
#
# La base doit être vide : le script y applique setup_consolide.sql. NE JAMAIS la pointer vers la prod.
set -euo pipefail
: "${DATABASE_URL:?DATABASE_URL (base jetable) requis}"
cd "$(dirname "$0")/.."
psql "$DATABASE_URL" -v ON_ERROR_STOP=0 -q -f supabase/setup_consolide.sql >/dev/null
{
  echo "# Inventaire attendu du schéma public — généré par supabase/diagnostics/schema_inventory.sql"
  echo "# sur setup_consolide.sql (correctifs profils_pharmacie_id et pharmacies_colonnes_protegees inclus)."
  echo "# Ne pas éditer à la main : voir scripts/build-baseline-inventory.sh."
  psql "$DATABASE_URL" -X -q -t -A -f supabase/diagnostics/schema_inventory.sql | grep -v '^info|'
} > supabase/baseline/inventory.expected.txt
echo "OK : supabase/baseline/inventory.expected.txt régénéré"
