#!/usr/bin/env bash
# Régénère supabase/baseline/inventory.expected.txt à partir d'une base JETABLE (Supabase local
# ou Postgres + PostGIS avec les rôles anon/authenticated/service_role et auth.uid()).
#
#   DATABASE_URL=postgresql://... scripts/build-baseline-inventory.sh
#
# La base doit être vide : le script y applique les migrations de supabase/migrations/ dans l'ordre.
# NE JAMAIS la pointer vers la prod.
set -euo pipefail
: "${DATABASE_URL:?DATABASE_URL (base jetable) requis}"
cd "$(dirname "$0")/.."
for f in $(ls supabase/migrations/*.sql | sort); do
  echo "migration : $f" >&2
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$f" >/dev/null
done
{
  echo "# Inventaire attendu du schéma public — généré par supabase/diagnostics/schema_inventory.sql"
  echo "# sur les migrations de supabase/migrations/. Ne pas éditer à la main :"
  echo "# voir scripts/build-baseline-inventory.sh."
  psql "$DATABASE_URL" -X -q -t -A -f supabase/diagnostics/schema_inventory.sql | grep -v '^info|'
} > supabase/baseline/inventory.expected.txt
echo "OK : supabase/baseline/inventory.expected.txt régénéré"
