-- ============================================================
-- N'Gola Pharma — catalogue : conditionnement (`pack_size` de la spec) ; import : rapprochement et avertissements de conditionnement ;
-- annulation d'import : dépublication automatique si le seuil de publication n'est plus atteint.
-- PRODUCTION : à exécuter à la main, après sauvegarde et après 20261014000000. Rétro-compatible.
-- NE TOUCHE PAS à `restreint` (restricted), `ordonnance` (requires_prescription) ni `classification_validee_le` (classification_validated_at) :
-- aucune de ces trois colonnes n'est lue, écrite ni recalculée ici ; la nouvelle colonne est NULL pour toutes les fiches existantes.
-- Nom de colonne : `conditionnement` (noms français du dépôt, voir docs/specs/NOMS-FR.md) ; la vue de compatibilité `drug_catalog` l'expose en `pack_size`.
-- Les fonctions import_ajouter_lignes, import_corriger_ligne et import_annuler_lot de 20261013000000 sont REMPLACÉES (CREATE OR REPLACE).
-- ============================================================
BEGIN;

-- ── 1. Colonne, unicité, vue de compatibilité ─────────────────────────
ALTER TABLE public.medicaments ADD COLUMN IF NOT EXISTS conditionnement text;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'medicaments_conditionnement_longueur') THEN
        ALTER TABLE public.medicaments ADD CONSTRAINT medicaments_conditionnement_longueur
            CHECK (conditionnement IS NULL OR char_length(conditionnement) BETWEEN 1 AND 100);
    END IF;
END $$;

