/**
 * Onglet admin « Pharmacies » (SPEC 1 §4) : création en masse depuis un CSV (aperçu, doublons, validation, annulation 24 h), vérification
 * une par une avec checklist obligatoire, invitation du titulaire. Réservé au rôle admin : tout passe par des fonctions SQL qui contrôlent le
 * rôle ; l'invitation passe par l'Edge Function `inviter-pharmacie` (jeton de session vérifié côté serveur).
 */
window.AdminPharmacies = (function () {
    var U = window.PharmaciesMasseUtils, IU = window.ImportUtils;
    var sb, esc, toast, config;
    var etat = { lot: null, filtre: 'tous', decalage: 0, occupe: false, courant: null };
    var PAGE = 100;
    var $ = function (id) { return document.getElementById(id); };

    function init(o) { sb = o.sb; esc = o.esc; toast = o.toast; config = window.NGOLA_ALERTE; }
    function ouvrir() { if (!etat.lot) vueDepart(); chargerAVerifier(); chargerAInviter(); }

    function rpc(nom, args, ok) {
        return sb.rpc(nom, args || {}).then(function (res) {
            if (res.error) { toast(res.error.message, 'error'); return null; }
            if (ok) toast(ok);
            return res.data === undefined || res.data === null ? true : res.data;
        });
    }

    // ── Import : écran de départ ──
    function vueDepart() {
        etat.lot = null;
        $('pharmaciesImport').innerHTML =
            '<p class="console-note">Colonnes : <strong>nom</strong> et <strong>quartier</strong> obligatoires ; adresse, telephone, latitude, longitude, titulaire, numero_ordre, email, telephone_mobile facultatives. ' +
            'Toutes les pharmacies sont créées <strong>non vérifiées et non publiées</strong> ; vous les vérifiez ensuite une par une (checklist de 5 cases obligatoire).</p>' +
            '<div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px"><button class="btn btn-secondary" onclick="AdminPharmacies.modele()">⬇ Modèle CSV</button></div>' +
            '<div class="import-zone" id="pharmaciesZone"><div class="icon">📄</div><p><strong>Glissez un fichier ici</strong> ou cliquez pour sélectionner</p><p style="font-size:12px;margin-top:4px">.csv — 5 Mo et 1 000 lignes au maximum</p></div>' +
            '<input type="file" id="pharmaciesFichier" accept=".csv,.txt" style="display:none"><div id="pharmaciesProgression" class="console-note"></div>' +
            '<h4 style="margin:14px 0 6px">Historique</h4><div id="pharmaciesHistorique"><div class="spinner"></div></div>';
        var zone = $('pharmaciesZone'), champ = $('pharmaciesFichier');
        zone.addEventListener('click', function () { champ.click(); });
        ['dragover', 'dragenter'].forEach(function (ev) { zone.addEventListener(ev, function (e) { e.preventDefault(); zone.classList.add('dragover'); }); });
        ['dragleave', 'drop'].forEach(function (ev) { zone.addEventListener(ev, function () { zone.classList.remove('dragover'); }); });
        zone.addEventListener('drop', function (e) { e.preventDefault(); if (e.dataTransfer.files.length) lire(e.dataTransfer.files[0]); });
        champ.addEventListener('change', function () { if (champ.files.length) lire(champ.files[0]); champ.value = ''; });
        chargerHistorique();
    }
    function modele() {
        var blob = new Blob([U.modeleCsv()], { type: 'text/csv;charset=utf-8' });
        var a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'modele-pharmacies.csv';
        document.body.appendChild(a); a.click(); document.body.removeChild(a); setTimeout(function () { URL.revokeObjectURL(a.href); }, 1000);
    }

    // ── Lecture et envoi par paquets ──
    function lire(f) {
        if (etat.occupe) return;
        var err = IU.erreurFichier({ name: f.name, size: f.size });
        if (err || /\.(xlsx|xls)$/i.test(f.name)) { toast(err || 'Format non supporté. Utilisez un fichier .csv.', 'error'); return; }
        var lecteur = new FileReader();
        lecteur.onerror = function () { toast('Fichier illisible.', 'error'); };
        lecteur.onload = function (ev) {
            var r;
            try { r = U.lireTexteCsv(IU.decoderOctets(new Uint8Array(ev.target.result))); } catch (e) { toast('Fichier illisible.', 'error'); return; }
            if (!r.ok) { toast(U.erreurLecture(r), 'error'); return; }
            envoyer(f.name, r.lignes);
        };
        lecteur.readAsArrayBuffer(f);
    }
    function progression(t) { var z = $('pharmaciesProgression'); if (z) z.textContent = t; }
    function envoyer(nom, lignes) {
        etat.occupe = true; progression('Analyse de ' + lignes.length + ' ligne(s)…');
        rpc('pm_creer_lot', { p_nom_fichier: nom }).then(function (lot) {
            if (!lot) { etat.occupe = false; return; }
            var paquets = IU.decouper(lignes, U.TAILLE_PAQUET), fait = 0;
            (function suivant(i) {
                if (i >= paquets.length) {
                    return rpc('pm_finaliser_lot', { p_lot: lot }).then(function (c) {
                        etat.occupe = false;
                        if (!c) { rpc('pm_abandonner_lot', { p_lot: lot }); return; }
                        etat.lot = lot; etat.filtre = 'tous'; etat.decalage = 0; vueApercu();
                    });
                }
                rpc('pm_ajouter_lignes', { p_lot: lot, p_lignes: paquets[i] }).then(function (r) {
                    if (!r) { etat.occupe = false; rpc('pm_abandonner_lot', { p_lot: lot }); return; }
                    fait += paquets[i].length; progression('Analyse… ' + fait + ' / ' + lignes.length); suivant(i + 1);
                });
            }(0));
        });
    }

    // ── Aperçu ──
    var FILTRES = [['tous', 'Toutes'], ['pret', 'Prêtes'], ['doublon', 'Doublons'], ['erreur', 'Erreurs'], ['avertissement', 'Avertissements']];
    function vueApercu() {
        $('pharmaciesImport').innerHTML =
            '<div class="section-header"><h4>🔎 Aperçu</h4><button class="btn btn-secondary" onclick="AdminPharmacies.abandonner()">✖ Abandonner</button></div>' +
            '<div id="pharmaciesResume" class="console-note"></div>' +
            '<div id="pharmaciesFiltres" style="display:flex;gap:6px;flex-wrap:wrap;margin:8px 0">' + FILTRES.map(function (f) { return '<button class="btn btn-secondary" data-f="' + f[0] + '" onclick="AdminPharmacies.filtrer(\'' + f[0] + '\')">' + f[1] + '</button>'; }).join('') + '</div>' +
            '<div style="overflow-x:auto"><table class="stock-table"><thead><tr><th>Ligne</th><th>Pharmacie</th><th>État</th><th>Action</th></tr></thead><tbody id="pharmaciesLignes"><tr><td colspan="4"><div class="spinner"></div></td></tr></tbody></table></div>' +
            '<div style="display:flex;gap:8px;justify-content:space-between;margin-top:10px;flex-wrap:wrap"><div><button class="btn btn-secondary" onclick="AdminPharmacies.page(-1)">← Précédent</button> <button class="btn btn-secondary" onclick="AdminPharmacies.page(1)">Suivant →</button></div>' +
            '<button class="btn btn-add" id="pharmaciesValider" onclick="AdminPharmacies.valider()">✅ Créer les pharmacies retenues</button></div>';
        chargerLignes();
    }
    function majResume(c) {
        $('pharmaciesResume').textContent = U.resume(c) + (c.avertissements ? ' ' + c.avertissements + ' avertissement(s).' : '');
        $('pharmaciesValider').disabled = !U.peutValider(c);
        Array.prototype.forEach.call(document.querySelectorAll('#pharmaciesFiltres button'), function (b) { b.style.fontWeight = b.getAttribute('data-f') === etat.filtre ? '700' : '400'; });
    }
    function filtrer(f) { etat.filtre = f; etat.decalage = 0; chargerLignes(); }
    function page(d) { var n = Math.max(0, etat.decalage + d * PAGE); if (n === etat.decalage) return; etat.decalage = n; chargerLignes(); }
    function chargerLignes() {
        rpc('pm_lire_lot', { p_lot: etat.lot, p_filtre: etat.filtre, p_limite: PAGE, p_decalage: etat.decalage }).then(function (d) {
            if (!d) return;
            majResume(d.compteurs);
            var corps = $('pharmaciesLignes');
            if (!d.lignes.length) { corps.innerHTML = '<tr><td colspan="4"><div class="empty-state"><p>Aucune ligne dans cette catégorie.</p></div></td></tr>'; return; }
            corps.innerHTML = d.lignes.map(function (l) {
                var e = U.libelleEtat(l.etat), cree = l.resolution === 'create';
                var pb = (l.problemes || []).map(function (p) { return '<div class="console-note" style="color:' + (p.niveau === 'bloquant' ? '#b42318' : '#b26a00') + '">' + esc(U.libelleProbleme(p)) + '</div>'; }).join('');
                var action = l.etat === 'erreur' ? '<span class="console-note">à corriger dans le fichier</span>'
                    : cree ? '<span class="console-note">✔ sera créée</span> <button class="btn btn-secondary" onclick="AdminPharmacies.corriger(' + l.numero + ',\'ignorer\')">Ignorer</button>'
                    : '<span class="console-note">ignorée</span> <button class="btn btn-secondary" onclick="AdminPharmacies.corriger(' + l.numero + ',\'creer\')">Créer quand même</button>';
                return '<tr><td>' + l.numero + '</td><td><strong>' + esc(l.nom || l.brut.nom) + '</strong><br><span class="console-note">' + esc(l.quartier || l.brut.quartier || '—') + (l.adresse ? ' · ' + esc(l.adresse) : '') + (l.telephone ? ' · ' + esc(l.telephone) : '') + (l.a_gps ? ' · 📍' : '') + '</span></td>' +
                    '<td>' + e.icone + ' ' + esc(e.libelle) + pb + '</td><td>' + action + '</td></tr>';
            }).join('');
        });
    }
    function corriger(numero, action) { rpc('pm_corriger_ligne', { p_lot: etat.lot, p_numero: numero, p_action: action }).then(function (c) { if (c) { majResume(c); chargerLignes(); } }); }
    function abandonner() { if (!window.confirm('Abandonner cet import ? Rien ne sera créé.')) return; rpc('pm_abandonner_lot', { p_lot: etat.lot }).then(function () { vueDepart(); }); }
    function valider() {
        if (etat.occupe) return;
        if (!window.confirm('Créer les pharmacies retenues ? Elles seront créées NON vérifiées et NON publiées (annulable pendant 24 h tant qu\'elles ne sont pas vérifiées).')) return;
        etat.occupe = true; $('pharmaciesValider').disabled = true;
        rpc('pm_valider_lot', { p_lot: etat.lot }).then(function (r) {
            etat.occupe = false;
            if (!r) { $('pharmaciesValider').disabled = false; return; }
            var lot = etat.lot; etat.lot = null;
            $('pharmaciesImport').innerHTML = '<p><strong>✅ ' + esc(r.creees) + ' pharmacie(s) créée(s)</strong>, ' + esc(r.ignorees) + ' ligne(s) non créée(s). Elles apparaissent ci-dessous dans « À vérifier ».</p>' +
                '<div style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn btn-delete" onclick="AdminPharmacies.annuler(\'' + esc(lot) + '\')">↺ Annuler cet import</button><button class="btn btn-add" onclick="AdminPharmacies.nouveau()">Nouvel import</button></div>';
            chargerAVerifier();
        });
    }
    function nouveau() { vueDepart(); }
    function annuler(lot) {
        if (!window.confirm('Annuler ce lot ? Les pharmacies encore intactes (non vérifiées, sans stock ni compte) seront supprimées ; les autres sont conservées.')) return;
        rpc('pm_annuler_lot', { p_lot: lot }).then(function (r) { if (!r) return; toast(r.supprimees + ' supprimée(s), ' + r.conservees + ' conservée(s).'); vueDepart(); chargerAVerifier(); });
    }
    var LIB = { parsed: 'En préparation', previewed: 'Aperçu prêt', committed: 'Validé', rolled_back: 'Annulé', failed: 'Abandonné' };
    function chargerHistorique() {
        rpc('pm_historique').then(function (l) {
            var z = $('pharmaciesHistorique'); if (!z) return;
            if (!l || l === true || !l.length) { z.innerHTML = '<div class="empty-state"><p>Aucun import pour le moment.</p></div>'; return; }
            z.innerHTML = '<table class="stock-table"><thead><tr><th>Date</th><th>Fichier</th><th>Résultat</th><th></th></tr></thead><tbody>' + l.map(function (x) {
                var c = x.compteurs || {};
                return '<tr><td>' + esc(new Date(x.cree_le).toLocaleString('fr-FR')) + '</td><td>' + esc(x.nom_fichier) + (x.est_demo ? ' <span class="console-pastille">démo</span>' : '') + '</td><td>' + esc(LIB[x.statut] || x.statut) +
                    (x.statut === 'committed' ? '<br><span class="console-note">' + esc(c.creees || 0) + ' créée(s)</span>' : '') + '</td><td>' + (x.annulable ? '<button class="btn btn-delete" onclick="AdminPharmacies.annuler(\'' + esc(x.id) + '\')">↺ Annuler</button>' : '') + '</td></tr>';
            }).join('') + '</tbody></table>';
        });
    }

    // ── Vérification une par une ──
    function chargerAVerifier() {
        var q = $('pharmaciesRecherche') ? $('pharmaciesRecherche').value.trim() : '';
        rpc('admin_pharmacies_a_verifier', { p_recherche: q || null, p_limite: 100, p_decalage: 0 }).then(function (l) {
            var z = $('pharmaciesAVerifier'); if (!z) return;
            if (l === null) { z.innerHTML = '<div class="empty-state"><p>Liste indisponible.</p></div>'; return; }
            if (l === true || !l.length) { z.innerHTML = '<div class="empty-state"><div class="icon">✅</div><p>Aucune pharmacie à vérifier</p></div>'; return; }
            z.innerHTML = '<table class="stock-table"><thead><tr><th>Pharmacie</th><th>Quartier</th><th>Checklist</th><th></th></tr></thead><tbody>' + l.map(function (p) {
                return '<tr><td><strong>' + esc(p.nom) + '</strong>' + (p.est_demo ? ' <span class="console-pastille">démo</span>' : '') + (p.en_masse ? ' <span class="console-note">import en masse</span>' : '') + '</td><td>' + esc(p.quartier) + '</td><td>' + esc(p.cases) + ' / 5</td>' +
                    '<td><button class="btn btn-secondary" onclick="AdminPharmacies.ouvrirDetail(\'' + esc(p.id) + '\')">Vérifier</button></td></tr>';
            }).join('') + '</tbody></table>';
        });
    }
    function chargerAInviter() {
        rpc('admin_pharmacies_a_inviter').then(function (l) {
            var z = $('pharmaciesAInviter'); if (!z) return;
            if (l === null) { z.innerHTML = ''; return; }
            if (l === true || !l.length) { z.innerHTML = '<div class="empty-state"><p>Aucune pharmacie vérifiée en attente d\'invitation.</p></div>'; return; }
            z.innerHTML = '<table class="stock-table"><thead><tr><th>Pharmacie</th><th>Quartier</th><th>Dernière invitation</th><th></th></tr></thead><tbody>' + l.map(function (p) {
                return '<tr><td><strong>' + esc(p.nom) + '</strong>' + (p.est_demo ? ' <span class="console-pastille">démo</span>' : '') + '</td><td>' + esc(p.quartier) + '</td><td>' + (p.derniere_invitation ? esc(new Date(p.derniere_invitation).toLocaleDateString('fr-FR')) : '—') + '</td>' +
                    '<td><button class="btn btn-add" onclick="AdminPharmacies.inviter(\'' + esc(p.id) + '\')">✉️ Inviter le titulaire</button></td></tr>';
            }).join('') + '</tbody></table>';
        });
    }
    function ouvrirDetail(id) {
        etat.courant = id;
        rpc('admin_detail_verification', { p_pharmacie: id }).then(function (d) {
            if (!d || d === true) return;
            var p = d.pharmacie, i = d.identite || {}, cases = U.etatCases(d.checklist), non = p.statut === 'non_verifie';
            $('pharmaciesDetail').innerHTML =
                '<h4>' + esc(p.nom) + '</h4><table class="stock-table"><tbody><tr><th>Quartier</th><td>' + esc(p.quartier) + '</td></tr><tr><th>Adresse</th><td>' + esc(p.adresse || '—') + '</td></tr><tr><th>Téléphone fixe</th><td>' + esc(p.telephone || '—') + '</td></tr>' +
                '<tr><th>Position</th><td>' + (p.latitude !== null && p.longitude !== null ? '<a target="_blank" rel="noopener noreferrer" href="https://www.google.com/maps?q=' + esc(p.latitude) + ',' + esc(p.longitude) + '">' + esc(p.latitude) + ', ' + esc(p.longitude) + '</a>' : 'non renseignée') + '</td></tr>' +
                '<tr><th>Titulaire</th><td>' + esc(i.nom_titulaire || '—') + '<br><span class="console-note">N° d\'Ordre : ' + esc(i.numero_ordre || '—') + ' · ' + esc(i.email_titulaire || 'email inconnu') + ' · ' + esc(i.telephone_mobile || '—') + '</span></td></tr></tbody></table>' +
                (non ? '<h5 style="margin:12px 0 6px">Checklist de vérification (les 5 cases sont obligatoires)</h5>' + cases.map(function (c) {
                    return '<label style="display:flex;gap:8px;align-items:flex-start;margin:4px 0;font-size:14px"><input type="checkbox" ' + (c.coche ? 'checked ' : '') + 'onchange="AdminPharmacies.basculer(\'' + esc(c.element) + '\', this.checked)"><span>' + esc(c.libelle) + '</span></label>';
                }).join('') + '<button class="btn btn-add" style="margin-top:10px" ' + (U.peutVerifier(d.checklist) ? '' : 'disabled title="Les 5 cases doivent être cochées" ') + 'onclick="AdminPharmacies.verifier()">✅ Marquer comme vérifiée</button>'
                    : '<p class="console-note">Pharmacie déjà vérifiée.</p>') + '<div id="pharmaciesLien" class="console-note"></div>';
        });
    }
    function basculer(element, coche) { rpc('admin_basculer_checklist_pharmacie', { p_pharmacie: etat.courant, p_element: element, p_coche: coche }).then(function () { ouvrirDetail(etat.courant); chargerAVerifier(); }); }
    function verifier() {
        if (!window.confirm('Marquer cette pharmacie comme vérifiée ? Elle ne sera pas publiée tant que sa mise en route n\'est pas terminée.')) return;
        rpc('admin_verifier_pharmacie', { p_pharmacie: etat.courant }, 'Pharmacie vérifiée ✅').then(function (ok) { if (ok) { $('pharmaciesDetail').innerHTML = '<p class="console-note">Choisissez une pharmacie dans la liste.</p>'; chargerAVerifier(); chargerAInviter(); } });
    }
    function inviter(id) {
        if (!window.confirm('Envoyer au titulaire un lien d\'activation de compte (valable 72 h) ?')) return;
        sb.auth.getSession().then(function (r) {
            var jwt = r.data && r.data.session ? r.data.session.access_token : '';
            return fetch(config.apiBase + '/functions/v1/inviter-pharmacie', { method: 'POST', headers: { 'content-type': 'application/json', apikey: config.anonKey, authorization: 'Bearer ' + jwt }, body: JSON.stringify({ pharmacie_id: id }) })
                .then(function (res) { return res.json().catch(function () { return {}; }).then(function (j) { return { ok: res.ok, j: j }; }); });
        }).then(function (r) {
            if (!r.ok) { toast({ pharmacie_non_verifiee: 'La pharmacie doit d\'abord être vérifiée.', email_inconnu: 'Email du titulaire inconnu.', refuse: 'Action réservée à l\'administrateur.' }[r.j.erreur] || 'Invitation impossible.', 'error'); return; }
            toast('Invitation envoyée.'); chargerAInviter();
            if (r.j.lien_activation) $('pharmaciesLienInvitation').innerHTML = '<strong>Mode démo — lien à ouvrir vous-même :</strong><br><input type="text" readonly style="width:100%" value="' + esc(r.j.lien_activation) + '" onclick="this.select()">';
        });
    }

    return { init: init, ouvrir: ouvrir, modele: modele, filtrer: filtrer, page: page, corriger: corriger, abandonner: abandonner, valider: valider, nouveau: nouveau, annuler: annuler,
        chargerAVerifier: chargerAVerifier, ouvrirDetail: ouvrirDetail, basculer: basculer, verifier: verifier, inviter: inviter };
})();
