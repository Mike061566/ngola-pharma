/**
 * Termes de recherche utilisateur -> filtres PostgREST.
 *
 * `query.or('nom.ilike.%' + q + '%,...')` est une chaîne analysée par PostgREST : une virgule,
 * une parenthèse ou un point dans `q` permet d'injecter des filtres supplémentaires
 * (ex. `x%,id.not.is.null`). On ne laisse donc passer que des lettres, chiffres, espaces et
 * quelques signes courants dans les noms de médicaments ; les jokers LIKE (% _ *) sont retirés.
 */
const MAX_SEARCH_LENGTH = 100;

function sanitizeSearchTerm(raw) {
  if (typeof raw !== 'string') return '';
  return raw
    .normalize('NFC')
    .replace(/[^\p{L}\p{N}\s'’\-/.+]/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, MAX_SEARCH_LENGTH)
    .trim();
}

/** Filtre `or()` : le terme (déjà passé par sanitizeSearchTerm) doit apparaître dans l'une des colonnes. */
function orIlike(columns, term) {
  return columns.map((col) => `${col}.ilike.%${term}%`).join(',');
}

module.exports = { sanitizeSearchTerm, orIlike, MAX_SEARCH_LENGTH };
