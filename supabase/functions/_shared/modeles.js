// Modèles de messages (SPEC 2 §7). Fonctions pures : (variables) -> { texte, sujet?, boutons?, format }.
// Règles : variables échappées en HTML pour Telegram ; SMS sans accents ni emojis ; aucune donnée personnelle du
// patient ; aucun conseil médical ; aucune ordonnance demandée ou acceptée (simple mention « à présenter sur place »).
import { ErreurModele } from './erreurs.js';

const BASE_URL_DEFAUT = 'https://ngola-pharma.com';

export function echapperHtml(s) {
  return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/** Texte compatible SMS GSM 7 bits : accents retirés, ligatures et ponctuation typographique remplacées. */
export function versAscii(s) {
  return String(s ?? '')
    .replace(/œ/g, 'oe').replace(/Œ/g, 'OE').replace(/æ/g, 'ae').replace(/Æ/g, 'AE')
    .replace(/[’‘`]/g, "'").replace(/[“”«»]/g, '"').replace(/[–—]/g, '-').replace(/…/g, '...')
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^\x20-\x7e\n]/g, '')
    .replace(/[ \t]+/g, ' ').trim();
}

function exiger(vars, champs) {
  const manquants = champs.filter((c) => vars == null || vars[c] === undefined || vars[c] === null || vars[c] === '');
  if (manquants.length) throw new ErreurModele('Variables manquantes : ' + manquants.join(', '));
}

const lienSansSchema = (vars, chemin) => {
  const base = String(vars.base_url || BASE_URL_DEFAUT).replace(/^https?:\/\//, '').replace(/\/+$/, '');
  return `${base}${chemin}`;
};
const lienAvecSchema = (vars, chemin) => `https://${lienSansSchema(vars, chemin)}`;
const prix = (n) => String(Math.round(Number(n))).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');

const LIGNE_ORDO_PHARMACIE = '📋 Médicament sur ordonnance : à présenter au comptoir lors de l\'achat ou du retrait.';
const LIGNE_ORDO_PATIENT = '📋 Ce médicament est délivré sur ordonnance : présentez-la à la pharmacie lors de l\'achat ou du retrait.';

/** Raccourcit sans casser : au plus `max` caractères, terminé par un point si coupé. */
function couper(s, max) {
  const t = String(s ?? '');
  return t.length <= max ? t : t.slice(0, Math.max(0, max - 1)) + '.';
}

function smsDemande(vars) {
  exiger(vars, ['drug', 'quartier', 'code']);
  const lien = lienSansSchema(vars, `/r/${encodeURIComponent(vars.code)}`);
  const construire = (d, q) => `NGola: demande patient ${d} a ${q}. Dispo? Repondez: ${lien}`;
  let drug = versAscii(vars.drug), quartier = versAscii(vars.quartier);
  if (construire(drug, quartier).length > 160) {
    if (construire('', quartier).length > 150) quartier = couper(quartier, 15);
    const place = 160 - construire('', quartier).length;
    drug = couper(drug, Math.max(place, 4));
  }
  return { texte: construire(drug, quartier), format: 'texte' };
}

export const MODELES = {
  // ── Vers les pharmacies ──
  alerte_demande: {
    canaux: {
      telegram: (v) => {
        exiger(v, ['drug', 'quartier', 'heure', 'code', 'envoi_court']);
        const lignes = [
          '🔔 <b>N\'Gola Pharma — Demande d\'un patient</b>',
          `Médicament : <b>${echapperHtml(v.drug)}</b>${v.form ? ` (${echapperHtml(v.form)})` : ''}`,
          `Quartier : ${echapperHtml(v.quartier)}`,
          `Reçue à ${echapperHtml(v.heure)}`,
        ];
        if (v.sur_ordonnance) lignes.push(LIGNE_ORDO_PHARMACIE);
        lignes.push('Avez-vous ce médicament en stock maintenant ?');
        return {
          format: 'html',
          texte: lignes.join('\n'),
          // callback_data : r:<envoi_court>:a|u, 64 octets au plus (limite Telegram)
          boutons: [
            [{ texte: '✅ Disponible', donnees: `r:${v.envoi_court}:a` }, { texte: '❌ Indisponible', donnees: `r:${v.envoi_court}:u` }],
            [{ texte: '💰 Préciser le prix', url: lienAvecSchema(v, `/r/${encodeURIComponent(v.code)}`) }],
          ],
        };
      },
    },
  },
  alerte_demande_sms: { canaux: { sms: smsDemande } },
  alerte_demande_email: {
    canaux: {
      email: (v) => {
        exiger(v, ['drug', 'quartier', 'heure', 'code']);
        const lien = lienAvecSchema(v, `/r/${encodeURIComponent(v.code)}`);
        const corps = [
          'Bonjour,',
          `un patient recherche ${v.drug} dans le quartier ${v.quartier} (demande reçue à ${v.heure}).`,
          v.sur_ordonnance ? 'Médicament sur ordonnance : à présenter au comptoir lors de l\'achat ou du retrait.' : null,
          `Merci de confirmer la disponibilité (Disponible / Indisponible) : ${lien}`,
          'Ces boutons mettent aussi à jour vos stocks.',
          v.lien_desabonnement ? `Ne plus recevoir ces demandes : ${v.lien_desabonnement}` : null,
        ].filter(Boolean).join('\n\n');
        return { format: 'texte', sujet: `Demande patient : ${v.drug} à ${v.quartier}`, texte: corps };
      },
    },
  },
  telegram_activation: {
    canaux: {
      telegram: (v) => {
        exiger(v, ['nom', 'pharmacie']);
        return { format: 'html', texte: `Bienvenue sur N'Gola Pharma, ${echapperHtml(v.nom)} 👋\n` +
          `Ce compte Telegram recevra les demandes de patients pour ${echapperHtml(v.pharmacie)}.\n` +
          'Envoyez /stop à tout moment pour ne plus les recevoir.' };
      },
    },
  },
  rappel_confirmation_stock: {
    canaux: {
      telegram: (v) => {
        exiger(v, ['nom', 'jours', 'token']);
        return { format: 'html',
          texte: `Bonjour ${echapperHtml(v.nom)}, vos stocks N'Gola Pharma datent de ${echapperHtml(v.jours)} jours.\nConfirmez-les en un clic.`,
          boutons: [[{ texte: 'Confirmer mes stocks', url: lienAvecSchema(v, `/c/${encodeURIComponent(v.token)}`) }]] };
      },
    },
  },
  // ── Vers le patient (une seule clé, rendu adapté au canal choisi par le patient) ──
  reponse_patient: {
    canaux: {
      telegram: (v) => {
        exiger(v, ['drug', 'heure']);
        const liste = Array.isArray(v.pharmacies) ? v.pharmacies.slice(0, 3) : [];
        if (liste.length === 0) throw new ErreurModele('Variables manquantes : pharmacies');
        const lignes = liste.map((p, i) => {
          exiger(p, ['nom', 'prix', 'quartier', 'tel']);
          return `${i + 1}) ${echapperHtml(p.nom)} — ${prix(p.prix)} FCFA — ${echapperHtml(p.quartier)} — Tél ${echapperHtml(p.tel)}`;
        });
        const sortie = [`✅ <b>${echapperHtml(v.drug)}</b> est disponible :`, ...lignes,
          `Prix confirmés par les pharmacies à ${echapperHtml(v.heure)}. Appelez avant de vous déplacer.`];
        if (v.sur_ordonnance) sortie.push(LIGNE_ORDO_PATIENT);
        return { format: 'html', texte: sortie.join('\n') };
      },
    },
  },
  reponse_patient_sms: {
    canaux: {
      sms: (v) => {
        exiger(v, ['drug', 'pharmacie', 'quartier', 'prix', 'tel']);
        const ordo = v.sur_ordonnance ? 'Ordonnance a presenter sur place. ' : '';
        return { format: 'texte', texte: versAscii(`NGola: ${v.drug} dispo chez ${v.pharmacie} (${v.quartier}) env. ${prix(v.prix)} FCFA. Tel ${v.tel}. ${ordo}Appelez avant de vous deplacer.`) };
      },
    },
  },
  attente_patient: {
    canaux: {
      telegram: (v) => { exiger(v, ['drug']); return { format: 'html', texte: `Nous cherchons encore ${echapperHtml(v.drug)} près de vous. Nous revenons vers vous dès qu'une pharmacie confirme.` }; },
      sms: (v) => { exiger(v, ['drug']); return { format: 'texte', texte: versAscii(`NGola: nous cherchons encore ${v.drug} pres de vous. Nous revenons vers vous des qu'une pharmacie confirme.`) }; },
    },
  },
  expiration_patient: {
    canaux: {
      telegram: (v) => { exiger(v, ['drug']); return { format: 'html', texte: `Aucune pharmacie n'a confirmé ${echapperHtml(v.drug)} pour le moment. Pharmacies de garde : ${lienSansSchema(v, '/garde')}` }; },
      sms: (v) => { exiger(v, ['drug']); return { format: 'texte', texte: versAscii(`NGola: aucune pharmacie n'a confirme ${v.drug} pour le moment. Pharmacies de garde: ${lienSansSchema(v, '/garde')}`) }; },
    },
  },
  restricted_attente: {
    canaux: {
      telegram: (v) => ({ format: 'html', texte: 'Ce médicament est soumis à une réglementation stricte. Votre demande sera examinée par notre équipe avant toute transmission. ' +
        `En cas d'urgence, rendez-vous directement dans une pharmacie de garde : ${lienSansSchema(v || {}, '/garde')}` }),
      sms: (v) => ({ format: 'texte', texte: versAscii('NGola: ce medicament est soumis a une reglementation stricte. Votre demande sera examinee par notre equipe avant toute transmission. ' +
        `En cas d'urgence, allez directement dans une pharmacie de garde: ${lienSansSchema(v || {}, '/garde')}`) }),
    },
  },
  restricted_refus: {
    canaux: {
      telegram: (v) => ({ format: 'html', texte: 'Ce médicament ne peut pas être recherché via N\'Gola Pharma. Rapprochez-vous directement d\'une pharmacie, avec votre ordonnance. ' +
        `Pharmacies de garde : ${lienSansSchema(v || {}, '/garde')}` }),
      sms: (v) => ({ format: 'texte', texte: versAscii('NGola: ce medicament ne peut pas etre recherche via N\'Gola Pharma. Rapprochez-vous directement d\'une pharmacie, avec votre ordonnance. ' +
        `Pharmacies de garde: ${lienSansSchema(v || {}, '/garde')}`) }),
    },
  },
  // ── Vers l'admin ──
  escalade_admin: {
    canaux: {
      email: (v) => {
        exiger(v, ['id', 'drug', 'quartier', 'n']);
        return { format: 'texte', sujet: `Alerte ${v.id} sans réponse depuis 30 min`,
          texte: `Alerte ${v.id} sans réponse depuis 30 min — ${v.drug} à ${v.quartier} — ${v.n} pharmacies sollicitées.` +
            (v.lien ? `\n${v.lien}` : '') };
      },
    },
  },
};

/** Rend un modèle pour un canal. Lève ErreurModele (modèle ou canal inconnu, variable manquante). */
export function rendre(modele, canal, variables) {
  const def = MODELES[modele];
  if (!def) throw new ErreurModele(`Modèle inconnu : ${modele}`);
  const rendu = def.canaux[canal];
  if (!rendu) throw new ErreurModele(`Le modèle ${modele} n'existe pas pour le canal ${canal}`);
  return rendu(variables || {});
}
