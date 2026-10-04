/**
 * Import guidé des stocks (SPEC 1 §5.1) — interface de l'onglet « Import » de l'Espace Pro.
 * Lecture du fichier dans le navigateur (ImportUtils), puis tout passe par des fonctions SQL réservées à MA pharmacie :
 * import_creer_lot -> import_ajouter_lignes (paquets) -> import_finaliser_lot -> aperçu et corrections -> import_valider_lot (atomique)
 * -> import_annuler_lot (24 h). Le serveur rapproche avec le catalogue et revalide tout.
 */
window.ImportUI = (function () {
    var U = window.ImportUtils;
    var sb, esc, toast, apres;
    var etat = { lot: null, mode: 'merge', filtre: 'tous', decalage: 0, compteurs: null, occupe: false };
    var PAGE = 100;
    var $ = function (id) { return document.getElementById(id); };

    function init(o) { sb = o.sb; esc = o.esc; toast = o.toast; apres = o.apres || function () {}; }
    function ouvrir() { if (!etat.lot) { vueDepart(); } }
    function racine() { return $('importRoot'); }

    function rpc(nom, args) {
        return sb.rpc(nom, args || {}).then(function (res) {
            if (res.error) { toast(res.error.message, 'error'); return null; }
            return res.data === undefined || res.data === null ? true : res.data;
        });
    }

    // ── Écran de départ : mode, modèle, fichier, historique ──
    function vueDepart() {
        etat.lot = null;
        racine().innerHTML =
            '<div class="section-card"><div class="section-header"><h3>📥 Importer mes stocks</h3></div>' +
            '<p class="console-note">1. Téléchargez le modèle · 2. Remplissez-le (colonnes <strong>nom</strong> et <strong>prix</strong> obligatoires ; dosage, conditionnement, en_stock facultatifs) · 3. Déposez-le ici · 4. Vérifiez l\'aperçu · 5. Validez. Vous pouvez annuler un import pendant 24 h.</p>' +
            '<div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px"><button class="btn btn-secondary" onclick="ImportUI.modele(\'csv\')">⬇ Modèle CSV</button><button class="btn btn-secondary" onclick="ImportUI.modele(\'xlsx\')">⬇ Modèle Excel</button></div>' +
            '<fieldset style="border:1px solid var(--border);border-radius:8px;padding:8px 12px;margin-bottom:12px"><legend style="font-size:13px">Mode</legend>' +
            '<label style="display:block;font-size:14px"><input type="radio" name="importMode" value="merge" checked> Mettre à jour (les produits absents du fichier ne sont pas touchés)</label>' +
            '<label style="display:block;font-size:14px"><input type="radio" name="importMode" value="replace"> Remplacer tout mon stock (les produits absents du fichier sont <strong>archivés</strong>)</label></fieldset>' +
            '<div class="import-zone" id="importZone"><div class="icon">📄</div><p><strong>Glissez un fichier ici</strong> ou cliquez pour sélectionner</p><p style="font-size:12px;margin-top:4px">.csv, .xlsx, .xls — 5 Mo et 5 000 lignes au maximum</p></div>' +
            '<input type="file" id="importFichier" accept=".csv,.txt,.xlsx,.xls" style="display:none">' +
            '<div id="importProgression" class="console-note"></div></div>' +
            '<div class="section-card" style="margin-top:16px"><div class="section-header"><h3>🕘 Historique des imports</h3></div><div id="importHistorique"><div class="spinner"></div></div></div>';
        var zone = $('importZone'), champ = $('importFichier');
        zone.addEventListener('click', function () { champ.click(); });
        ['dragover', 'dragenter'].forEach(function (ev) { zone.addEventListener(ev, function (e) { e.preventDefault(); zone.classList.add('dragover'); }); });
        ['dragleave', 'drop'].forEach(function (ev) { zone.addEventListener(ev, function () { zone.classList.remove('dragover'); }); });
        zone.addEventListener('drop', function (e) { e.preventDefault(); if (e.dataTransfer.files.length) lireFichier(e.dataTransfer.files[0]); });
        champ.addEventListener('change', function () { if (champ.files.length) lireFichier(champ.files[0]); champ.value = ''; });
        chargerHistorique();
    }

    function modele(type) {
        if (type === 'xlsx' && window.XLSX) {
            var wb = window.XLSX.utils.book_new();
            window.XLSX.utils.book_append_sheet(wb, window.XLSX.utils.aoa_to_sheet(U.MODELE), 'Stocks');
            window.XLSX.writeFile(wb, 'modele-import-stocks.xlsx');
            return;
        }
        var blob = new Blob([U.modeleCsv()], { type: 'text/csv;charset=utf-8' });
        var a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'modele-import-stocks.csv';
        document.body.appendChild(a); a.click(); document.body.removeChild(a); setTimeout(function () { URL.revokeObjectURL(a.href); }, 1000);
    }

    // ── Lecture et envoi par paquets ──
    function lireFichier(f) {
        if (etat.occupe) return;
        var err = U.erreurFichier(f); if (err) { toast(err, 'error'); return; }
        var radio = document.querySelector('input[name="importMode"]:checked'); etat.mode = radio ? radio.value : 'merge';
        if (etat.mode === 'replace' && !window.confirm('« Remplacer tout mon stock » : les produits de votre stock absents du fichier seront archivés (annulable pendant 24 h). Continuer ?')) return;
        var lecteur = new FileReader();
        lecteur.onerror = function () { toast('Fichier illisible.', 'error'); };
        lecteur.onload = function (ev) {
            var tableau;
            try {
                if (U.typeFichier(f.name) === 'excel') {
                    var wb = window.XLSX.read(new Uint8Array(ev.target.result), { type: 'array' });
                    tableau = window.XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, raw: true, defval: '' });
                } else tableau = U.parserCsv(U.decoderOctets(new Uint8Array(ev.target.result)));
            } catch (e) { toast('Fichier illisible.', 'error'); return; }
            var r = U.lignesDepuisTableau(tableau);
            if (!r.ok) { toast(U.erreurLecture(r), 'error'); return; }
            envoyer(f.name, r.lignes);
        };
        lecteur.readAsArrayBuffer(f);
    }

    function progression(t) { var z = $('importProgression'); if (z) z.textContent = t; }
    function envoyer(nom, lignes) {
        etat.occupe = true;
        progression('Analyse de ' + lignes.length + ' ligne(s)…');
        rpc('import_creer_lot', { p_nom_fichier: nom, p_mode: etat.mode }).then(function (lot) {
            if (!lot) { etat.occupe = false; return; }
            var paquets = U.decouper(lignes), fait = 0;
            (function suivant(i) {
                if (i >= paquets.length) {
                    return rpc('import_finaliser_lot', { p_lot: lot }).then(function (c) {
                        etat.occupe = false;
                        if (!c) { rpc('import_abandonner_lot', { p_lot: lot }); return; }
                        etat.lot = lot; etat.filtre = 'tous'; etat.decalage = 0; etat.compteurs = c; vueApercu();
                    });
                }
                rpc('import_ajouter_lignes', { p_lot: lot, p_lignes: paquets[i] }).then(function (r) {
                    if (!r) { etat.occupe = false; rpc('import_abandonner_lot', { p_lot: lot }); return; }
                    fait += paquets[i].length; progression('Analyse… ' + fait + ' / ' + lignes.length);
                    suivant(i + 1);
                });
            }(0));
        });
    }

    // ── Aperçu et corrections ──
    var FILTRES = [['tous', 'Toutes'], ['reconnu', 'Reconnues'], ['a_confirmer', 'À confirmer'], ['non_reconnu', 'Non reconnues'], ['erreur', 'Erreurs'], ['avertissement', 'Avertissements']];
    function vueApercu() {
        racine().innerHTML =
            '<div class="section-card"><div class="section-header"><h3>🔎 Aperçu de l\'import</h3><button class="btn btn-secondary" onclick="ImportUI.abandonner()">✖ Abandonner</button></div>' +
            '<div id="importResume" class="console-note"></div>' +
            '<div id="importFiltres" style="display:flex;gap:6px;flex-wrap:wrap;margin:8px 0">' + FILTRES.map(function (f) { return '<button class="btn btn-secondary" data-f="' + f[0] + '" onclick="ImportUI.filtrer(\'' + f[0] + '\')">' + f[1] + '</button>'; }).join('') + '</div>' +
            '<div style="overflow-x:auto"><table class="stock-table"><thead><tr><th>Ligne</th><th>Dans votre fichier</th><th>État</th><th>Médicament retenu</th><th>Actions</th></tr></thead><tbody id="importLignes"><tr><td colspan="5"><div class="spinner"></div></td></tr></tbody></table></div>' +
            '<div style="display:flex;gap:8px;justify-content:space-between;margin-top:10px;flex-wrap:wrap"><div><button class="btn btn-secondary" onclick="ImportUI.page(-1)">← Précédent</button> <button class="btn btn-secondary" onclick="ImportUI.page(1)">Suivant →</button></div>' +
            '<button class="btn btn-add" id="importBoutonValider" onclick="ImportUI.valider()">✅ Importer les lignes retenues</button></div></div>';
        chargerLignes();
    }
    function majResume(c) {
        etat.compteurs = c;
        $('importResume').textContent = U.resume(c) + (c.avertissements ? ' ' + c.avertissements + ' avertissement(s).' : '') + ' Lignes retenues pour l\'import : ' + c.a_ecrire + '.';
        $('importBoutonValider').disabled = !U.peutValider(c);
        Array.prototype.forEach.call(document.querySelectorAll('#importFiltres button'), function (b) { b.style.fontWeight = b.getAttribute('data-f') === etat.filtre ? '700' : '400'; });
    }
    function filtrer(f) { etat.filtre = f; etat.decalage = 0; chargerLignes(); }
    function page(d) { var n = Math.max(0, etat.decalage + d * PAGE); if (n === etat.decalage) return; etat.decalage = n; chargerLignes(); }

    function chargerLignes() {
        rpc('import_lire_lot', { p_lot: etat.lot, p_filtre: etat.filtre, p_limite: PAGE, p_decalage: etat.decalage }).then(function (d) {
            if (!d) return;
            majResume(d.compteurs);
            var corps = $('importLignes');
            if (!d.lignes.length) { corps.innerHTML = '<tr><td colspan="5"><div class="empty-state"><p>Aucune ligne dans cette catégorie.</p></div></td></tr>'; return; }
            corps.innerHTML = d.lignes.map(ligneHtml).join('');
        });
    }
    function ligneHtml(l) {
        var e = U.libelleEtat(l.etat), b = l.brut || {};
        var retenue = l.resolution === 'accepted' || l.resolution === 'mapped_manually';
        var pb = (l.problemes || []).map(function (p) { return '<div class="console-note" style="color:' + (p.niveau === 'bloquant' ? '#b42318' : '#b26a00') + '">' + esc(U.libelleProbleme(p)) + '</div>'; }).join('');
        var cand = (l.candidats || []).map(function (c) { return '<button class="btn btn-secondary" style="margin:2px 4px 2px 0" onclick="ImportUI.mapper(' + l.numero + ',\'' + esc(c.id) + '\')">' + esc(c.libelle) + ' · ' + Math.round(c.score * 100) + ' %</button>'; }).join('');
        var actions = '';
        if (l.etat !== 'erreur') {
            if (l.medicament_id && !retenue) actions += '<button class="btn btn-add" onclick="ImportUI.corriger(' + l.numero + ',\'accepter\')">Accepter</button> ';
            if (retenue) actions += '<button class="btn btn-secondary" onclick="ImportUI.corriger(' + l.numero + ',\'ignorer\')">Ignorer</button> ';
            actions += '<button class="btn btn-secondary" onclick="ImportUI.chercher(' + l.numero + ')">Changer…</button>';
            if (l.etat === 'non_reconnu') actions += ' <button class="btn btn-secondary" onclick="ImportUI.demanderAjout(' + l.numero + ')">Demander l\'ajout au catalogue</button>';
        }
        return '<tr id="import-l-' + l.numero + '"><td>' + l.numero + '</td><td><strong>' + esc(b.nom) + '</strong>' + (b.dosage ? ' · ' + esc(b.dosage) : '') + (b.conditionnement ? ' · ' + esc(b.conditionnement) : '') +
            '<br><span class="console-note">' + (l.prix !== null ? esc(l.prix) + ' FCFA' : esc(b.prix_brut || 'prix absent')) + ' · ' + (l.en_stock ? 'en stock' : 'rupture') + '</span></td>' +
            '<td><span title="' + esc(e.libelle) + '">' + e.icone + ' ' + esc(e.libelle) + '</span>' + (l.confiance !== null && l.etat !== 'erreur' ? '<br><span class="console-note">confiance ' + Math.round(l.confiance * 100) + ' %</span>' : '') + pb + '</td>' +
            '<td>' + (l.medicament ? esc(l.medicament) + (retenue ? '<br><span class="console-note">✔ retenu</span>' : '<br><span class="console-note">non retenu</span>') : '—') + (!retenue && cand ? '<div>' + cand + '</div>' : '') + '<div id="import-rech-' + l.numero + '"></div></td>' +
            '<td>' + actions + '</td></tr>';
    }
    function corriger(numero, action, medicament) {
        rpc('import_corriger_ligne', { p_lot: etat.lot, p_numero: numero, p_action: action, p_medicament: medicament || null }).then(function (c) { if (c) { majResume(c); chargerLignes(); } });
    }
    function mapper(numero, id) { corriger(numero, 'mapper', id); }
    function chercher(numero) {
        var z = $('import-rech-' + numero);
        z.innerHTML = '<input type="text" id="import-q-' + numero + '" placeholder="Nom du médicament du catalogue" style="width:100%;padding:6px 8px;border:1px solid var(--border);border-radius:8px;margin-top:6px"><div id="import-res-' + numero + '"></div>';
        var champ = $('import-q-' + numero), minuteur = null;
        champ.focus();
        champ.addEventListener('input', function () {
            clearTimeout(minuteur);
            minuteur = setTimeout(function () {
                rpc('import_chercher_catalogue', { p_q: champ.value }).then(function (l) {
                    var r = $('import-res-' + numero); if (!r) return;
                    r.innerHTML = (l && l !== true ? l : []).map(function (m) { return '<button class="btn btn-secondary" style="display:block;margin:3px 0" onclick="ImportUI.mapper(' + numero + ',\'' + esc(m.id) + '\')">' + esc(m.libelle) + '</button>'; }).join('') || '<span class="console-note">Aucun résultat.</span>';
                });
            }, 300);
        });
    }
    function demanderAjout(numero) { rpc('import_demander_ajout', { p_lot: etat.lot, p_numero: numero }).then(function (ok) { if (ok) toast('Demande d\'ajout envoyée à l\'équipe N\'Gola Pharma.'); }); }

    function abandonner() {
        if (!window.confirm('Abandonner cet import ? Rien ne sera modifié dans vos stocks.')) return;
        rpc('import_abandonner_lot', { p_lot: etat.lot }).then(function () { vueDepart(); });
    }

    // ── Validation ──
    function valider() {
        if (etat.occupe) return;
        etat.occupe = true; $('importBoutonValider').disabled = true;
        rpc('import_finaliser_lot', { p_lot: etat.lot }).then(function (c) {
            if (!c) { etat.occupe = false; $('importBoutonValider').disabled = false; return; }
            majResume(c);
            var msg = c.a_ecrire + ' ligne(s) vont être écrites dans vos stocks' + (c.a_confirmer ? ' (' + c.a_confirmer + ' ligne(s) « à confirmer » ne seront PAS importées)' : '') + '.' +
                (c.avertissements ? '\n' + c.avertissements + ' avertissement(s) : vérifiez-les.' : '') + (etat.mode === 'replace' ? '\nMode « Remplacer » : les produits absents du fichier seront archivés.' : '') + '\nVous pourrez annuler pendant 24 h. Continuer ?';
            if (!window.confirm(msg)) { etat.occupe = false; $('importBoutonValider').disabled = false; return; }
            rpc('import_valider_lot', { p_lot: etat.lot }).then(function (r) {
                etat.occupe = false;
                if (!r) { $('importBoutonValider').disabled = false; return; }
                vueResultat(r); apres(r);
            });
        });
    }
    function vueResultat(r) {
        var lot = etat.lot; etat.lot = null;
        racine().innerHTML = '<div class="section-card"><div class="section-header"><h3>✅ Import terminé</h3></div>' +
            '<p>' + esc(r.crees) + ' médicament(s) ajouté(s), ' + esc(r.mis_a_jour) + ' mis à jour, ' + esc(r.ignores) + ' ligne(s) non importée(s)' + (r.archives ? ', ' + esc(r.archives) + ' archivé(s)' : '') + '.' +
            (r.publiee ? ' <strong>Votre pharmacie est maintenant publiée 🎉</strong>' : '') + '</p>' +
            '<div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:10px"><button class="btn btn-secondary" onclick="ProApp.switchTab(\'stocks\')">Voir mes stocks</button>' +
            '<button class="btn btn-delete" onclick="ImportUI.annuler(\'' + esc(lot) + '\')">↺ Annuler cet import</button><button class="btn btn-add" onclick="ImportUI.nouveau()">Nouvel import</button></div></div>';
    }
    function nouveau() { vueDepart(); }

    // ── Annulation et historique ──
    function annuler(lot) {
        if (!window.confirm('Annuler cet import ? Les stocks reviendront à leur état d\'avant (les lignes modifiées depuis ne sont pas écrasées).')) return;
        rpc('import_annuler_lot', { p_lot: lot }).then(function (r) {
            if (!r) return;
            toast('Import annulé : ' + r.supprimes + ' supprimé(s), ' + r.restaures + ' restauré(s)' + (r.modifies_depuis ? ', ' + r.modifies_depuis + ' modifié(s) depuis (conservés)' : '') + '.' +
                (r.depubliee ? ' Votre pharmacie n\'est plus publiée : la mise en route doit être complétée (voir la checklist).' : ''));
            apres(r); vueDepart();
        });
    }
    var LIB_STATUT = { parsed: 'En préparation', previewed: 'Aperçu prêt', committed: 'Validé', rolled_back: 'Annulé', failed: 'Abandonné' };
    function chargerHistorique() {
        rpc('import_historique').then(function (l) {
            var z = $('importHistorique'); if (!z) return;
            if (!l || l === true || !l.length) { z.innerHTML = '<div class="empty-state"><p>Aucun import pour le moment.</p></div>'; return; }
            z.innerHTML = '<table class="stock-table"><thead><tr><th>Date</th><th>Fichier</th><th>Résultat</th><th></th></tr></thead><tbody>' + l.map(function (x) {
                var c = x.compteurs || {};
                return '<tr><td>' + esc(new Date(x.cree_le).toLocaleString('fr-FR')) + '</td><td>' + esc(x.nom_fichier) + '<br><span class="console-note">' + (x.mode === 'replace' ? 'Remplacer' : 'Mettre à jour') + '</span></td>' +
                    '<td>' + esc(LIB_STATUT[x.statut] || x.statut) + (x.statut === 'committed' || x.statut === 'rolled_back' ? '<br><span class="console-note">' + esc(c.crees || 0) + ' créé(s) · ' + esc(c.mis_a_jour || 0) + ' mis à jour · ' + esc(c.ignores || 0) + ' ignoré(s)</span>' : '') + '</td>' +
                    '<td>' + (x.annulable ? '<button class="btn btn-delete" onclick="ImportUI.annuler(\'' + esc(x.id) + '\')">↺ Annuler</button>' : '') + '</td></tr>';
            }).join('') + '</tbody></table>';
        });
    }

    return { init: init, ouvrir: ouvrir, modele: modele, filtrer: filtrer, page: page, corriger: corriger, mapper: mapper, chercher: chercher,
        demanderAjout: demanderAjout, abandonner: abandonner, valider: valider, annuler: annuler, nouveau: nouveau };
})();
