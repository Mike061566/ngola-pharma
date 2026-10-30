/**
 * Erreur d'un fournisseur de messages. `type` :
 *  - 'transitoire'   : réessayer plus tard (réseau, 5xx) ;
 *  - 'permanente'    : inutile de réessayer sur ce canal (adresse invalide, bot bloqué) -> canal suivant ;
 *  - 'limite_debit'  : 429, réessayer après `retryApresS` sans compter une tentative.
 * `bloque` : l'adresse est définitivement rejetée -> le contact est marqué bloqué.
 * Le message ne doit JAMAIS contenir d'adresse ni de contenu de message (journaux sans donnée personnelle).
 */
export class ErreurFournisseur extends Error {
  constructor(message, { type = 'transitoire', retryApresS = null, bloque = false } = {}) {
    super(message);
    this.name = 'ErreurFournisseur';
    this.type = type;
    this.retryApresS = retryApresS;
    this.bloque = bloque;
  }
}

/** Modèle de message introuvable ou variables manquantes : réessayer ne servirait à rien. */
export class ErreurModele extends Error {
  constructor(message) {
    super(message);
    this.name = 'ErreurModele';
  }
}
