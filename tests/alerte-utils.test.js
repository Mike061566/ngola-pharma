const U = require('../public/alerte-utils');

describe('validerFormulaire', () => {
  const base = { medicament_id: 'm1', quartier_id: 'q1', urgence: 'normal', canal: 'telegram', telephone: '', consentement: false };

  test('formulaire complet (Telegram) : valide', () => {
    expect(U.validerFormulaire(base)).toEqual({ ok: true, erreurs: {} });
  });
  test('médicament et quartier obligatoires', () => {
    const r = U.validerFormulaire({ ...base, medicament_id: null, quartier_id: '' });
    expect(r.ok).toBe(false);
    expect(Object.keys(r.erreurs).sort()).toEqual(['medicament', 'quartier']);
  });
  test('SMS : numéro valide et consentement obligatoires', () => {
    const sms = { ...base, canal: 'sms' };
    expect(Object.keys(U.validerFormulaire(sms).erreurs).sort()).toEqual(['consentement', 'telephone']);
    expect(U.validerFormulaire({ ...sms, telephone: '699 12 34 56', consentement: true }).ok).toBe(true);
    expect(U.validerFormulaire({ ...sms, telephone: '699 12 34 56', consentement: false }).erreurs.consentement).toMatch(/consentement/);
  });
  test('le numéro n\'est pas exigé hors SMS', () => {
    expect(U.validerFormulaire({ ...base, canal: 'none', telephone: 'n importe quoi' }).ok).toBe(true);
  });
});

describe('construireCorps', () => {
  test('liste blanche : aucun champ d\'ordonnance, numéro seulement pour le SMS', () => {
    const v = { medicament_id: 'm1', quartier_id: 'q1', urgence: 'urgent', canal: 'telegram', telephone: '699123456', consentement: true, ordonnance: 'x', photo: 'y' };
    expect(U.construireCorps(v, 'jeton')).toEqual({ medicament_id: 'm1', quartier_id: 'q1', urgence: 'urgent', canal: 'telegram', captcha: 'jeton' });
    expect(U.construireCorps({ ...v, canal: 'sms' }, 'jeton')).toEqual({ medicament_id: 'm1', quartier_id: 'q1', urgence: 'urgent', canal: 'sms',
      telephone: '699123456', consentement: true, captcha: 'jeton' });
  });
  test('valeurs inattendues ramenées aux valeurs sûres', () => {
    const c = U.construireCorps({ medicament_id: 'm', quartier_id: 'q', urgence: 'critique', canal: 'whatsapp' }, 'j');
    expect(c.urgence).toBe('normal');
    expect(c.canal).toBe('none');
  });
});

describe('normaliserTelephone', () => {
  test.each([['699123456', '+237699123456'], ['+237 699 12 34 56', '+237699123456'], ['00237699123456', '+237699123456'], ['6.99.12.34.56', '+237699123456']])('%s', (a, b) => {
    expect(U.normaliserTelephone(a)).toBe(b);
  });
  test.each(['', '12345', '+33612345678', '799123456', null])('refusé : %s', (a) => {
    expect(U.normaliserTelephone(a)).toBeNull();
  });
});

describe('divers', () => {
  test('idDepuisChemin : seulement le format NG-XXXXXXXX', () => {
    expect(U.idDepuisChemin('/alerte/NG-ABCDEFGH')).toBe('NG-ABCDEFGH');
    expect(U.idDepuisChemin('/alerte/NG-ABCDEFGH/')).toBe('NG-ABCDEFGH');
    expect(U.idDepuisChemin('/alerte/NG-ABCDEFGI')).toBeNull();       // I exclu (alphabet Crockford)
    expect(U.idDepuisChemin('/alerte/../etc/passwd')).toBeNull();
    expect(U.idDepuisChemin('/alerte/NG-abcdefgh')).toBeNull();
    expect(U.idDepuisChemin('/')).toBeNull();
  });
  test('echapper neutralise le HTML', () => {
    expect(U.echapper('<img src=x onerror=alert(1)>"\'&')).toBe('&lt;img src=x onerror=alert(1)&gt;&quot;&#39;&amp;');
    expect(U.echapper(null)).toBe('');
  });
  test('termeRecherche : jokers et séparateurs retirés, longueur bornée', () => {
    expect(U.termeRecherche('ibu%profène_400,(x)*')).toBe('ibu profène 400 x');
    expect(U.termeRecherche('a'.repeat(100)).length).toBe(60);
    expect(U.termeRecherche(undefined)).toBe('');
  });
  test('messages d\'erreur en français ; code inconnu = message générique', () => {
    expect(U.messageErreur('limite_quotidienne')).toMatch(/Trop de demandes/);
    expect(U.messageErreur('ordonnance_interdite')).toMatch(/Aucune ordonnance/);
    expect(U.messageErreur('???')).toMatch(/Une erreur est survenue/);
  });
  test('statuts : libellés et fin de suivi', () => {
    expect(U.libelleStatut('needs_review')).toMatch(/examinée par notre équipe/);
    expect(U.libelleStatut('inconnu')).toBe('');
    ['fulfilled', 'expired', 'cancelled'].forEach((s) => expect(U.suiviTermine(s)).toBe(true));
    ['new', 'routing', 'escalated', 'answered', 'needs_review'].forEach((s) => expect(U.suiviTermine(s)).toBe(false));
  });
});
