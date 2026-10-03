const U = require('../public/admin-utils');

describe('formats', () => {
  test.each([[null, '—'], [undefined, '—'], ['x', '—'], [45, '45 s'], [60, '1 min'], [330, '5 min 30 s'], [3600, '1 h'], [5400, '1 h 30 min']])('formaterDuree(%s)', (a, b) => {
    expect(U.formaterDuree(a)).toBe(b);
  });
  test.each([[null, '—'], [0.5, '50 %'], [1, '100 %'], [0.3333, '33.3 %'], [0, '0 %']])('pourcentage(%s)', (a, b) => {
    expect(U.pourcentage(a)).toBe(b);
  });
  test('libellés : statuts, raisons, refus ; valeur inconnue renvoyée telle quelle', () => {
    expect(U.libelleStatut('needs_review')).toBe('À examiner');
    expect(U.libelleStatut('autre')).toBe('autre');
    expect(U.libelleRaison('restreint')).toBe('Médicament restreint');
    expect(U.libelleRefus('aucun_contact_actif')).toBe('aucun contact actif');
  });
});

describe('actionsPossibles (miroir des règles SQL)', () => {
  test('alerte en revue : rattacher, refuser, transmettre ; pas de relance ni de clôture', () => {
    const a = U.actionsPossibles({ statut: 'needs_review' });
    expect(a).toMatchObject({ rattacher: true, refuser: true, transmettre: true, relancer: false, cloturer: false, annuler: true, bloquer: true });
  });
  test('alerte en recherche : relancer seulement hors routage manuel et sans réponse positive', () => {
    expect(U.actionsPossibles({ statut: 'routing' }).relancer).toBe(true);
    expect(U.actionsPossibles({ statut: 'routing', routage_manuel: true }).relancer).toBe(false);
    expect(U.actionsPossibles({ statut: 'escalated', nb_positives: 1 }).relancer).toBe(false);
    expect(U.actionsPossibles({ statut: 'routing' })).toMatchObject({ rattacher: false, refuser: false, cloturer: true });
  });
  test('alerte répondue : clôturable, plus de relance', () => {
    expect(U.actionsPossibles({ statut: 'answered', nb_positives: 1 })).toMatchObject({ cloturer: true, relancer: false, transmettre: true });
  });
  test('alerte terminée : plus aucune action sauf bloquer le patient', () => {
    for (const s of ['fulfilled', 'expired', 'cancelled']) {
      const a = U.actionsPossibles({ statut: s });
      expect(Object.keys(a).filter((k) => a[k])).toEqual(['bloquer']);
    }
  });
  test('transmettre exige un médicament rattaché', () => {
    expect(U.actionsPossibles({ statut: 'needs_review', avec_medicament: false }).transmettre).toBe(false);
  });
});

describe('chronologie', () => {
  test('libellés d\'événements, sans donnée personnelle', () => {
    expect(U.libelleEvenement({ type: 'creation', urgence: 'urgent' })).toBe('Demande créée (urgente)');
    expect(U.libelleEvenement({ type: 'envoi', pharmacie: 'Pharmacie 1', vague: 1, score: 80, detail_score: {} })).toBe('Envoyée à Pharmacie 1 (vague 1, score 80)');
    expect(U.libelleEvenement({ type: 'envoi', pharmacie: 'P', vague: 1, score: 0, detail_score: { manuel: true } })).toMatch(/transmission manuelle/);
    expect(U.libelleEvenement({ type: 'reponse', pharmacie: 'P', reponse: 'available', prix_fcfa: 1500, canal: 'telegram' })).toBe('P : Disponible (1500 FCFA) via telegram');
    expect(U.libelleEvenement({ type: 'reponse', pharmacie: 'P', reponse: 'unavailable', canal: 'link' })).toBe('P : Indisponible via link');
    expect(U.libelleEvenement({ type: 'message', canal: 'sms', modele: 'alerte_demande_sms', statut: 'failed', erreur: 'contact_bloque' })).toBe('Message sms (alerte_demande_sms) : failed — contact_bloque');
    expect(U.libelleEvenement({ type: 'message', canal: 'telegram', modele: 'alerte_demande', statut: 'suppressed_demo' })).toMatch(/aurait été envoyé \(mode démo/);
    expect(U.libelleEvenement({ type: 'action_admin', action: 'annuler' })).toBe('Action admin : annuler');
    expect(U.libelleEvenement({ type: 'inconnu' })).toBe('inconnu');
  });
});

describe('réglages', () => {
  test('analyserValeurConfig : JSON valide ou message', () => {
    expect(U.analyserValeurConfig('3')).toEqual({ ok: true, valeur: 3 });
    expect(U.analyserValeurConfig(' 0.5 ')).toEqual({ ok: true, valeur: 0.5 });
    expect(U.analyserValeurConfig('[30, 120, 300]')).toEqual({ ok: true, valeur: [30, 120, 300] });
    expect(U.analyserValeurConfig('true')).toEqual({ ok: true, valeur: true });
    expect(U.analyserValeurConfig('{"a":1}').valeur).toEqual({ a: 1 });
    for (const mauvais of ['', '   ', 'trois', '{a:1}', '[1,', null]) expect(U.analyserValeurConfig(mauvais).ok).toBe(false);
  });
  test('reglagesAffichables : mode_application exclu (verrou de production), tri par clé', () => {
    const l = U.reglagesAffichables([{ cle: 'b' }, { cle: 'mode_application' }, { cle: 'a' }]);
    expect(l.map((x) => x.cle)).toEqual(['a', 'b']);
    expect(U.reglagesAffichables(null)).toEqual([]);
  });
  test('niveauBudget', () => {
    expect(U.niveauBudget(null)).toBe('ok');
    expect(U.niveauBudget({ alerte_80: false, depasse: false })).toBe('ok');
    expect(U.niveauBudget({ alerte_80: true, depasse: false })).toBe('alerte');
    expect(U.niveauBudget({ alerte_80: true, depasse: true })).toBe('depasse');
  });
});

describe('remise à zéro de la démo', () => {
  test('résumé lisible, avec les points à traiter', () => {
    expect(U.resumeReinitialisation(null)).toBe('');
    const r = { alertes_supprimees: 3, messages_supprimes: 7, stocks: 24, pharmacies_scenario: ['a', 'b'], avertissements: [] };
    expect(U.resumeReinitialisation(r)).toBe('3 alerte(s) et 7 message(s) supprimés, 24 stocks rétablis. Pharmacies : a, b.');
    expect(U.resumeReinitialisation({ ...r, avertissements: ['aucun_compte_de_test : ajoutez les comptes'] })).toMatch(/À traiter : aucun compte de test\./);
  });
});
