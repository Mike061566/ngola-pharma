import { test } from 'node:test';
import assert from 'node:assert/strict';
import { creerMagasinSupabase } from '../../supabase/functions/_shared/magasin-supabase.js';

// Faux client : enregistre la chaîne d'appels et renvoie le résultat programmé.
function faux(resultat = { data: [], error: null }) {
  const appels = [];
  const chaine = (table) => {
    const etape = { table, appels: [] };
    const p = new Proxy({}, { get: (_t, prop) => {
      if (prop === 'then') return (res) => res(resultat);
      return (...a) => { etape.appels.push([prop, a]); return p; };
    } });
    appels.push(etape);
    return p;
  };
  return { appels, sb: { from: chaine, rpc: (nom, args) => { appels.push({ rpc: nom, args }); return Promise.resolve(resultat); } } };
}

test('reclamer : appelle la fonction SQL SKIP LOCKED avec limite et bail', async () => {
  const f = faux({ data: [{ id: 'x' }], error: null });
  assert.deepEqual(await creerMagasinSupabase(f.sb).reclamer(20, 120), [{ id: 'x' }]);
  assert.deepEqual(f.appels[0], { rpc: 'reclamer_notifications', args: { p_limite: 20, p_bail_s: 120 } });
});

test('enfiler : upsert avec ignoreDuplicates sur cle_idempotence ; true seulement si une ligne est créée', async () => {
  let f = faux({ data: [{ id: 'n' }], error: null });
  assert.equal(await creerMagasinSupabase(f.sb).enfiler({ cle_idempotence: 'k' }), true);
  const [nom, args] = f.appels[0].appels[0];
  assert.equal(nom, 'upsert');
  assert.deepEqual(args[1], { onConflict: 'cle_idempotence', ignoreDuplicates: true });
  f = faux({ data: [], error: null });
  assert.equal(await creerMagasinSupabase(f.sb).enfiler({ cle_idempotence: 'k' }), false);
});

test('reporter : remet en file ; restaure `tentatives` seulement si demandé', async () => {
  let f = faux();
  await creerMagasinSupabase(f.sb).reporter('o1', new Date('2026-10-05T10:00:30Z'), { erreur: 'x', tentatives: 0 });
  assert.deepEqual(f.appels[0].appels[0][1][0], { statut: 'queued', prochaine_tentative_le: '2026-10-05T10:00:30.000Z', derniere_erreur: 'x', tentatives: 0 });
  f = faux();
  await creerMagasinSupabase(f.sb).reporter('o1', new Date('2026-10-05T10:00:30Z'));
  assert.equal('tentatives' in f.appels[0].appels[0][1][0], false);
});

test('une erreur de base lève une erreur sans exposer de données', async () => {
  const f = faux({ data: null, error: { code: '42501', message: 'détail sensible' } });
  await assert.rejects(creerMagasinSupabase(f.sb).lireConfig(), (e) => /42501/.test(e.message) && !/sensible/.test(e.message));
});

test('lireConfig : tableau de lignes -> objet { cle: valeur }', async () => {
  const f = faux({ data: [{ cle: 'a', valeur: 1 }, { cle: 'b', valeur: 'x' }], error: null });
  assert.deepEqual(await creerMagasinSupabase(f.sb).lireConfig(), { a: 1, b: 'x' });
});
