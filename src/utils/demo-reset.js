/**
 * Remise à zéro des données de démonstration (SPEC 2 §4.0bis) : appelle la fonction SQL `reinitialiser_demo` (atomique, refusée
 * hors mode démo). N'envoie aucun message. Ne touche ni aux contacts de la liste blanche ni à la classification des médicaments.
 */
async function reinitialiserDemo(sb, { nbPharmacies = 6 } = {}) {
  const mode = await sb.rpc('mode_public');
  if (mode.error) throw new Error(`Mode illisible : ${mode.error.code || 'erreur'}`);
  if (mode.data !== 'demo') throw new Error('Remise à zéro refusée : l\'application n\'est pas en mode démo');
  const r = await sb.rpc('reinitialiser_demo', { p_nb_pharmacies: nbPharmacies });
  if (r.error) throw new Error(`Remise à zéro : ${r.error.code || 'erreur'}`);
  return r.data;
}

module.exports = { reinitialiserDemo };