-- Unicité : nom + dosage + conditionnement (normalisés). L'index garde son NOM historique `uq_medicaments_nom_dosage` : les diagnostics,
-- le retour arrière et les tests de la fusion le référencent. Plus permissif que l'ancien (une dimension de plus) : toute donnée valide
-- pour l'ancien l'est pour le nouveau, et toutes les fiches existantes ont un conditionnement NULL (même clé qu'avant).
DROP INDEX IF EXISTS public.uq_medicaments_nom_dosage;
CREATE UNIQUE INDEX uq_medicaments_nom_dosage ON public.medicaments (
    lower(btrim(nom)),
    lower(regexp_replace(coalesce(dosage, ''), '\s', '', 'g')),
    lower(regexp_replace(coalesce(conditionnement, ''), '\s', '', 'g')));

CREATE OR REPLACE VIEW public.drug_catalog WITH (security_invoker = true) AS
SELECT m.id,
       m.dci,
       m.nom_commercial AS brand_name,
       m.dosage AS strength,
       m.forme AS form,
       m.conditionnement AS pack_size,
       m.ordonnance AS requires_prescription,
       m.restreint AS restricted,
       m.classification_validee_le AS classification_validated_at,
       m.est_demo AS is_demo,
       m.validation_classification_id AS classification_validation_id,
       m.statut_catalogue AS status
FROM public.medicaments m;

-- ── 2. Comparaison de conditionnements ────────────────────────────────
-- « Boîte de 16 », « 16 comprimés » et « B/16 » portent les mêmes nombres : on compare les NOMBRES (triés), jamais les mots.
CREATE OR REPLACE FUNCTION public.jetons_nombres(p text) RETURNS text
LANGUAGE sql IMMUTABLE
AS $$ SELECT NULLIF((SELECT string_agg(n, ' ' ORDER BY n) FROM regexp_split_to_table(
        regexp_replace(public.normaliser_texte_medicament(p), '[^0-9.]+', ' ', 'g'), '\s+') n WHERE n ~ '^[0-9]+(\.[0-9]+)?$'), '') $$;

-- 2 mêmes nombres ; 0 inconnu d'un côté (ou nombres absents) ; -1 nombres différents.
CREATE OR REPLACE FUNCTION public.conditionnements_compatibles(p_ligne text, p_fiche text) RETURNS integer
LANGUAGE sql IMMUTABLE
AS $$ SELECT CASE WHEN coalesce(p_ligne, '') = '' OR coalesce(p_fiche, '') = '' THEN 0 WHEN p_ligne = p_fiche THEN 2 ELSE -1 END $$;

-- Avertissement d'une ligne qui indique un conditionnement (NULL si rien à signaler). Jamais bloquant.
--  - fiche sans conditionnement : le conditionnement de la ligne ne peut pas être vérifié (en attendant que le catalogue le renseigne) ;
--  - conditionnements différents : probablement une autre présentation du produit.
CREATE OR REPLACE FUNCTION public.avertissement_conditionnement(p_brut text, p_medicament uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE v_fiche text; v_ligne text := public.jetons_nombres(p_brut);
BEGIN
    IF btrim(coalesce(p_brut, '')) = '' OR p_medicament IS NULL THEN RETURN NULL; END IF;
    SELECT conditionnement INTO v_fiche FROM public.medicaments WHERE id = p_medicament;
    IF btrim(coalesce(v_fiche, '')) = '' THEN
        RETURN jsonb_build_object('code', 'conditionnement_non_verifie', 'niveau', 'avertissement',
            'detail', 'la fiche du catalogue n''indique pas de conditionnement : « ' || left(btrim(p_brut), 60) || ' » n''est pas vérifié');
    END IF;
    IF public.conditionnements_compatibles(v_ligne, public.jetons_nombres(v_fiche)) = -1 THEN
        RETURN jsonb_build_object('code', 'conditionnement_different', 'niveau', 'avertissement',
            'detail', 'fichier : « ' || left(btrim(p_brut), 60) || ' » ; catalogue : « ' || left(v_fiche, 60) || ' »');
    END IF;
    RETURN NULL;
END $f$;
REVOKE ALL ON FUNCTION public.jetons_nombres(text), public.conditionnements_compatibles(text, text), public.avertissement_conditionnement(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jetons_nombres(text), public.conditionnements_compatibles(text, text), public.avertissement_conditionnement(text, uuid) TO authenticated;

-- Libellé d'une fiche : le conditionnement s'ajoute quand il existe (les libellés des fiches sans conditionnement ne changent pas).
CREATE OR REPLACE FUNCTION public.libelle_fiche(m public.medicaments) RETURNS text
LANGUAGE sql IMMUTABLE
AS $$ SELECT btrim(concat_ws(' ', coalesce(m.nom_commercial, m.nom), m.dosage, CASE WHEN m.forme IS NOT NULL THEN '(' || m.forme || ')' END,
                             CASE WHEN m.conditionnement IS NOT NULL THEN '— ' || m.conditionnement END)) $$;

-- ── 3. Import : rapprochement avec le conditionnement, avertissements ─
CREATE OR REPLACE FUNCTION public.import_ajouter_lignes(p_lot uuid, p_lignes jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE
    l public.lots_import%ROWTYPE := public.lot_du_pharmacien(p_lot, true);
    r record;
    v_n int;
    v_nom text; v_dos_norm text; v_nom_norm text; v_nom_sans text; v_hint text;
    v_pack text; v_aw jsonb; v_pb jsonb; v_prob jsonb; v_cand jsonb; v_etat text; v_med uuid; v_conf numeric; v_meth text; v_res text;
    c record; n_alias int; v_alias uuid;
BEGIN
    IF l.statut <> 'parsed' THEN RAISE EXCEPTION 'Ce lot n''accepte plus de lignes' USING ERRCODE = '55000'; END IF;
    IF jsonb_typeof(p_lignes) <> 'array' OR jsonb_array_length(p_lignes) NOT BETWEEN 1 AND 500 THEN
        RAISE EXCEPTION '1 à 500 lignes par appel' USING ERRCODE = '22023';
    END IF;
    SELECT count(*) INTO v_n FROM public.lignes_import WHERE lot_id = p_lot;
    IF v_n + jsonb_array_length(p_lignes) > 5000 THEN RAISE EXCEPTION 'Limite de 5 000 lignes par import' USING ERRCODE = '54000'; END IF;

    -- Seuil de pré-filtre : en dessous de 0,45 de similarité aucune ligne ne peut atteindre 0,50 de confiance (« non reconnu » de toute façon).
    PERFORM set_config('pg_trgm.similarity_threshold', '0.45', true);

    -- Clés de rapprochement des fiches actives : nom, nom commercial (sans dosage), dosage normalisé.
    CREATE TEMP TABLE IF NOT EXISTS _cles_catalogue (medicament_id uuid, cle text, dosage text, pack text) ON COMMIT DROP;
    DELETE FROM _cles_catalogue;
    INSERT INTO _cles_catalogue
    SELECT m.id, k.cle, public.normaliser_texte_medicament(m.dosage), public.jetons_nombres(m.conditionnement)
      FROM public.medicaments m
      CROSS JOIN LATERAL (VALUES (public.normaliser_texte_medicament(m.nom)), (public.normaliser_texte_medicament(m.nom_commercial))) k(cle)
     WHERE m.statut_catalogue = 'actif' AND k.cle <> '';
    CREATE INDEX IF NOT EXISTS _cles_catalogue_trgm ON _cles_catalogue USING gin (cle gin_trgm_ops);
    CREATE INDEX IF NOT EXISTS _cles_catalogue_cle ON _cles_catalogue (cle);
    ANALYZE _cles_catalogue;

    FOR r IN SELECT * FROM jsonb_to_recordset(p_lignes) AS x(numero int, nom text, dosage text, conditionnement text, prix_brut text, prix numeric, en_stock boolean, en_stock_invalide boolean)
    LOOP
        IF r.numero IS NULL OR r.numero < 1 THEN RAISE EXCEPTION 'Numéro de ligne invalide' USING ERRCODE = '22023'; END IF;
        v_nom := left(btrim(coalesce(r.nom, '')), 200);
        v_prob := '[]'::jsonb; v_cand := '[]'::jsonb; v_med := NULL; v_conf := NULL; v_meth := 'none'; v_res := 'skipped';
        v_pb := jsonb_build_object('nom', v_nom, 'dosage', left(btrim(coalesce(r.dosage, '')), 100),
                                   'conditionnement', left(btrim(coalesce(r.conditionnement, '')), 100), 'prix_brut', left(coalesce(r.prix_brut, ''), 50));
        -- Erreurs bloquantes (la ligne est ignorée ; le lot, lui, n'est pas bloqué)
        IF v_nom = '' THEN v_prob := v_prob || jsonb_build_object('code', 'nom_absent', 'niveau', 'bloquant'); END IF;
        IF r.prix IS NULL OR r.prix <> trunc(r.prix) OR r.prix <= 0 OR r.prix > 500000 THEN
            v_prob := v_prob || jsonb_build_object('code', 'prix_invalide', 'niveau', 'bloquant', 'detail', 'prix absent, non numérique, ≤ 0 ou > 500 000');
        END IF;
        IF r.en_stock_invalide IS TRUE THEN v_prob := v_prob || jsonb_build_object('code', 'en_stock_invalide', 'niveau', 'bloquant'); END IF;

        IF v_nom <> '' THEN
            v_nom_norm := public.normaliser_texte_medicament(v_nom);
            v_dos_norm := public.normaliser_texte_medicament(r.dosage);
            v_pack := public.jetons_nombres(r.conditionnement);
            -- Dosage glissé dans le nom : suite de nombres (avec unité facultative) en fin de nom (« Doliprane 500 », « Coartem 20/120 »),
            -- sinon dosage avec unité au milieu (« Doliprane 500mg comprimé »).
            v_hint := (regexp_match(v_nom_norm, '((?:\s+\d+(?:\.\d+)?(?:mg|ml|g|mcg|ug|µg|ui|iu|%)?)+)\s*$'))[1];
            IF v_hint IS NOT NULL THEN
                v_nom_sans := btrim(regexp_replace(v_nom_norm, '((?:\s+\d+(?:\.\d+)?(?:mg|ml|g|mcg|ug|µg|ui|iu|%)?)+)\s*$', ''));
                v_hint := btrim(v_hint);
            ELSE
                v_hint := (regexp_match(v_nom_norm, '(\d+(?:\.\d+)?(?:mg|ml|g|mcg|ug|µg|ui|iu|%))'))[1];
                v_nom_sans := btrim(regexp_replace(v_nom_norm, '\d+(?:\.\d+)?(?:mg|ml|g|mcg|ug|µg|ui|iu|%)', ' ', 'g'));
            END IF;
            IF v_dos_norm = '' AND v_hint IS NOT NULL THEN v_dos_norm := v_hint; END IF;
            IF v_nom_sans = '' THEN v_nom_sans := v_nom_norm; END IF;

            -- 1. Alias exact
            SELECT count(DISTINCT a.medicament_id), min(a.medicament_id::text)::uuid INTO n_alias, v_alias
              FROM public.alias_medicaments a JOIN public.medicaments m ON m.id = a.medicament_id AND m.statut_catalogue = 'actif'
             WHERE a.alias_normalise IN (v_nom_norm, v_nom_sans);
            -- 2. Candidats (alias exact compris) : nom exact + dosage compatible = 1,0 ; sinon similarité corrigée par le dosage
            v_cand := COALESCE((SELECT jsonb_agg(jsonb_build_object('id', t.medicament_id, 'libelle', public.libelle_fiche(m), 'score', round(t.score::numeric, 2),
                                                                      'exact', t.exact) ORDER BY t.score DESC, m.nom)
                FROM (SELECT g.medicament_id, g.score, g.exact FROM (
                        SELECT k.medicament_id,
                               max(CASE WHEN k.cle = v_nom_sans AND d.c >= 1 AND d.p >= 0 THEN 1.0
                                        ELSE LEAST(1.0, GREATEST(similarity(k.cle, v_nom_sans), similarity(k.cle, v_nom_norm))
                                             * CASE d.c WHEN 2 THEN 1.0 WHEN 1 THEN 0.97 WHEN 0 THEN 0.9 ELSE 0.55 END * CASE WHEN d.p < 0 THEN 0.7 ELSE 1.0 END
                                             + CASE WHEN d.c = 2 THEN 0.08 ELSE 0 END + CASE WHEN d.p = 2 THEN 0.04 ELSE 0 END) END) AS score,
                               bool_or(k.cle = v_nom_sans AND d.c >= 1 AND d.p >= 0) AS exact
                          FROM _cles_catalogue k
                          CROSS JOIN LATERAL (SELECT public.dosages_compatibles(v_dos_norm, k.dosage) AS c, public.conditionnements_compatibles(v_pack, k.pack) AS p) d
                         WHERE k.cle % v_nom_sans OR k.cle % v_nom_norm OR k.cle = v_nom_sans
                         GROUP BY k.medicament_id) g
                       ORDER BY g.score DESC LIMIT 3) t
                   JOIN public.medicaments m ON m.id = t.medicament_id), '[]'::jsonb);
            -- Un alias exact (une seule fiche) prime : confiance 1,0
            IF n_alias = 1 THEN
                v_cand := jsonb_build_array(jsonb_build_object('id', v_alias, 'libelle', (SELECT public.libelle_fiche(m) FROM public.medicaments m WHERE m.id = v_alias), 'score', 1.00, 'exact', true))
                          || COALESCE((SELECT jsonb_agg(e) FROM jsonb_array_elements(v_cand) e WHERE (e ->> 'id')::uuid <> v_alias), '[]'::jsonb);
            END IF;
            IF jsonb_array_length(v_cand) > 0 THEN
                v_med := (v_cand -> 0 ->> 'id')::uuid; v_conf := (v_cand -> 0 ->> 'score')::numeric;
                v_meth := CASE WHEN n_alias = 1 OR (v_cand -> 0 ->> 'exact')::boolean THEN 'alias' ELSE 'trigram' END;
                -- Ambiguïté : deux fiches presque aussi proches -> jamais pré-sélectionné
                IF jsonb_array_length(v_cand) > 1 AND n_alias <> 1 AND v_conf - (v_cand -> 1 ->> 'score')::numeric < 0.05 THEN
                    v_etat := 'a_confirmer'; v_prob := v_prob || jsonb_build_object('code', 'ambigu', 'niveau', 'avertissement', 'detail', 'plusieurs fiches possibles');
                ELSIF v_conf >= 0.995 AND v_meth = 'alias' THEN v_etat := 'reconnu';
                ELSIF v_conf >= 0.80 THEN v_etat := 'suggestion';
                ELSIF v_conf >= 0.50 THEN v_etat := 'a_confirmer';
                ELSE v_etat := 'non_reconnu'; v_med := NULL; v_meth := 'none'; END IF;
            ELSE v_etat := 'non_reconnu'; END IF;
        ELSE v_etat := 'non_reconnu'; END IF;

        IF v_med IS NOT NULL AND v_etat IN ('reconnu', 'suggestion', 'a_confirmer') THEN
            v_aw := public.avertissement_conditionnement(r.conditionnement, v_med);
            IF v_aw IS NOT NULL THEN v_prob := v_prob || v_aw; END IF;
        END IF;

        IF jsonb_path_exists(v_prob, '$[*] ? (@.niveau == "bloquant")') THEN v_etat := 'erreur'; v_med := NULL; v_conf := NULL; v_meth := 'none';
        ELSIF v_etat IN ('reconnu', 'suggestion') THEN v_res := 'accepted'; END IF;

        INSERT INTO public.lignes_import (lot_id, numero, brut, prix, en_stock, medicament_id, confiance, methode, etat, problemes, candidats, resolution)
        VALUES (p_lot, r.numero, v_pb, CASE WHEN r.prix IS NOT NULL AND r.prix = trunc(r.prix) AND r.prix BETWEEN 1 AND 500000 THEN r.prix::int END,
                COALESCE(r.en_stock, true), v_med, v_conf, v_meth, v_etat, v_prob, v_cand, v_res);
    END LOOP;
    RETURN jsonb_build_object('lignes', (SELECT count(*) FROM public.lignes_import WHERE lot_id = p_lot));
END $f$;

CREATE OR REPLACE FUNCTION public.import_corriger_ligne(p_lot uuid, p_numero int, p_action text, p_medicament uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE l public.lots_import%ROWTYPE := public.lot_du_pharmacien(p_lot, true); li public.lignes_import%ROWTYPE;
BEGIN
    IF l.statut NOT IN ('parsed', 'previewed') THEN RAISE EXCEPTION 'Import déjà traité' USING ERRCODE = '55000'; END IF;
    SELECT * INTO li FROM public.lignes_import WHERE lot_id = p_lot AND numero = p_numero FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Ligne introuvable' USING ERRCODE = 'P0002'; END IF;
    IF li.etat = 'erreur' AND p_action <> 'ignorer' THEN RAISE EXCEPTION 'Ligne en erreur : corrigez le fichier et réimportez' USING ERRCODE = '55000'; END IF;
    IF p_action = 'ignorer' THEN
        UPDATE public.lignes_import SET resolution = 'skipped' WHERE lot_id = p_lot AND numero = p_numero;
    ELSIF p_action = 'accepter' THEN
        IF li.medicament_id IS NULL THEN RAISE EXCEPTION 'Aucune suggestion à accepter : choisissez un médicament' USING ERRCODE = '55000'; END IF;
        UPDATE public.lignes_import SET resolution = 'accepted' WHERE lot_id = p_lot AND numero = p_numero;
    ELSIF p_action = 'mapper' THEN
        IF NOT EXISTS (SELECT 1 FROM public.medicaments WHERE id = p_medicament AND statut_catalogue = 'actif') THEN
            RAISE EXCEPTION 'Médicament introuvable dans le catalogue' USING ERRCODE = 'P0002';
        END IF;
        UPDATE public.lignes_import SET medicament_id = p_medicament, methode = 'manual', confiance = 1.00, resolution = 'mapped_manually',
            problemes = COALESCE((SELECT jsonb_agg(e) FROM jsonb_array_elements(li.problemes) e WHERE e ->> 'code' NOT IN ('conditionnement_non_verifie', 'conditionnement_different')), '[]'::jsonb)
                        || (SELECT CASE WHEN w IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(w) END FROM (SELECT public.avertissement_conditionnement(li.brut ->> 'conditionnement', p_medicament) AS w) z)
         WHERE lot_id = p_lot AND numero = p_numero;
    ELSE RAISE EXCEPTION 'Action inconnue' USING ERRCODE = '22023'; END IF;
    UPDATE public.lots_import SET statut = 'parsed' WHERE id = p_lot AND statut = 'previewed';   -- toute correction demande une nouvelle finalisation
    RETURN public.import_compter_interne(p_lot);
END $f$;

-- ── 4. Annulation d'import : dépublication automatique si le seuil n'est plus atteint ──
-- Réévalue la règle de publication (la même que evaluer_publication_interne : vérifiée + 6 tâches + stocks frais). Ne dépublie QUE les
-- pharmacies dont la publication est automatique : le dernier événement de publication de la pharmacie est « pharmacie_publiee »
-- (système). Une pharmacie publiée à la main par l'admin (sans cet événement, ou republiée après une dépublication) n'est jamais touchée.
CREATE OR REPLACE FUNCTION public.evaluer_depublication_interne(p_pharmacie uuid, p_raison text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE c jsonb := public.calculer_onboarding(p_pharmacie);
BEGIN
    IF c IS NULL OR NOT (c ->> 'est_publiee')::boolean OR (c ->> 'publiable')::boolean THEN RETURN false; END IF;
    IF COALESCE((SELECT e.evenement FROM public.evenements_onboarding e WHERE e.pharmacie_id = p_pharmacie AND e.evenement IN ('pharmacie_publiee', 'pharmacie_depubliee')
                  ORDER BY e.id DESC LIMIT 1), '') <> 'pharmacie_publiee' THEN RETURN false; END IF;
    UPDATE public.pharmacies SET est_publiee = false, publiee_le = NULL WHERE id = p_pharmacie AND est_publiee;
    IF NOT FOUND THEN RETURN false; END IF;
    PERFORM public.journaliser_onboarding(NULL, p_pharmacie, NULL, 'system', 'pharmacie_depubliee', jsonb_build_object(
        'raison', p_raison, 'taches_faites', c -> 'faits', 'items_frais', c -> 'items_frais', 'min_items_frais', c -> 'min_items_frais',
        'taches_manquantes', COALESCE((SELECT jsonb_agg(i ->> 'cle') FROM jsonb_array_elements(c -> 'items') i WHERE NOT (i ->> 'fait')::boolean), '[]'::jsonb)));
    RETURN true;
END $f$;
REVOKE ALL ON FUNCTION public.evaluer_depublication_interne(uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.import_annuler_lot(p_lot uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE
    l public.lots_import%ROWTYPE := public.lot_du_pharmacien(p_lot, true);
    v_suppr int; v_rest int; v_arch int; v_conflits int; v_depub boolean;
BEGIN
    IF l.statut <> 'committed' THEN RAISE EXCEPTION 'Seul un import validé peut être annulé' USING ERRCODE = '55000'; END IF;
    IF l.valide_le < now() - interval '24 hours' THEN RAISE EXCEPTION 'Annulation impossible : plus de 24 h se sont écoulées' USING ERRCODE = '55000'; END IF;

    -- Lignes inchangées depuis la validation (même prix, même statut, même date de mise à jour)
    DROP TABLE IF EXISTS _cibles;
    CREATE TEMP TABLE _cibles ON COMMIT DROP AS
    SELECT li.numero, s.id AS stock_id, li.valeur_prec AS prec FROM public.lignes_import li
      JOIN public.stocks s ON s.pharmacie_id = l.pharmacie_id AND s.medicament_id = li.medicament_id
     WHERE li.lot_id = p_lot AND li.valeur_nouv IS NOT NULL
       AND s.prix_fcfa = (li.valeur_nouv ->> 'prix_fcfa')::int AND s.statut_stock = li.valeur_nouv ->> 'statut_stock' AND s.date_maj = (li.valeur_nouv ->> 'date_maj')::timestamptz;
    SELECT count(*) INTO v_conflits FROM public.lignes_import WHERE lot_id = p_lot AND valeur_nouv IS NOT NULL AND numero NOT IN (SELECT numero FROM _cibles);

    DELETE FROM public.stocks WHERE id IN (SELECT stock_id FROM _cibles WHERE NOT (prec ->> 'existait')::boolean);
    GET DIAGNOSTICS v_suppr = ROW_COUNT;
    -- 1) valeurs et date de mise à jour (le trigger aligne confirme_le sur date_maj) ; 2) date de confirmation exacte
    UPDATE public.stocks s SET prix_fcfa = (c.prec ->> 'prix_fcfa')::int, en_stock = (c.prec ->> 'en_stock')::boolean, statut_stock = c.prec ->> 'statut_stock',
           date_maj = (c.prec ->> 'date_maj')::timestamptz, source = (c.prec ->> 'source')::source_donnee, mis_a_jour_par = NULLIF(c.prec ->> 'mis_a_jour_par', '')::uuid
      FROM _cibles c WHERE s.id = c.stock_id AND (c.prec ->> 'existait')::boolean;
    UPDATE public.stocks s SET confirme_le = (c.prec ->> 'confirme_le')::timestamptz
      FROM _cibles c WHERE s.id = c.stock_id AND (c.prec ->> 'existait')::boolean;
    GET DIAGNOSTICS v_rest = ROW_COUNT;

    -- Stocks archivés par « Remplacer » : restaurés s'ils sont toujours archivés
    UPDATE public.stocks s SET statut_stock = a.valeur_prec ->> 'statut_stock'
      FROM public.lots_import_archives a WHERE a.lot_id = p_lot AND a.stock_id = s.id AND s.statut_stock = 'archive';
    GET DIAGNOSTICS v_arch = ROW_COUNT;

    UPDATE public.lots_import SET statut = 'rolled_back', annule_le = now() WHERE id = p_lot;
    PERFORM public.journaliser_onboarding(NULL, l.pharmacie_id, auth.uid(), 'pharmacy', 'import_annule', jsonb_build_object('lot', p_lot, 'supprimes', v_suppr, 'restaures', v_rest, 'conflits', v_conflits));
    -- Fin d'annulation : la règle de publication est réévaluée ; si le seuil n'est plus atteint, la pharmacie est dépubliée (audit).
    v_depub := public.evaluer_depublication_interne(l.pharmacie_id, 'import_annule');
    RETURN jsonb_build_object('supprimes', v_suppr, 'restaures', v_rest, 'archives_restaures', v_arch, 'modifies_depuis', v_conflits, 'depubliee', v_depub);
END $f$;

COMMIT;
