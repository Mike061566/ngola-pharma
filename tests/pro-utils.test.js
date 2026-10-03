const { formatHoraires, statutInfo, medIdentityKey, findOwnedStock, mapLinks } = require('../public/pro-utils');

const jour = (ouv, fer) => ({ ouv, fer });

describe('formatHoraires', () => {
  test('objet JSON -> texte lisible, jamais [object Object]', () => {
    const h = { lun: jour('08:00', '20:00'), mar: jour('08:00', '20:00'), mer: jour('08:00', '20:00'),
      jeu: jour('08:00', '20:00'), ven: jour('08:00', '20:00'), sam: jour('08:00', '20:00') };
    expect(formatHoraires(h)).toBe('Lun–Sam 08:00–20:00 · Dim Fermé');
    expect(formatHoraires(h)).not.toMatch(/object/i);
  });

  test('regroupe les jours consécutifs identiques et sépare les horaires différents', () => {
    const h = { lun: jour('08:00', '20:00'), mar: jour('08:00', '20:00'), mer: jour('09:00', '18:00'),
      jeu: jour('08:00', '20:00'), ven: jour('08:00', '20:00'), sam: jour('08:00', '13:00'), dim: jour('08:00', '13:00') };
    expect(formatHoraires(h)).toBe('Lun–Mar 08:00–20:00 · Mer 09:00–18:00 · Jeu–Ven 08:00–20:00 · Sam–Dim 08:00–13:00');
  });

  test('7j/7 identiques', () => {
    const h = {};
    ['lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim'].forEach((j) => { h[j] = jour('00:00', '23:59'); });
    expect(formatHoraires(h)).toBe('Lun–Dim 00:00–23:59');
  });

  test('vide, absent ou illisible -> Non renseignés', () => {
    [undefined, null, {}, '{}', '', [], 42, { lun: {} }, { lun: jour('', '') }].forEach((h) => {
      expect(formatHoraires(h)).toBe('Non renseignés');
    });
  });

  test('JSON reçu sous forme de texte et texte libre historique', () => {
    expect(formatHoraires('{"lun":{"ouv":"08:00","fer":"20:00"}}')).toBe('Lun 08:00–20:00 · Mar–Dim Fermé');
    expect(formatHoraires('24h/24')).toBe('24h/24');
    expect(formatHoraires('{pas du json')).toBe('{pas du json');
  });
});

describe('statutInfo', () => {
  test('libellés français et badges', () => {
    expect(statutInfo('non_verifie')).toEqual({ label: 'Non vérifiée', css: 'badge-unverified' });
    expect(statutInfo('verifie').label).toBe('✓ Vérifiée');
    expect(statutInfo('partenaire').css).toBe('badge-partner');
    expect(statutInfo('suspendu').label).toBe('Suspendue');
  });
  test('valeur inconnue ou absente : jamais de valeur brute vide', () => {
    expect(statutInfo('autre').label).toBe('autre');
    expect(statutInfo(null).label).toBe('—');
  });
});

describe('doublons de médicament', () => {
  const coartem1 = { id: 'm1', nom: 'Coartem', nom_commercial: 'Coartem', dci: 'Artemether-Lumefantrine', dosage: '20/120mg', forme: 'Comprimé' };
  const coartem2 = { id: 'm2', nom: 'Artemether-Lumefantrine', nom_commercial: 'Coartem', dci: 'artemether-lumefantrine ', dosage: '20/120 mg', forme: 'comprimé' };
  const doliprane = { id: 'm3', nom: 'Doliprane', nom_commercial: 'Doliprane', dci: 'Paracétamol', dosage: '500mg', forme: 'Comprimé' };
  const efferalgan = { id: 'm4', nom: 'Efferalgan', nom_commercial: 'Efferalgan', dci: 'Paracétamol', dosage: '500mg', forme: 'Comprimé' };
  const stocks = [{ id: 's1', medicament_id: 'm1', medicaments: coartem1 }, { id: 's3', medicament_id: 'm3', medicaments: doliprane }];

  test('deux fiches du même produit ont la même clé ; deux marques différentes non', () => {
    expect(medIdentityKey(coartem1)).toBe(medIdentityKey(coartem2));
    expect(medIdentityKey(doliprane)).not.toBe(medIdentityKey(efferalgan));
  });

  test('même fiche ou fiche équivalente : déjà dans le stock', () => {
    expect(findOwnedStock(stocks, coartem1).id).toBe('s1');
    expect(findOwnedStock(stocks, coartem2).id).toBe('s1');
  });

  test('autre marque du même principe actif : autorisée', () => {
    expect(findOwnedStock(stocks, efferalgan)).toBeNull();
  });

  test('médicament inconnu ou sans détail : recherche par identifiant seulement', () => {
    expect(findOwnedStock(stocks, { id: 'm3' }).id).toBe('s3');
    expect(findOwnedStock(stocks, { id: 'zzz' })).toBeNull();
    expect(findOwnedStock(stocks, null)).toBeNull();
  });
});

describe('mapLinks', () => {
  test('liens pour une position valide (nombres ou chaînes)', () => {
    const l = mapLinks('3.8667', 11.5167);
    expect(l.google).toBe('https://www.google.com/maps/search/?api=1&query=3.8667,11.5167');
    expect(l.embed).toContain('marker=3.8667,11.5167');
  });
  test('position absente, invalide ou injectée : aucun lien', () => {
    [[null, null], [undefined, 11], ['abc', '11'], [95, 11], [3, 200], ['3"><script>', 11]].forEach(([a, b]) => {
      expect(mapLinks(a, b)).toBeNull();
    });
  });
});
