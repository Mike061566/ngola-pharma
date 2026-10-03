/**
 * Console admin des alertes (SPEC 2 §10) : file en temps réel, chronologie, actions manuelles, réglages, indicateurs.
 * Réservée au rôle admin : chaque appel passe par une fonction SQL qui vérifie le rôle (admin_*, file_alertes_admin, ...)
 * et journalise. Aucune donnée personnelle de patient n'est lue ni affichée (contact et empreintes restent masqués).
 */
window.AdminAlertes = (function () {
    var U = window.AdminUtils;
    var sb, esc, toast;
    var minuteur = null, courant = null, ligneCourante = null, pharmaciesCache = null;
    var $ = function (id) { return document.getElementById(id); };

    function init(o) { sb = o.sb; esc = o.esc; toast = o.toast; }

    function ouvrir() {
        chargerTout();
        if (!minuteur) minuteur = setInterval(function () {
            if ($('tab-console') && $('tab-console').classList.contains('active')) { chargerBandeau(); chargerFile(); if (courant) ouvrirDetail(courant, true); }
        }, 15000);
    }

    function chargerTout() { chargerBandeau(); chargerIndicateurs(); chargerFile(); chargerReglages(); chargerComptesTest(); }

    function rpc(nom, args, ok) {
        return sb.rpc(nom, args || {}).then(function (res) {
            if (res.error) { toast('Refusé : ' + res.error.message, 'error'); return null; }
            if (ok) toast(ok);
            return res.data === undefined ? true : (res.data === null ? true : res.data);
        });
    }

    // ── Bandeau : mode, budget, alertes à examiner ──
    function chargerBandeau() {
        Promise.all([sb.rpc('etat_budget_messages'), sb.from('config_routage').select('valeur').eq('cle', 'mode_application').maybeSingle(),
            sb.rpc('file_alertes_admin', { p_statuts: ['needs_review'], p_limite: 100 })]).then(function (r) {
            var b = r[0].data, mode = r[1].data ? r[1].data.valeur : 'demo', nbRevue = (r[2].data || []).length;
            var niveau = U.niveauBudget(b), couleurs = { ok: '#155724', alerte: '#b26a00', depasse: '#b42318' };
            $('consoleBandeau').innerHTML =
                '<span class="console-pastille" style="background:' + (mode === 'production' ? '#d4edda' : '#fff3cd') + '">' + (mode === 'production' ? 'PRODUCTION' : 'MODE DÉMO') + '</span>' +
                '<span class="console-pastille" style="background:' + (nbRevue ? '#fde8e8' : '#eef0f2') + '">' + nbRevue + ' alerte(s) à examiner</span>' +
                (b ? '<span class="console-pastille" style="color:' + couleurs[niveau] + '">Messages payants : ' + esc(b.utilises) + ' / ' + esc(b.plafond) + (b.pourcentage !== null ? ' (' + esc(b.pourcentage) + ' %)' : '') +
                    (niveau === 'depasse' ? ' — budget dépassé : plus de SMS de relance' : niveau === 'alerte' ? ' — 80 % atteint' : '') + '</span>' : '');
        });
    }

    // ── Indicateurs ──
    function chargerIndicateurs() {
        var jours = parseInt($('consolePeriode').value, 10) || 30;
        sb.rpc('indicateurs_alertes', { p_jours: jours }).then(function (res) {
            var zone = $('consoleIndicateurs');
            if (res.error || !res.data) { zone.textContent = 'Indicateurs indisponibles.'; return; }
            var d = res.data;
            var carte = function (titre, valeur, aide) { return '<div class="console-carte"><div class="console-valeur">' + esc(valeur) + '</div><div>' + esc(titre) + '</div>' + (aide ? '<small>' + esc(aide) + '</small>' : '') + '</div>'; };
            var msgs = d.messages || {};
            var tg = msgs.telegram || {};
            zone.innerHTML =
                carte('Alertes', d.nb_alertes, d.alertes_routees + ' routées') +
                carte('Délai médian 1re réponse', U.formaterDuree(d.delai_median_premiere_reponse_s)) +
                carte('Réponse positive < 15 min', U.pourcentage(d.part_reponse_positive_15min), 'des alertes routées') +
                carte('Activation Telegram', U.pourcentage(d.activation_telegram.taux), d.activation_telegram.avec_telegram + ' / ' + d.activation_telegram.pharmacies_publiees + ' pharmacies publiées') +
                carte('Échecs Telegram', U.pourcentage(tg.taux_echec), (tg.echecs || 0) + ' échec(s)') +
                carte('Repli SMS', U.pourcentage(d.repli_sms.taux), d.repli_sms.sms_de_repli + ' SMS de repli') +
                carte('Coût moyen par alerte', d.cout.moyen_par_alerte === null ? '—' : d.cout.moyen_par_alerte, d.cout.messages_payants + ' message(s) payant(s)') +
                carte('Mises à jour de stock', d.mises_a_jour_stock.total, d.mises_a_jour_stock.disponible + ' dispo · ' + d.mises_a_jour_stock.indisponible + ' rupture');
            var lignes = (d.taux_reponse_pharmacies || []).slice(0, 10).map(function (p) {
                return '<tr><td>' + esc(p.nom) + '</td><td>' + esc(p.envois) + '</td><td>' + esc(p.reponses) + '</td><td>' + U.pourcentage(p.taux) + '</td></tr>';
            }).join('');
            zone.insertAdjacentHTML('beforeend', '<div class="console-carte" style="grid-column:1/-1"><strong>Taux de réponse par pharmacie</strong>' +
                (lignes ? '<table class="stock-table"><thead><tr><th>Pharmacie</th><th>Demandes</th><th>Réponses</th><th>Taux</th></tr></thead><tbody>' + lignes + '</tbody></table>' : '<div>Aucune demande sur la période.</div>') + '</div>');
        });
    }

    // ── File ──
    function chargerFile() {
        var f = $('consoleFiltre').value;
        sb.rpc('file_alertes_admin', { p_statuts: f ? f.split(',') : null, p_limite: 100 }).then(function (res) {
            var zone = $('consoleFile');
            if (res.error) { zone.innerHTML = '<div class="empty-state"><p>' + esc(res.error.message) + '</p></div>'; return; }
            var l = res.data || [];
            window.__fileAdmin = l;
            if (!l.length) { zone.innerHTML = '<div class="empty-state"><div class="icon">✅</div><p>Aucune alerte</p></div>'; return; }
            zone.innerHTML = '<table class="stock-table"><thead><tr><th>Statut</th><th>Médicament</th><th>Quartier</th><th>Âge</th><th>Vague</th><th>Envois</th><th>Réponses</th><th></th></tr></thead><tbody>' +
                l.map(function (a) {
                    var urgent = a.urgence === 'urgent' ? ' <span class="badge-suspended">URGENT</span>' : '';
                    var raison = a.raison_revue ? '<br><small>' + esc(U.libelleRaison(a.raison_revue)) + '</small>' : '';
                    return '<tr class="console-ligne' + (a.id === courant ? ' actif' : '') + '" data-id="' + esc(a.id) + '"><td><strong>' + esc(U.libelleStatut(a.statut)) + '</strong>' + raison + '</td>' +
                        '<td>' + esc(a.medicament) + urgent + '</td><td>' + esc(a.quartier) + '</td><td>' + esc(depuis(a.cree_le)) + '</td>' +
                        '<td>' + esc(a.vague) + (a.routage_manuel ? ' (manuel)' : '') + '</td><td>' + esc(a.nb_envois) + '</td><td>' + esc(a.nb_positives) + ' ✅ / ' + esc(a.nb_reponses) + '</td>' +
                        '<td><button class="btn btn-secondary" data-ouvrir="' + esc(a.id) + '">Ouvrir</button></td></tr>';
                }).join('') + '</tbody></table>';
            Array.prototype.forEach.call(zone.querySelectorAll('[data-ouvrir]'), function (b) { b.addEventListener('click', function () { courant = b.getAttribute('data-ouvrir'); ouvrirDetail(courant); chargerFile(); }); });
        });
    }

    function depuis(iso) {
        var s = (Date.now() - new Date(iso).getTime()) / 1000;
        return s < 90 ? 'à l\'instant' : U.formaterDuree(s).replace(/ \d+ s$/, '');
    }

    // ── Détail : chronologie et actions ──
    function ouvrirDetail(id, silencieux) {
        sb.rpc('chronologie_alerte', { p_alerte_id: id }).then(function (res) {
            var zone = $('consoleDetail');
            if (res.error || !res.data) { if (!silencieux) zone.textContent = 'Alerte introuvable.'; return; }
            var d = res.data, a = d.alerte;
            ligneCourante = (window.__fileAdmin || []).filter(function (x) { return x.id === id; })[0] || { statut: a.statut, routage_manuel: a.routage_manuel };
            var ac = U.actionsPossibles({ statut: a.statut, routage_manuel: a.routage_manuel, nb_positives: ligneCourante.nb_positives || 0, avec_medicament: !!a.medicament });
            var btn = function (cle, libelle, classe) { return ac[cle] ? '<button class="btn ' + (classe || 'btn-secondary') + '" data-action="' + cle + '">' + libelle + '</button>' : ''; };
            var med = a.medicament ? esc(a.medicament.nom + (a.medicament.dosage ? ' ' + a.medicament.dosage : '')) + (a.medicament.restreint ? ' <span class="badge-suspended">restreint</span>' : '') +
                (a.medicament.ordonnance ? ' <span class="badge-unverified">ordonnance</span>' : '') : '<em>non reconnu</em>' + (a.requete_brute ? ' — « ' + esc(a.requete_brute) + ' »' : '');
            zone.innerHTML = '<div class="console-entete"><div><strong>' + esc(a.id_public) + '</strong> — ' + esc(U.libelleStatut(a.statut)) +
                (a.raison_revue ? ' (' + esc(U.libelleRaison(a.raison_revue)) + ')' : '') + '<br>' + med + ' · ' + esc(a.quartier) + '</div></div>' +
                '<p class="console-note">Le contact du patient n\'est jamais affiché. Cette consultation est journalisée.</p>' +
                '<div class="console-actions">' + btn('rattacher', '📎 Rattacher à un médicament') + btn('transmettre', '📤 Transmettre / ajouter une pharmacie') + btn('relancer', '🔁 Relancer une vague') +
                btn('cloturer', '✔ Clôturer') + btn('refuser', '🚫 Refuser', 'btn-delete') + btn('annuler', '✖ Annuler', 'btn-delete') + btn('bloquer', '⛔ Bloquer le patient', 'btn-delete') + '</div>' +
                '<div id="consoleZoneAction"></div>' +
                '<h4 style="margin:14px 0 6px">Chronologie</h4><ul class="console-chrono">' + (d.evenements || []).map(function (e) {
                    var retirer = e.type === 'envoi' && e.statut === 'sent' ? ' <button class="btn btn-delete" data-retirer="' + esc(e.envoi_id) + '">Retirer</button>' : '';
                    return '<li><span class="console-heure">' + esc(new Date(e.t).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit', second: '2-digit' })) + '</span> ' + esc(U.libelleEvenement(e)) + retirer + '</li>';
                }).join('') + '</ul><p class="console-note">Coût estimé : ' + esc(d.cout_estime_total) + '</p>';
            Array.prototype.forEach.call(zone.querySelectorAll('[data-action]'), function (b) { b.addEventListener('click', function () { action(b.getAttribute('data-action'), a); }); });
            Array.prototype.forEach.call(zone.querySelectorAll('[data-retirer]'), function (b) {
                b.addEventListener('click', function () {
                    if (!window.confirm('Retirer ce destinataire ? Son message en attente ne partira pas.')) return;
                    rpc('admin_retirer_destinataire', { p_envoi_id: b.getAttribute('data-retirer') }, 'Destinataire retiré').then(function () { rafraichir(); });
                });
            });
        });
    }

    function rafraichir() { chargerBandeau(); chargerFile(); if (courant) ouvrirDetail(courant, true); }

    function action(nom, a) {
        var simples = {
            relancer: ['admin_relancer_vague', 'Relancer la vague ? Des pharmacies pas encore sollicitées seront contactées.', 'Vague relancée'],
            cloturer: ['admin_cloturer_alerte', 'Clôturer cette alerte ?', 'Alerte clôturée'],
            refuser: ['admin_refuser_alerte', 'Refuser cette demande ? Le patient recevra le message de refus.', 'Demande refusée'],
            annuler: ['admin_annuler_alerte', 'Annuler cette alerte ? Les messages en attente ne partiront pas.', 'Alerte annulée']
        };
        if (simples[nom]) {
            if (!window.confirm(simples[nom][1])) return;
            rpc(simples[nom][0], { p_alerte_id: a.id }, simples[nom][2]).then(rafraichir);
        } else if (nom === 'bloquer') {
            var motif = window.prompt('Motif du blocage (facultatif) ? Le numéro et l\'IP (empreintes) seront bloqués et l\'alerte annulée.', '');
            if (motif === null) return;
            rpc('admin_bloquer_patient', { p_alerte_id: a.id, p_motif: motif || null }, 'Patient bloqué').then(rafraichir);
        } else if (nom === 'rattacher') formulaireRattacher(a);
        else if (nom === 'transmettre') formulaireTransmettre(a);
    }

    function formulaireRattacher(a) {
        var z = $('consoleZoneAction');
        z.innerHTML = '<div class="console-formulaire"><label>Médicament du catalogue</label><input id="consoleRecherche" type="text" placeholder="Nom du médicament" autocomplete="off"><div id="consoleResultats"></div></div>';
        var t = null;
        $('consoleRecherche').addEventListener('input', function () {
            clearTimeout(t);
            t = setTimeout(function () {
                var terme = this.value.replace(/[%_*,()\\]/g, ' ').trim().slice(0, 60);
                if (terme.length < 2) { $('consoleResultats').innerHTML = ''; return; }
                sb.from('medicaments').select('id, nom, dosage, forme, restreint').eq('statut_catalogue', 'actif').ilike('nom', '%' + terme + '%').order('nom').limit(8).then(function (res) {
                    var zone = $('consoleResultats'); zone.textContent = '';
                    (res.data || []).forEach(function (m) {
                        var b = document.createElement('button'); b.type = 'button'; b.className = 'btn btn-secondary'; b.style.display = 'block'; b.style.margin = '4px 0';
                        b.textContent = m.nom + (m.dosage ? ' ' + m.dosage : '') + (m.forme ? ' — ' + m.forme : '') + (m.restreint ? ' (restreint)' : '');
                        b.addEventListener('click', function () {
                            rpc('admin_rattacher_medicament', { p_alerte_id: a.id, p_medicament_id: m.id }).then(function (statut) {
                                if (statut) { toast(statut === 'new' ? 'Rattachée : le routage automatique reprend' : 'Rattachée : reste à examiner (médicament restreint ou non classé)'); rafraichir(); }
                            });
                        });
                        zone.appendChild(b);
                    });
                });
            }.bind(this), 250);
        });
    }

    function formulaireTransmettre(a) {
        var z = $('consoleZoneAction');
        var rendre = function (liste) {
            z.innerHTML = '<div class="console-formulaire"><label>Pharmacies (vérifiées)</label><input id="consoleFiltrePharma" type="text" placeholder="Filtrer par nom">' +
                '<div id="consoleListePharma" style="max-height:200px;overflow:auto;margin:6px 0"></div>' +
                '<p class="console-note">Le message part dans la minute, avec le rappel d\'ordonnance si besoin. Action tracée.</p>' +
                '<button class="btn btn-add" id="consoleEnvoyerPharma">Transmettre</button></div>';
            var dessiner = function () {
                var f = ($('consoleFiltrePharma').value || '').toLowerCase();
                var cochees = {}; Array.prototype.forEach.call(z.querySelectorAll('input[type=checkbox]:checked'), function (c) { cochees[c.value] = true; });
                $('consoleListePharma').innerHTML = liste.filter(function (p) { return !f || p.nom.toLowerCase().indexOf(f) !== -1; }).map(function (p) {
                    return '<label style="display:block;font-weight:400"><input type="checkbox" value="' + esc(p.id) + '"' + (cochees[p.id] ? ' checked' : '') + '> ' + esc(p.nom) + '</label>';
                }).join('');
            };
            $('consoleFiltrePharma').addEventListener('input', dessiner); dessiner();
            $('consoleEnvoyerPharma').addEventListener('click', function () {
                var ids = Array.prototype.map.call(z.querySelectorAll('input[type=checkbox]:checked'), function (c) { return c.value; });
                if (!ids.length) { toast('Choisissez au moins une pharmacie', 'error'); return; }
                rpc('admin_transmettre', { p_alerte_id: a.id, p_pharmacie_ids: ids }).then(function (r) {
                    if (!r) return;
                    var refus = (r.refusees || []).map(function (x) { return U.libelleRefus(x.raison); });
                    toast(r.acceptees + ' pharmacie(s) transmise(s)' + (refus.length ? ' · refusée(s) : ' + refus.join(', ') : ''), r.acceptees ? 'success' : 'error');
                    rafraichir();
                });
            });
        };
        if (pharmaciesCache) { rendre(pharmaciesCache); return; }
        sb.from('pharmacies').select('id, nom').eq('statut', 'verifie').order('nom').limit(300).then(function (res) { pharmaciesCache = res.data || []; rendre(pharmaciesCache); });
    }

    // ── Réglages (config_routage) : validés par la base, journalisés ──
    function chargerReglages() {
        sb.from('config_routage').select('cle, valeur').then(function (res) {
            var zone = $('consoleReglages');
            if (res.error) { zone.textContent = 'Réglages indisponibles.'; return; }
            zone.innerHTML = '<table class="stock-table"><thead><tr><th>Réglage</th><th>Valeur (JSON)</th><th></th></tr></thead><tbody>' + U.reglagesAffichables(res.data).map(function (l) {
                var id = esc(l.cle);
                return '<tr><td><code>' + id + '</code></td><td><input type="text" data-cle="' + id + '" value="' + esc(JSON.stringify(l.valeur)) + '" style="width:100%;padding:6px 8px;border:1px solid var(--border);border-radius:6px"></td>' +
                    '<td><button class="btn btn-secondary" data-enregistrer="' + id + '">Enregistrer</button></td></tr>';
            }).join('') + '</tbody></table><p class="console-note">Le mode (démo / production) se change dans « Classification du catalogue », avec la liste de contrôle.</p>';
            Array.prototype.forEach.call(zone.querySelectorAll('[data-enregistrer]'), function (b) {
                b.addEventListener('click', function () {
                    var cle = b.getAttribute('data-enregistrer');
                    var champ = zone.querySelector('input[data-cle="' + cle.replace(/"/g, '') + '"]');
                    var p = U.analyserValeurConfig(champ.value);
                    if (!p.ok) { toast(p.erreur, 'error'); return; }
                    sb.from('config_routage').update({ valeur: p.valeur }).eq('cle', cle).then(function (r) {
                        if (r.error) { toast('Refusé : ' + r.error.message, 'error'); return; }
                        toast('Réglage « ' + cle + ' » enregistré');
                    });
                });
            });
        });
    }

        // ── Comptes de test, messages « aurait été envoyé », remise à zéro de la démo ──
    function chargerComptesTest() {
        sb.rpc('admin_liste_contacts', { p_limite: 300 }).then(function (res) {
            var zone = $('consoleContacts');
            if (res.error) { zone.textContent = 'Liste indisponible.'; return; }
            var l = res.data || [];
            var icones = { telegram: '✈️ Telegram', sms: '📱 SMS', email: '✉️ Email' };
            zone.innerHTML = l.length ? '<table class="stock-table"><thead><tr><th>Pharmacie</th><th>Canal</th><th>Compte</th><th>Liste blanche</th></tr></thead><tbody>' + l.map(function (c) {
                var etat = c.bloque ? ' (bloqué)' : c.desabonne ? ' (désabonné)' : '';
                var id = esc(c.contact_id);
                return '<tr><td>' + esc(c.pharmacie_nom) + (c.pharmacie_est_demo ? ' <span class="badge-unverified">démo</span>' : '') + '</td><td>' + (icones[c.canal] || esc(c.canal)) + '</td><td>' + esc(c.adresse_masquee) + esc(etat) + '</td>' +
                    '<td>' + (c.est_contact_demo ? '✅ <button class="btn btn-secondary" data-demo="' + id + '" data-valeur="0">Retirer</button>' : '<button class="btn btn-secondary" data-demo="' + id + '" data-valeur="1">Ajouter</button>') + '</td></tr>';
            }).join('') + '</tbody></table>' : '<div class="empty-state"><p>Aucun contact</p></div>';
            Array.prototype.forEach.call(zone.querySelectorAll('[data-demo]'), function (b) {
                b.addEventListener('click', function () {
                    rpc('admin_marquer_contact_demo', { p_contact_id: b.getAttribute('data-demo'), p_demo: b.getAttribute('data-valeur') === '1' }, 'Liste blanche mise à jour').then(chargerComptesTest);
                });
            });
        });
        sb.rpc('file_messages_demo', { p_limite: 50 }).then(function (res) {
            var zone = $('consoleMessagesDemo'), l = res.data || [];
            zone.innerHTML = l.length ? '<ul class="console-chrono">' + l.map(function (m) {
                return '<li><span class="console-heure">' + esc(new Date(m.cree_le).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })) + '</span> ' +
                    esc(m.type_destinataire) + ' · ' + esc(m.canal) + ' · ' + esc(m.modele) + ' — aurait été envoyé</li>';
            }).join('') + '</ul>' : '<p class="console-note">Aucun message supprimé.</p>';
        });
        if (!$('consolePharmaDemo').options.length) {
            sb.from('pharmacies').select('id, nom').eq('est_demo', true).order('slug').limit(100).then(function (res) {
                var s = $('consolePharmaDemo'); s.textContent = '';
                (res.data || []).forEach(function (p) { var o = document.createElement('option'); o.value = p.id; o.textContent = p.nom; s.appendChild(o); });
            });
        }
    }

    function creerCompteTest() {
        var id = $('consolePharmaDemo').value;
        if (!id) { toast('Choisissez une pharmacie de démonstration', 'error'); return; }
        var bot = (window.NGOLA_ALERTE && window.NGOLA_ALERTE.telegramBot) || '';
        if (!bot) { toast('Le bot Telegram n\'est pas encore configuré', 'error'); return; }
        rpc('admin_activer_telegram_demo', { p_pharmacie_id: id }).then(function (r) {
            if (!r) return;
            var ligne = Array.isArray(r) ? r[0] : r;
            var lien = window.ProUtils.lienTelegram(bot, ligne.jeton);
            var zone = $('consoleLienTest'); zone.textContent = '';
            if (!lien) { zone.textContent = 'Lien indisponible.'; return; }
            var a = document.createElement('a'); a.href = lien; a.target = '_blank'; a.rel = 'noopener'; a.className = 'btn btn-add'; a.textContent = 'Ouvrir Telegram et appuyer sur « Démarrer »'; a.style.textDecoration = 'none';
            var p = document.createElement('p'); p.className = 'console-note'; p.textContent = 'Lien à usage unique, valable jusqu\'au ' + new Date(ligne.expire_le).toLocaleString('fr-FR') + '. Une fois activé, ce compte reçoit les messages en vrai.';
            zone.appendChild(a); zone.appendChild(p);
            chargerComptesTest();
        });
    }

    function reinitialiserDemo() {
        var saisie = window.prompt('Remettre la démonstration à zéro ? Alertes, messages et liste de blocage seront effacés. Tapez REINITIALISER pour confirmer.', '');
        if (saisie !== 'REINITIALISER') { if (saisie !== null) toast('Confirmation incorrecte : rien n\'a été fait', 'error'); return; }
        sb.rpc('reinitialiser_demo', { p_nb_pharmacies: 6 }).then(function (res) {
            if (res.error) { toast('Refusé : ' + res.error.message, 'error'); return; }
            $('consoleResumeReset').textContent = U.resumeReinitialisation(res.data);
            toast('Démonstration remise à zéro');
            courant = null; $('consoleDetail').innerHTML = '<p class="console-note">Choisissez une alerte dans la file.</p>';
            chargerTout();
        });
    }

    return { creerCompteTest: creerCompteTest, reinitialiserDemo: reinitialiserDemo, init: init, ouvrir: ouvrir, chargerIndicateurs: chargerIndicateurs, chargerFile: chargerFile, chargerTout: chargerTout };
})();
