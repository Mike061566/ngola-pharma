/**
 * Onglet admin « Demandes » (SPEC 1 §4) : file des pré-inscriptions, détail, justificatifs (URL signée de 5 min), checklist,
 * décisions (approuver / compléments / refuser) et renvoi d'invitation. Réservé au rôle admin : lectures et checklist par fonctions SQL
 * qui vérifient le rôle ; décisions par l'Edge Function `decider-demande` (jeton de session vérifié côté serveur).
 */
window.AdminDemandes = (function () {
    var U = window.AdminDemandesUtils;
    var sb, esc, toast, config;
    var courant = null;
    var $ = function (id) { return document.getElementById(id); };

    function init(o) { sb = o.sb; esc = o.esc; toast = o.toast; config = window.NGOLA_ALERTE; }
    function ouvrir() { chargerFile(); chargerEnRetard(); }

    function rpc(nom, args, ok) {
        return sb.rpc(nom, args || {}).then(function (res) {
            if (res.error) { toast('Refusé : ' + res.error.message, 'error'); return null; }
            if (ok) toast(ok);
            return res.data === undefined || res.data === null ? true : res.data;
        });
    }
    function appelFonction(nom, corps) {
        return sb.auth.getSession().then(function (r) {
            var jwt = r.data && r.data.session ? r.data.session.access_token : '';
            return fetch(config.apiBase + '/functions/v1/' + nom, { method: 'POST',
                headers: { 'content-type': 'application/json', apikey: config.anonKey, authorization: 'Bearer ' + jwt }, body: JSON.stringify(corps) })
                .then(function (res) { return res.json().catch(function () { return {}; }).then(function (j) { return { ok: res.ok, j: j }; }); });
        });
    }

    function chargerFile() {
        var f = $('demandesFiltre').value;
        var args = { p_statut: null, p_doublons: null };
        if (f === 'doublons') args.p_doublons = true; else if (f) args.p_statut = f;
        rpc('admin_lister_demandes', args).then(function (l) {
            var zone = $('demandesFile');
            if (l === null) { zone.innerHTML = '<div class="empty-state"><p>Liste indisponible.</p></div>'; return; }
            if (l === true || !l.length) { zone.innerHTML = '<div class="empty-state"><div class="icon">📭</div><p>Aucune demande</p></div>'; return; }
            zone.innerHTML = '<table class="stock-table"><thead><tr><th>Officine</th><th>Quartier</th><th>Statut</th><th>Reçue</th><th>Checklist</th><th></th></tr></thead><tbody>' +
                l.map(function (d) {
                    var age = U.formaterAge(d.age_heures, d.en_retard);
                    return '<tr><td><strong>' + esc(d.nom_pharmacie) + '</strong>' + (d.doublon_suspect ? ' <span class="console-pastille" style="background:#fde8e8">Doublon suspect</span>' : '') +
                        (d.est_demo ? ' <span class="console-pastille">démo</span>' : '') + '<br><span class="console-note">' + esc(d.nom_titulaire) + '</span></td>' +
                        '<td>' + esc(d.quartier) + '</td><td>' + esc(U.libelleStatut(d.statut)) + '</td>' +
                        '<td' + (age.retard ? ' style="color:#b42318;font-weight:700"' : '') + '>' + esc(age.texte) + (age.retard ? ' ⚠' : '') + '</td>' +
                        '<td>' + esc(d.cases_cochees) + ' / 5 · ' + esc(d.nb_documents) + ' doc.</td>' +
                        '<td><button class="btn btn-secondary" onclick="AdminDemandes.ouvrirDetail(\'' + esc(d.id) + '\')">Ouvrir</button></td></tr>';
                }).join('') + '</tbody></table>';
        });
    }

    function chargerEnRetard() {
        rpc('admin_pharmacies_en_retard').then(function (l) {
            var zone = $('demandesRetard');
            if (l === null) { zone.innerHTML = '<div class="empty-state"><p>Liste indisponible.</p></div>'; return; }
            if (l === true || !l.length) { zone.innerHTML = '<div class="empty-state"><div class="icon">✅</div><p>Aucune pharmacie en attente de publication</p></div>'; return; }
            zone.innerHTML = '<table class="stock-table"><thead><tr><th>Pharmacie</th><th>Depuis</th><th>Avancement</th><th>Étape en attente</th><th>Rappels</th></tr></thead><tbody>' + l.map(function (p) {
                return '<tr><td><strong>' + esc(p.nom) + '</strong>' + (p.est_demo ? ' <span class="console-pastille">démo</span>' : '') + (p.dormante ? ' <span class="console-pastille" style="background:#fde8e8">Dormante</span>' : '') + '</td>' +
                    '<td>' + esc(p.jours) + ' j</td><td>' + esc(p.faits) + ' / 6</td><td>' + esc(window.OnboardingUtils.libelleEtape(p.compte_actif ? p.etape : 'activation')) + '</td>' +
                    '<td>' + (p.rappels.length ? p.rappels.map(function (j) { return 'J+' + esc(j); }).join(', ') : '—') + '</td></tr>';
            }).join('') + '</tbody></table>';
        });
    }

    function ouvrirDetail(id) {
        courant = id;
        rpc('admin_detail_demande', { p_id: id }).then(function (d) {
            if (!d || d === true) return;
            var dem = d.demande, zone = $('demandesDetail');
            var cases = U.etatChecklist(d.checklist), actions = U.actionsPossibles(dem.statut);
            var enRevue = dem.statut === 'in_review';
            zone.innerHTML =
                '<h4>' + esc(dem.nom_pharmacie) + ' <span class="console-pastille">' + esc(U.libelleStatut(dem.statut)) + '</span></h4>' +
                (dem.doublon_suspect ? '<div class="console-formulaire" style="background:#fde8e8"><strong>Doublon suspect :</strong> ' + esc(U.libellesRaisons(dem.doublon_raisons).join(' · ')) + '</div>' : '') +
                '<table class="stock-table"><tbody>' +
                '<tr><th>Quartier</th><td>' + esc(d.quartier) + '</td></tr><tr><th>Adresse</th><td>' + esc(dem.adresse) + '</td></tr>' +
                '<tr><th>Téléphone fixe</th><td>' + esc(dem.telephone_fixe) + ' (rappel de vérification)</td></tr>' +
                '<tr><th>Titulaire</th><td>' + esc(dem.nom_titulaire) + '<br>' + esc(dem.email_titulaire) + ' · ' + esc(dem.telephone_mobile) + '</td></tr>' +
                '<tr><th>N° d\'Ordre</th><td>' + esc(dem.numero_ordre) + '</td></tr>' +
                '<tr><th>Position</th><td>' + (dem.latitude !== null && dem.longitude !== null ? '<a target="_blank" rel="noopener noreferrer" href="https://www.google.com/maps?q=' + esc(dem.latitude) + ',' + esc(dem.longitude) + '">' + esc(dem.latitude) + ', ' + esc(dem.longitude) + '</a>' : 'non renseignée') + '</td></tr>' +
                '<tr><th>Garde</th><td>' + (dem.participe_garde ? 'oui' : 'non') + '</td></tr></tbody></table>' +
                (d.onboarding ? '<h5 style="margin:12px 0 6px">Mise en route de la pharmacie (' + esc(d.onboarding.faits) + ' / ' + esc(d.onboarding.total) + ') — ' + (d.onboarding.est_publiee ? 'publiée' : 'non publiée') + '</h5>' +
                    '<div class="console-note">' + window.OnboardingUtils.tachesAffichables(d.onboarding).map(function (t) { return (t.fait ? '✅ ' : '⬜ ') + esc(t.titre) + (t.detail ? ' — ' + esc(t.detail) : ''); }).join('<br>') + '</div>' : '') +
                '<h5 style="margin:12px 0 6px">Justificatifs</h5>' +
                (d.documents.length ? d.documents.map(function (x) {
                    return '<div><button class="btn btn-secondary" onclick="AdminDemandes.voirDocument(\'' + esc(x.id) + '\')">📄 ' + esc(U.libelleNature(x.nature)) + '</button> <span class="console-note">' + Math.round(x.taille_octets / 1024) + ' Ko</span></div>';
                }).join('') : '<p class="console-note">Aucun justificatif.</p>') +
                '<h5 style="margin:12px 0 6px">Checklist de vérification</h5>' +
                (enRevue ? '' : '<p class="console-note">La checklist se remplit une fois la revue démarrée.</p>') +
                cases.map(function (c) {
                    return '<label style="display:flex;gap:8px;align-items:flex-start;margin:4px 0;font-size:14px"><input type="checkbox" ' + (c.coche ? 'checked ' : '') + (enRevue ? '' : 'disabled ') +
                        'onchange="AdminDemandes.basculer(\'' + esc(c.element) + '\', this.checked)"><span>' + esc(c.libelle) + '</span></label>';
                }).join('') +
                '<div id="demandesActions" style="margin-top:12px;display:flex;gap:8px;flex-wrap:wrap">' +
                (actions.indexOf('demarrer') >= 0 ? '<button class="btn btn-add" onclick="AdminDemandes.demarrer()">▶ Démarrer la revue</button>' : '') +
                (actions.indexOf('approuver') >= 0 ? '<button class="btn btn-add" ' + (U.peutApprouver(dem.statut, d.checklist) ? '' : 'disabled title="Les 5 cases doivent être cochées" ') + 'onclick="AdminDemandes.decider(\'approve\')">✅ Approuver</button>' : '') +
                (actions.indexOf('complements') >= 0 ? '<button class="btn btn-secondary" onclick="AdminDemandes.decider(\'request_info\')">❓ Demander des compléments</button>' : '') +
                (actions.indexOf('refuser') >= 0 ? '<button class="btn btn-delete" onclick="AdminDemandes.decider(\'reject\')">⛔ Refuser</button>' : '') +
                (actions.indexOf('renvoyer_invitation') >= 0 ? '<button class="btn btn-secondary" onclick="AdminDemandes.renvoyer()">✉️ Renvoyer l\'invitation</button>' : '') +
                '</div><div id="demandesLien" class="console-note"></div>' +
                '<h5 style="margin:12px 0 6px">Journal</h5>' +
                '<div class="console-note">' + d.journal.map(function (e) { return esc(new Date(e.t).toLocaleString('fr-FR')) + ' — ' + esc(e.evenement) + (e.details && e.details.motif ? ' (' + esc(e.details.motif) + ')' : ''); }).join('<br>') + '</div>';
        });
    }

    function voirDocument(id) {
        appelFonction('url-document', { document_id: id }).then(function (r) {
            if (r.ok && r.j.url) window.open(r.j.url, '_blank', 'noopener');
            else toast(U.messageErreur(r.j.erreur), 'error');
        });
    }
    function basculer(element, coche) {
        rpc('admin_basculer_checklist', { p_id: courant, p_element: element, p_coche: coche }).then(function () { ouvrirDetail(courant); });
    }
    function demarrer() { rpc('admin_demarrer_revue', { p_id: courant }, 'Revue démarrée').then(function () { chargerFile(); ouvrirDetail(courant); }); }

    function decider(decision) {
        var motif = '';
        if (decision !== 'approve') {
            motif = window.prompt(decision === 'reject' ? 'Motif du refus (envoyé au demandeur) :' : 'Quels compléments demander ? (envoyé au demandeur) :');
            if (motif === null) return;
            if (motif.trim().length < 3) { toast('Un motif est obligatoire.', 'error'); return; }
        } else if (!window.confirm('Approuver cette demande ? La pharmacie sera créée (vérifiée, non publiée) et une invitation envoyée par email.')) return;
        envoyerDecision(decision, motif);
    }
    function renvoyer() { if (window.confirm('Renvoyer une invitation (l\'ancien lien sera invalidé) ?')) envoyerDecision('resend_invite', ''); }
    function envoyerDecision(decision, motif) {
        appelFonction('decider-demande', { demande_id: courant, decision: decision, motif: motif }).then(function (r) {
            if (!r.ok) { toast(U.messageErreur(r.j.erreur), 'error'); return; }
            toast('Décision enregistrée.');
            chargerFile(); ouvrirDetail(courant);
            // Mode démo seulement : le serveur renvoie le lien (le candidat est fictif, aucun email réel ne part).
            var lien = r.j.lien_activation || r.j.lien_complements;
            if (lien) setTimeout(function () {
                $('demandesLien').innerHTML = '<strong>Mode démo — lien à ouvrir vous-même :</strong><br><input type="text" readonly style="width:100%" value="' + esc(lien) + '" onclick="this.select()">';
            }, 600);
        });
    }

    return { init: init, ouvrir: ouvrir, chargerFile: chargerFile, chargerEnRetard: chargerEnRetard, ouvrirDetail: ouvrirDetail, voirDocument: voirDocument, basculer: basculer,
        demarrer: demarrer, decider: decider, renvoyer: renvoyer };
})();
