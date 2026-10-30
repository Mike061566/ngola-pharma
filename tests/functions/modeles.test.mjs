import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rendre, versAscii, echapperHtml } from '../../supabase/functions/_shared/modeles.js';
import { modeleDeRepli } from '../../supabase/functions/_shared/canaux.js';
import { ErreurModele } from '../../supabase/functions/_shared/erreurs.js';

const base = { drug: 'Ibuprofène 400mg', form: 'comprimé', quartier: 'Centre-Ville', heure: '10:05', code: 'ABC123', envoi_court: 'e1' };

test('alerte_demande Telegram : texte, boutons, callback_data ≤ 64 octets', () => {
  const r = rendre('alerte_demande', 'telegram', base);
  assert.match(r.texte, /<b>Ibuprofène 400mg<\/b> \(comprimé\)/);
  assert.match(r.texte, /Quartier : Centre-Ville/);
  assert.doesNotMatch(r.texte, /ordonnance/);
  assert.equal(r.boutons[0][0].donnees, 'r:e1:a');
  assert.equal(r.boutons[0][1].donnees, 'r:e1:u');
  assert.ok(Buffer.byteLength(r.boutons[0][0].donnees) <= 64);
  assert.equal(r.boutons[1][0].url, 'https://ngola-pharma.com/r/ABC123');
});

test('mention d\'ordonnance : présente pour la pharmacie et pour le patient quand requise, absente sinon', () => {
  assert.match(rendre('alerte_demande', 'telegram', { ...base, sur_ordonnance: true }).texte, /sur ordonnance : à présenter au comptoir/);
  assert.match(rendre('alerte_demande_email', 'email', { ...base, sur_ordonnance: true }).texte, /ordonnance/);
  const pat = { drug: 'X', heure: '10:00', pharmacies: [{ nom: 'P1', prix: 1500, quartier: 'Q', tel: '222' }] };
  assert.match(rendre('reponse_patient', 'telegram', { ...pat, sur_ordonnance: true }).texte, /présentez-la à la pharmacie/);
  assert.doesNotMatch(rendre('reponse_patient', 'telegram', pat).texte, /ordonnance/);
  assert.match(rendre('reponse_patient_sms', 'sms', { drug: 'X', pharmacie: 'P', quartier: 'Q', prix: 1500, tel: '222', sur_ordonnance: true }).texte, /Ordonnance a presenter sur place/);
});

test('les variables sont échappées en HTML (Telegram) : pas d\'injection de balises', () => {
  const r = rendre('alerte_demande', 'telegram', { ...base, drug: '<script>alert(1)</script> & co', quartier: 'A<B' });
  assert.doesNotMatch(r.texte, /<script>/);
  assert.match(r.texte, /&lt;script&gt;/);
  assert.match(r.texte, /A&lt;B/);
  assert.equal(echapperHtml('<&>'), '&lt;&amp;&gt;');
});

test('SMS : ≤ 160 caractères, ASCII pur, noms trop longs tronqués, lien sans schéma', () => {
  const court = rendre('alerte_demande_sms', 'sms', base).texte;
  assert.equal(court, 'NGola: demande patient Ibuprofene 400mg a Centre-Ville. Dispo? Repondez: ngola-pharma.com/r/ABC123');
  const long = rendre('alerte_demande_sms', 'sms', { ...base, drug: 'Médicament à très long nom '.repeat(10), quartier: 'Quartier très très long '.repeat(5) }).texte;
  assert.ok(long.length <= 160, `longueur ${long.length}`);
  assert.match(long, /^[\x20-\x7e]+$/);
  assert.match(long, /ngola-pharma\.com\/r\/ABC123$/);
});

test('versAscii : accents, ligatures, guillemets typographiques, emojis', () => {
  assert.equal(versAscii('Élève à Ngoa-Ekellé — œuvre ’ok’ 📋'), "Eleve a Ngoa-Ekelle - oeuvre 'ok'");
});

test('réponse patient Telegram : jusqu\'à 3 pharmacies, prix groupés, heure de confirmation', () => {
  const ph = (n) => ({ nom: `Pharmacie ${n}`, prix: 12500, quartier: 'Bastos', tel: '222 00 00 0' + n });
  const r = rendre('reponse_patient', 'telegram', { drug: 'Coartem', heure: '10:10', pharmacies: [ph(1), ph(2), ph(3), ph(4)] });
  assert.match(r.texte, /1\) Pharmacie 1 — 12 500 FCFA — Bastos — Tél 222 00 00 01/);
  assert.doesNotMatch(r.texte, /4\)/);
  assert.match(r.texte, /confirmés par les pharmacies à 10:10/);
});

test('aucun modèle ne laisse passer de variable manquante ni de modèle/canal inconnu', () => {
  assert.throws(() => rendre('alerte_demande', 'telegram', { drug: 'X' }), ErreurModele);
  assert.throws(() => rendre('inconnu', 'telegram', {}), ErreurModele);
  assert.throws(() => rendre('alerte_demande', 'sms', base), ErreurModele);
  assert.throws(() => rendre('reponse_patient', 'telegram', { drug: 'X', heure: '1', pharmacies: [] }), ErreurModele);
});

test('messages restreints : texte de la spec, aucun conseil, SMS en ASCII', () => {
  assert.match(rendre('restricted_attente', 'telegram', {}).texte, /sera examinée par notre équipe/);
  assert.match(rendre('restricted_refus', 'sms', {}).texte, /^[\x20-\x7e]+$/);
  assert.match(rendre('expiration_patient', 'sms', { drug: 'X' }).texte, /ngola-pharma\.com\/garde/);
});

test('repli de modèle : alerte_demande -> sms -> email ; reponse_patient sans email ; modèle unique multi-canal', () => {
  assert.equal(modeleDeRepli('alerte_demande', 'sms'), 'alerte_demande_sms');
  assert.equal(modeleDeRepli('alerte_demande_sms', 'email'), 'alerte_demande_email');
  assert.equal(modeleDeRepli('reponse_patient', 'email'), null);
  assert.equal(modeleDeRepli('attente_patient', 'sms'), 'attente_patient');
  assert.equal(modeleDeRepli('telegram_activation', 'sms'), null);
});
