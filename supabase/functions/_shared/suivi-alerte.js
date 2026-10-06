// Suivi public d'une alerte (SPEC 2 §9, §3 : page /alerte/:publicId). Renvoie l'état et le médicament demandé ;
// n'expose AUCUNE donnée patient (contact, empreintes, position) et AUCUNE donnée de pharmacie tant qu'aucune pharmacie n'a
// répondu « disponible ». Ensuite : nom, prix, quartier et téléphone des pharmacies (jamais d'identifiant interne).
const FORMAT_ID = /^NG-[0-9A-HJKMNP-TV-Z]{8}$/;
const LIBELLES = {
  new: 'Demande enregistrée', routing: 'Recherche en cours auprès des pharmacies', escalated: 'Recherche en cours, notre équipe suit votre demande',
  answered: 'Une pharmacie a confirmé la disponibilité', needs_review: 'Votre demande sera examinée par notre équipe avant toute transmission',
  fulfilled: 'Demande clôturée', expired: 'Aucune pharmacie n\'a confirmé pour le moment', cancelled: 'Demande annulée',
};

export async function traiterSuivi(idPublic, { magasin }) {
  if (typeof idPublic !== 'string' || !FORMAT_ID.test(idPublic)) return { status: 400, corps: { erreur: 'identifiant_invalide' } };
  const a = await magasin.lireSuivi(idPublic);
  if (!a) return { status: 404, corps: { erreur: 'introuvable' } };
  const corps = {
    id_public: a.id_public, statut: a.statut, libelle: LIBELLES[a.statut] || '', urgence: a.urgence,
    cree_le: a.cree_le, expire_le: a.expire_le,
    medicament: a.medicaments ? `${a.medicaments.nom}${a.medicaments.dosage ? ' ' + a.medicaments.dosage : ''}` : null,
    sur_ordonnance: a.medicaments ? a.medicaments.ordonnance === true : false,
    quartier: a.quartiers?.nom ?? null,
    garde_url: '/garde',
  };
  if (a.statut === 'answered' || a.statut === 'fulfilled') {
    if (magasin.pharmaciesDisponibles) corps.pharmacies = await magasin.pharmaciesDisponibles(a.id);
  }
  return { status: 200, corps };
}
