// Fournisseur email réel : ZeptoMail (API transactionnelle). Jamais utilisé en dev/test : les tests injectent `fetch`.
// Secrets en variables d'environnement : ZEPTOMAIL_TOKEN (« Send Mail token », avec ou sans le préfixe « Zoho-enczapikey »),
// EMAIL_FROM_ADDRESS (adresse d'un domaine vérifié chez ZeptoMail), EMAIL_FROM_NAME (facultatif),
// ZEPTOMAIL_HOST (facultatif : api.zeptomail.com par défaut ; api.zeptomail.eu / .in selon la région du compte).
// À CONFIRMER avec le compte réel du propriétaire (documentation ZeptoMail non consultable depuis cet environnement) :
// codes d'erreur exacts. Choix prudents : 429 -> limite_debit ; 5xx/réseau -> transitoire ; 401/403 (configuration) -> permanente
// SANS blocage du contact ; autres 4xx -> permanente SANS blocage (un rebond définitif sera traité via les webhooks de rebond).
import { ErreurFournisseur } from './erreurs.js';

const PREFIXE = 'Zoho-enczapikey ';

export function creerFournisseurZeptoMail({ jeton, adresseExpediteur, nomExpediteur = "N'Gola Pharma", hote = 'api.zeptomail.com',
  fetchImpl = globalThis.fetch, delaiMs = 10000 } = {}) {
  if (!jeton) throw new Error('ZEPTOMAIL_TOKEN manquant');
  if (!adresseExpediteur) throw new Error('EMAIL_FROM_ADDRESS manquant');
  if (!/^[a-z0-9.-]+$/i.test(hote)) throw new Error('ZEPTOMAIL_HOST invalide');
  const autorisation = jeton.startsWith(PREFIXE) ? jeton : PREFIXE + jeton;

  return {
    canal: 'email',
    mock: false,
    async envoyer({ adresse, texte, sujet, cleIdempotence }) {
      if (!sujet) throw new ErreurFournisseur('zeptomail : sujet manquant', { type: 'permanente' });
      let reponse;
      try {
        reponse = await fetchImpl(`https://${hote}/v1.1/email`, {
          method: 'POST',
          headers: { 'content-type': 'application/json', accept: 'application/json', authorization: autorisation },
          body: JSON.stringify({
            from: { address: adresseExpediteur, name: nomExpediteur },
            to: [{ email_address: { address: adresse } }],
            subject: sujet,
            textbody: texte,
            ...(cleIdempotence ? { client_reference: String(cleIdempotence).slice(0, 100) } : {}),
          }),
          signal: typeof AbortSignal?.timeout === 'function' ? AbortSignal.timeout(delaiMs) : undefined,
        });
      } catch {
        throw new ErreurFournisseur('zeptomail : réseau', { type: 'transitoire' });
      }
      let json = null;
      try { json = await reponse.json(); } catch { /* corps non JSON */ }
      if (reponse.status >= 200 && reponse.status < 300) {
        return { idMessage: String(json?.request_id ?? json?.data?.[0]?.message_id ?? 'zeptomail'), idDiscussion: null };
      }
      if (reponse.status === 429) {
        const apres = Number(reponse.headers?.get?.('retry-after'));
        throw new ErreurFournisseur('zeptomail : limite de débit', { type: 'limite_debit', retryApresS: apres > 0 ? apres : 30 });
      }
      if (reponse.status >= 500) throw new ErreurFournisseur(`zeptomail : erreur ${reponse.status}`, { type: 'transitoire' });
      // Message d'erreur : code technique seulement (jamais l'adresse ni le contenu).
      const code = String(json?.error?.code ?? '').replace(/[^A-Za-z0-9_]/g, '').slice(0, 40);
      throw new ErreurFournisseur(`zeptomail : refus ${reponse.status}${code ? ` ${code}` : ''}`, { type: 'permanente' });
    },
  };
}
