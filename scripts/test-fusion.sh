#!/usr/bin/env bash
# Teste la migration de fusion des fiches medicaments et son retour arrière sur des données SYNTHÉTIQUES.
# Base jetable uniquement (Supabase local / CI), schéma déjà migré. Tout est annulé à la fin du test.
#
#   DATABASE_URL=postgresql://... scripts/test-fusion.sh
set -uo pipefail
: "${DATABASE_URL:?DATABASE_URL (base jetable) requis}"
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Les fichiers de production portent leur propre BEGIN/COMMIT : on les retire pour les jouer dans la transaction du test.
grep -v -x -E 'BEGIN;|COMMIT;' supabase/migrations/20261003100000_fusion_doublons_medicaments.sql > "$tmp/migration.sql"
grep -v -x -E 'BEGIN;|COMMIT;' supabase/rollback/20261003100000_fusion_doublons_medicaments_rollback.sql > "$tmp/rollback.sql"
out="$(cd scripts/test-fusion && psql "$DATABASE_URL" -X -q -v migration="$tmp/migration.sql" -v rollback="$tmp/rollback.sql" -f fusion.test.sql 2>&1)"
echo "$out" | grep -E "TEST OK|ERREUR TEST" || true
attendus=(
  "fusion : 5 fiches supprimées" "fusion : 4 lignes de stock supprimées" "fusion : sauvegarde = 1 déplacé"
  "Ma pharmacie : Coartem 5100 en stock" "Ma pharmacie : Chloroquine 1500 en stock" "Pharmacie B : égalité de date"
  "Pharmacie C : la ligne la plus récente" "Efferalgan (autre marque) intact" "alerte Ibuprofène rattachée" "alerte sans fiche : intacte"
  "index unique présent" "unicité : un nom en double" "retour arrière : fiches, stocks et alertes strictement identiques"
  "retour arrière : index unique retiré" "garde-fou FK : échec" "index impossible : migration annulée" "contrôle final : anomalie détectée"
)
statut=0
for a in "${attendus[@]}"; do
  echo "$out" | grep -q "TEST OK : $a" || { echo "MANQUANT ou en échec : $a"; statut=1; }
done
echo "$out" | grep -q "ERREUR TEST" && statut=1
# Les échecs voulus doivent venir des bons garde-fous
echo "$out" | grep -q "non gérée(s) par cette migration" || { echo "MANQUANT : message du garde-fou FK"; statut=1; }
echo "$out" | grep -q "Index unique impossible" || { echo "MANQUANT : message de l'index impossible"; statut=1; }
echo "$out" | grep -q "aucune alerte ne doit disparaître" || { echo "MANQUANT : message du contrôle final"; statut=1; }
[ "$statut" -eq 0 ] && echo "✅ test de fusion : OK" || { echo "❌ test de fusion : ÉCHEC"; echo "$out" | tail -40; }
exit "$statut"
