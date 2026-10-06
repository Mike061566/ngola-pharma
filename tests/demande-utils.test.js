const U = require('../public/demande-utils');

const base = () => ({
  nom_pharmacie: 'Pharmacie Test', quartier_id: 'q1', adresse: 'Rue 1', telephone_fixe: '222 23 45 67', telephone_mobile: '699 12 34 56',
  nom_titulaire: 'Dr Test', numero_ordre: 'ORD-1', email_titulaire: 'a@b.test', grille: U.horairesParDefaut(),
  consentement_conditions: true, consentement_messages: true, participe_garde: false
});

describe('validerFormulaire', () => {
  test('formulaire complet : valide', () => { expect(U.validerFormulaire(base())).toEqual({ ok: true, erreurs: {} }); });
  test('champs obligatoires', () => {
    const r = U.validerFormulaire({ ...base(), nom_pharmacie: '', quartier_id: '', email_titulaire: 'x', numero_ordre: '', consentement_messages: false });
    expect(Object.keys(r.erreurs).sort()).toEqual(['consentements', 'email_titulaire', 'nom_pharmacie', 'numero_ordre', 'quartier_id']);
  });
  test('le mobile doit commencer par 6 ; le fixe accepte 2 ou 3', () => {
    expect(U.validerFormulaire({ ...base(), telephone_mobile: '222 23 45 67' }).erreurs.telephone_mobile).toBeDefined();
    expect(U.validerFormulaire({ ...base(), telephone_fixe: '699 12 34 56' }).ok).toBe(true);
  });
  test('horaires : au moins un jour ouvert, ouverture avant fermeture', () => {
    const g = U.horairesParDefaut();
    Object.keys(g).forEach((j) => { g[j].ferme = true; });
    expect(U.validerFormulaire({ ...base(), grille: g }).erreurs.horaires).toBeDefined();
    const g2 = U.horairesParDefaut(); g2.lun = { ferme: false, ouv: '20:00', fer: '08:00' };
    expect(U.validerFormulaire({ ...base(), grille: g2 }).erreurs.horaires).toBeDefined();
  });
});

test('construireHoraires omet les jours fermés', () => {
  const h = U.construireHoraires(U.horairesParDefaut());
  expect(Object.keys(h)).toEqual(['lun', 'mar', 'mer', 'jeu', 'ven', 'sam']);
  expect(h.lun).toEqual({ ouv: '08:00', fer: '20:00' });
});

test('erreurFichier : taille, vide, type', () => {
  expect(U.erreurFichier({ size: 1000, type: 'application/pdf' })).toBeNull();
  expect(U.erreurFichier({ size: 6 * 1024 * 1024, type: 'application/pdf' })).toMatch(/volumineux/);
  expect(U.erreurFichier({ size: 0, type: 'image/png' })).toMatch(/vide/);
  expect(U.erreurFichier({ size: 10, type: 'application/zip' })).toMatch(/Format/);
  expect(U.erreurFichier(null)).toBeNull();
});

test('construireDonnees : position facultative, consentements vrais, aucune clé hors liste', () => {
  const d = U.construireDonnees({ ...base(), latitude: 3.86, longitude: 11.5 }, 'mock-ok');
  expect(d.latitude).toBe(3.86);
  expect(d.captcha).toBe('mock-ok');
  expect(Object.keys(U.construireDonnees(base(), 'x'))).not.toContain('latitude');
  expect(Object.keys(d).join()).not.toMatch(/ordonnance|prescription/);
});

test('jetonDuFragment : seulement #t=<jeton> bien formé', () => {
  expect(U.jetonDuFragment('#t=abcdefghijklmnop1234')).toBe('abcdefghijklmnop1234');
  expect(U.jetonDuFragment('#t=court')).toBeNull();
  expect(U.jetonDuFragment('#x=abcdefghijklmnop1234')).toBeNull();
  expect(U.jetonDuFragment('')).toBeNull();
});

test('messageErreur : connu et repli générique', () => {
  expect(U.messageErreur('document_manquant')).toMatch(/attestation/);
  expect(U.messageErreur('???')).toMatch(/Réessayez/);
});
