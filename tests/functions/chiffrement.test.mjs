import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cleDepuisBase64, chiffrer, dechiffrer, versBytea, depuisBytea } from '../../supabase/functions/_shared/chiffrement.js';
import { egalConstante } from '../../supabase/functions/_shared/securite.js';
import { cleTest } from './aide.mjs';

test('chiffrement : aller-retour, IV aléatoire, rien de lisible dans le texte chiffré', async () => {
  const cle = await cleTest();
  const a = await chiffrer(cle, '+237600000001');
  const b = await chiffrer(cle, '+237600000001');
  assert.notDeepEqual(a, b);
  assert.equal(await dechiffrer(cle, a), '+237600000001');
  assert.equal(Buffer.from(a).toString('latin1').includes('237600'), false);
});

test('chiffrement : donnée altérée ou autre clé refusées', async () => {
  const cle = await cleTest();
  const autre = await cleDepuisBase64(Buffer.from(new Uint8Array(32).fill(9)).toString('base64'));
  const c = await chiffrer(cle, 'secret');
  await assert.rejects(dechiffrer(autre, c));
  const alteree = Uint8Array.from(c); alteree[alteree.length - 1] ^= 1;
  await assert.rejects(dechiffrer(cle, alteree));
  await assert.rejects(dechiffrer(cle, new Uint8Array(5)));
});

test('clé : longueur et présence vérifiées', async () => {
  await assert.rejects(cleDepuisBase64(''));
  await assert.rejects(cleDepuisBase64(Buffer.from('court').toString('base64')));
});

test('bytea : aller-retour hexadécimal, entrée invalide refusée', () => {
  const o = Uint8Array.from([0, 1, 254, 255]);
  assert.equal(versBytea(o), '\\x0001feff');
  assert.deepEqual(depuisBytea('\\x0001feff'), o);
  assert.throws(() => depuisBytea('0001'));
  assert.throws(() => depuisBytea('\\xzz'));
});

test('egalConstante : secrets égaux, différents, vides', async () => {
  assert.equal(await egalConstante('abc', 'abc'), true);
  assert.equal(await egalConstante('abc', 'abd'), false);
  assert.equal(await egalConstante('abc', 'abcd'), false);
  assert.equal(await egalConstante('', ''), false);
  assert.equal(await egalConstante(undefined, 'x'), false);
});
