// Limites de débit (SPEC 2 §6.1) : plafond global du worker et 1 message par discussion et par seconde.
// `maintenant` (ms) et `dormir` (ms) sont injectés pour des tests sans attente réelle.
export function creerLimiteur({ parSeconde = 20, parDiscussionMs = 1000, maintenant = () => Date.now(),
  dormir = (ms) => new Promise((r) => setTimeout(r, ms)) } = {}) {
  const intervalle = parSeconde > 0 ? 1000 / parSeconde : 0;
  let prochainCreneau = 0;
  const dernierParDiscussion = new Map();

  return {
    /** Attend le prochain créneau global (espacement régulier de 1000/parSeconde ms). */
    async attendreGlobal() {
      const t = maintenant();
      const creneau = Math.max(prochainCreneau, t);
      prochainCreneau = creneau + intervalle;
      if (creneau > t) await dormir(creneau - t);
    },
    /** Millisecondes à attendre avant de pouvoir réécrire à cette discussion (0 si possible maintenant). */
    delaiDiscussion(idDiscussion) {
      const dernier = dernierParDiscussion.get(idDiscussion);
      if (dernier === undefined) return 0;
      return Math.max(0, dernier + parDiscussionMs - maintenant());
    },
    marquerEnvoi(idDiscussion) {
      const t = maintenant();
      dernierParDiscussion.set(idDiscussion, t);
      if (dernierParDiscussion.size > 5000) {
        for (const [k, v] of dernierParDiscussion) if (v + parDiscussionMs < t) dernierParDiscussion.delete(k);
      }
    },
  };
}
