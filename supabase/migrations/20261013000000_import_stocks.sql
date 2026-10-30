-- ============================================================
-- N'Gola Pharma — onboarding, étape 3 : import guidé des stocks (SPEC 1 §5.1) : lecture tolérante côté navigateur, rapprochement avec le
-- catalogue (alias exact, similarité trigramme), aperçu, correction ligne par ligne, validation atomique, annulation sous 24 h, historique.
-- PRODUCTION : à exécuter à la main, après relecture, après 20261012000000. Rétro-compatible : aucune table existante modifiée,
-- sauf le critère de la tâche d'onboarding « Importer mes stocks » (« au moins 1 import validé »).
-- Tout passe par des fonctions SECURITY DEFINER qui limitent chaque appel à LA pharmacie de l'utilisateur ; les tables ne sont
-- pas accessibles directement. Un médicament restreint est importé normalement dans le stock (le routage, lui, ne l'utilise jamais).
-- Rapprochement (extensions pg_trgm) : le chemin de recherche inclut `extensions` (Supabase y installe pg_trgm).
-- ============================================================
BEGIN;

-- ── 1. Tables ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.lots_import (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    pharmacie_id  uuid NOT NULL REFERENCES public.pharmacies(id) ON DELETE CASCADE,
    auteur_id     uuid NOT NULL REFERENCES auth.users(id),
    nom_fichier   text NOT NULL CHECK (char_length(btrim(nom_fichier)) BETWEEN 1 AND 200),
    mode          text NOT NULL CHECK (mode IN ('merge', 'replace')),
    statut        text NOT NULL DEFAULT 'parsed' CHECK (statut IN ('parsed', 'previewed', 'committed', 'rolled_back', 'failed')),
    compteurs     jsonb NOT NULL DEFAULT '{}',
    cree_le       timestamptz NOT NULL DEFAULT now(),
    valide_le     timestamptz,
    annule_le     timestamptz
);
CREATE INDEX IF NOT EXISTS idx_lots_import_pharmacie ON public.lots_import (pharmacie_id, cree_le DESC);

CREATE TABLE IF NOT EXISTS public.lignes_import (
    lot_id        uuid NOT NULL REFERENCES public.lots_import(id) ON DELETE CASCADE,
    numero        integer NOT NULL CHECK (numero > 0),
    brut          jsonb NOT NULL,                                  -- ce que le fichier contenait (nom, dosage, conditionnement, prix_brut)
    prix          integer,
    en_stock      boolean NOT NULL DEFAULT true,
    medicament_id uuid REFERENCES public.medicaments(id),
    confiance     numeric(3,2),
    methode       text CHECK (methode IN ('alias', 'trigram', 'manual', 'none')),
    etat          text NOT NULL CHECK (etat IN ('reconnu', 'suggestion', 'a_confirmer', 'non_reconnu', 'erreur')),
    problemes     jsonb NOT NULL DEFAULT '[]',                     -- [{code, niveau: 'bloquant'|'avertissement', detail?}]
    candidats     jsonb NOT NULL DEFAULT '[]',                     -- 3 meilleures fiches : [{id, libelle, score}]
    resolution    text CHECK (resolution IN ('accepted', 'skipped', 'mapped_manually')),
    valeur_prec   jsonb,                                           -- état du stock avant la validation (annulation)
    valeur_nouv   jsonb,                                           -- état écrit par la validation (détection des modifications ultérieures)
    PRIMARY KEY (lot_id, numero)
);
CREATE INDEX IF NOT EXISTS idx_lignes_import_etat ON public.lignes_import (lot_id, etat);

-- Stocks archivés par le mode « Remplacer tout mon stock » (restaurés à l'annulation).
CREATE TABLE IF NOT EXISTS public.lots_import_archives (
    lot_id      uuid NOT NULL REFERENCES public.lots_import(id) ON DELETE CASCADE,
    stock_id    uuid NOT NULL REFERENCES public.stocks(id) ON DELETE CASCADE,
    valeur_prec jsonb NOT NULL,
    PRIMARY KEY (lot_id, stock_id)
);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['lots_import', 'lignes_import', 'lots_import_archives'] LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    END LOOP;
END $$;
DROP POLICY IF EXISTS "Admin lit les lots d'import" ON public.lots_import;
CREATE POLICY "Admin lit les lots d'import" ON public.lots_import FOR SELECT USING (auth_role() = 'admin');
GRANT SELECT ON public.lots_import TO authenticated;

-- ── 2. Normalisation (sans accents, unités collées : « 500 mg » -> « 500mg », virgule décimale) ──
CREATE OR REPLACE FUNCTION public.normaliser_texte_medicament(p text) RETURNS text
LANGUAGE sql IMMUTABLE
AS $$ SELECT btrim(regexp_replace(
         regexp_replace(
           regexp_replace(
             lower(translate(coalesce(p, ''),
               'àâäáãåçéèêëíìîïñóòôöõúùûüýÿÀÂÄÁÃÅÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜÝ', 'aaaaaaceeeeiiiinooooouuuuyyAAAAAACEEEEIIIINOOOOOUUUUY')),
             '(\d)\s*,\s*(\d)', '\1.\2', 'g'),
           '(\d+(?:\.\d+)?)\s*(mg|ml|g|mcg|ug|µg|ui|iu|%)(?![a-z])', '\1\2', 'g'),
         '[^a-z0-9.%]+', ' ', 'g')) $$;

-- Jeton de dosage d'un texte normalisé (« 500mg », « 0.5g », ou seulement « 500 ») ; NULL s'il n'y en a pas.
CREATE OR REPLACE FUNCTION public.jeton_dosage(p_norm text) RETURNS text
LANGUAGE sql IMMUTABLE
AS $$ SELECT COALESCE(
        (regexp_match(p_norm, '(\d+(?:\.\d+)?(?:mg|ml|g|mcg|ug|µg|ui|iu|%))'))[1],
        (regexp_match(p_norm, '(?:^|\s)(\d+(?:\.\d+)?)\s*$'))[1]) $$;

-- Compatibilité de deux dosages normalisés : 2 identiques ; 1 nombre seul qui figure dans l'autre ; 0 inconnu d'un côté ; -1 en conflit.
CREATE OR REPLACE FUNCTION public.dosages_compatibles(p_ligne text, p_fiche text) RETURNS integer
LANGUAGE sql IMMUTABLE
AS $$ SELECT CASE
        WHEN coalesce(p_ligne, '') = '' OR coalesce(p_fiche, '') = '' THEN 0
        WHEN replace(p_ligne, ' ', '') = replace(p_fiche, ' ', '') THEN 2
        -- ligne sans unité (« 500 », « 20 120 ») : mêmes nombres que la fiche
        WHEN p_ligne !~ '[a-z%µ]' AND btrim(regexp_replace(p_ligne, '\s+', ' ', 'g')) = btrim(regexp_replace(regexp_replace(p_fiche, '[a-z%µ]+', ' ', 'g'), '\s+', ' ', 'g')) THEN 1
        -- un seul nombre sans unité qui figure dans l'autre dosage
        WHEN p_ligne ~ '^\d+(\.\d+)?$' AND p_ligne = ANY (regexp_split_to_array(btrim(regexp_replace(p_fiche, '[a-z%µ]+', ' ', 'g')), '\s+')) THEN 1
        WHEN p_fiche ~ '^\d+(\.\d+)?$' AND p_fiche = ANY (regexp_split_to_array(btrim(regexp_replace(p_ligne, '[a-z%µ]+', ' ', 'g')), '\s+')) THEN 1
        ELSE -1 END $$;

REVOKE ALL ON FUNCTION public.normaliser_texte_medicament(text), public.jeton_dosage(text), public.dosages_compatibles(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.normaliser_texte_medicament(text), public.jeton_dosage(text), public.dosages_compatibles(text, text) TO authenticated;

-- ── 3. Aides d'accès ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.lot_du_pharmacien(p_lot uuid, p_verrou boolean DEFAULT false) RETURNS public.lots_import
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE v_ph uuid := public.exiger_pharmacien_interne(); l public.lots_import%ROWTYPE;
BEGIN
    IF p_verrou THEN SELECT * INTO l FROM public.lots_import WHERE id = p_lot AND pharmacie_id = v_ph FOR UPDATE;
    ELSE SELECT * INTO l FROM public.lots_import WHERE id = p_lot AND pharmacie_id = v_ph; END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'Import introuvable' USING ERRCODE = 'P0002'; END IF;
    RETURN l;
END $f$;
REVOKE ALL ON FUNCTION public.lot_du_pharmacien(uuid, boolean) FROM PUBLIC, anon, authenticated;

-- Libellé lisible d'une fiche du catalogue.
CREATE OR REPLACE FUNCTION public.libelle_fiche(m public.medicaments) RETURNS text
LANGUAGE sql IMMUTABLE
AS $$ SELECT btrim(concat_ws(' ', coalesce(m.nom_commercial, m.nom), m.dosage, CASE WHEN m.forme IS NOT NULL THEN '(' || m.forme || ')' END)) $$;
REVOKE ALL ON FUNCTION public.libelle_fiche(public.medicaments) FROM PUBLIC, anon, authenticated;

-- ── 4. Création du lot, ajout de lignes par paquets (limite de durée des requêtes), finalisation ──
CREATE OR REPLACE FUNCTION public.import_creer_lot(p_nom_fichier text, p_mode text DEFAULT 'merge') RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE v_ph uuid := public.exiger_pharmacien_interne(); v_id uuid;
BEGIN
    IF p_mode NOT IN ('merge', 'replace') THEN RAISE EXCEPTION 'Mode inconnu' USING ERRCODE = '22023'; END IF;
    IF char_length(btrim(coalesce(p_nom_fichier, ''))) = 0 THEN RAISE EXCEPTION 'Nom de fichier obligatoire' USING ERRCODE = '22023'; END IF;
    IF (SELECT count(*) FROM public.lots_import WHERE pharmacie_id = v_ph AND cree_le > now() - interval '1 hour') >= 20 THEN
        RAISE EXCEPTION 'Trop d''imports démarrés : réessayez plus tard' USING ERRCODE = '54000';
    END IF;
    INSERT INTO public.lots_import (pharmacie_id, auteur_id, nom_fichier, mode) VALUES (v_ph, auth.uid(), left(btrim(p_nom_fichier), 200), p_mode) RETURNING id INTO v_id;
    RETURN v_id;
END $f$;

-- Chaque ligne : { numero, nom, dosage, conditionnement, prix_brut, prix, en_stock, en_stock_invalide }. 500 lignes au plus par appel, 5 000 par lot.
CREATE OR REPLACE FUNCTION public.import_ajouter_lignes(p_lot uuid, p_lignes jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE
    l public.lots_import%ROWTYPE := public.lot_du_pharmacien(p_lot, true);
    r record;
    v_n int;
    v_nom text; v_dos_norm text; v_nom_norm text; v_nom_sans text; v_hint text;
    v_pb jsonb; v_prob jsonb; v_cand jsonb; v_etat text; v_med uuid; v_conf numeric; v_meth text; v_res text;
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
    CREATE TEMP TABLE IF NOT EXISTS _cles_catalogue (medicament_id uuid, cle text, dosage text) ON COMMIT DROP;
    DELETE FROM _cles_catalogue;
    INSERT INTO _cles_catalogue
    SELECT m.id, k.cle, public.normaliser_texte_medicament(m.dosage)
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
                               max(CASE WHEN k.cle = v_nom_sans AND d.c >= 1 THEN 1.0
                                        ELSE LEAST(1.0, GREATEST(similarity(k.cle, v_nom_sans), similarity(k.cle, v_nom_norm))
                                             * CASE d.c WHEN 2 THEN 1.0 WHEN 1 THEN 0.97 WHEN 0 THEN 0.9 ELSE 0.55 END
                                             + CASE WHEN d.c = 2 THEN 0.08 ELSE 0 END) END) AS score,
                               bool_or(k.cle = v_nom_sans AND d.c >= 1) AS exact
                          FROM _cles_catalogue k
                          CROSS JOIN LATERAL (SELECT public.dosages_compatibles(v_dos_norm, k.dosage) AS c) d
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

        IF jsonb_path_exists(v_prob, '$[*] ? (@.niveau == "bloquant")') THEN v_etat := 'erreur'; v_med := NULL; v_conf := NULL; v_meth := 'none';
        ELSIF v_etat IN ('reconnu', 'suggestion') THEN v_res := 'accepted'; END IF;

        INSERT INTO public.lignes_import (lot_id, numero, brut, prix, en_stock, medicament_id, confiance, methode, etat, problemes, candidats, resolution)
        VALUES (p_lot, r.numero, v_pb, CASE WHEN r.prix IS NOT NULL AND r.prix = trunc(r.prix) AND r.prix BETWEEN 1 AND 500000 THEN r.prix::int END,
                COALESCE(r.en_stock, true), v_med, v_conf, v_meth, v_etat, v_prob, v_cand, v_res);
    END LOOP;
    RETURN jsonb_build_object('lignes', (SELECT count(*) FROM public.lignes_import WHERE lot_id = p_lot));
END $f$;

-- Doublons : plusieurs lignes acceptées pour la même fiche -> la dernière l'emporte (les autres sont ignorées, avec avertissement).
CREATE OR REPLACE FUNCTION public.dedoublonner_lot_interne(p_lot uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
    UPDATE public.lignes_import li
       SET resolution = 'skipped',
           problemes = li.problemes || jsonb_build_object('code', 'doublon_fichier', 'niveau', 'avertissement', 'detail', 'une ligne plus bas concerne le même médicament')
     FROM (SELECT lot_id, numero, row_number() OVER (PARTITION BY medicament_id ORDER BY numero DESC) AS rang
             FROM public.lignes_import WHERE lot_id = p_lot AND medicament_id IS NOT NULL AND resolution IN ('accepted', 'mapped_manually') AND etat <> 'erreur') d
    WHERE li.lot_id = d.lot_id AND li.numero = d.numero AND d.rang > 1 $$;
REVOKE ALL ON FUNCTION public.dedoublonner_lot_interne(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.import_compter_interne(p_lot uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT jsonb_build_object(
        'total', count(*), 'reconnu', count(*) FILTER (WHERE etat = 'reconnu'), 'suggestion', count(*) FILTER (WHERE etat = 'suggestion'),
        'a_confirmer', count(*) FILTER (WHERE etat = 'a_confirmer' AND resolution IS DISTINCT FROM 'mapped_manually' AND resolution IS DISTINCT FROM 'accepted'),
        'non_reconnu', count(*) FILTER (WHERE etat = 'non_reconnu' AND resolution IS DISTINCT FROM 'mapped_manually'),
        'erreur', count(*) FILTER (WHERE etat = 'erreur'),
        'a_ecrire', count(*) FILTER (WHERE resolution IN ('accepted', 'mapped_manually') AND medicament_id IS NOT NULL AND etat <> 'erreur'),
        'avertissements', count(*) FILTER (WHERE jsonb_path_exists(problemes, '$[*] ? (@.niveau == "avertissement")'))) FROM public.lignes_import WHERE lot_id = p_lot $$;
REVOKE ALL ON FUNCTION public.import_compter_interne(uuid) FROM PUBLIC, anon, authenticated;

-- Finalisation : doublons, écarts de prix (> 50 % de la médiane des AUTRES pharmacies, si ≥ 5 en ont), passage à « previewed ».
CREATE OR REPLACE FUNCTION public.import_finaliser_lot(p_lot uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE l public.lots_import%ROWTYPE := public.lot_du_pharmacien(p_lot, true);
BEGIN
    IF l.statut NOT IN ('parsed', 'previewed') THEN RAISE EXCEPTION 'Import déjà traité' USING ERRCODE = '55000'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.lignes_import WHERE lot_id = p_lot) THEN RAISE EXCEPTION 'Le fichier ne contient aucune ligne exploitable' USING ERRCODE = '55000'; END IF;
    PERFORM public.dedoublonner_lot_interne(p_lot);
    UPDATE public.lignes_import li
       SET problemes = li.problemes || jsonb_build_object('code', 'prix_ecart_median', 'niveau', 'avertissement', 'detail', 'médiane des autres pharmacies : ' || m.mediane || ' FCFA')
      FROM (SELECT s.medicament_id, round(percentile_cont(0.5) WITHIN GROUP (ORDER BY s.prix_fcfa))::int AS mediane, count(*) AS n
              FROM public.stocks s WHERE s.pharmacie_id <> l.pharmacie_id AND s.statut_stock <> 'archive' AND s.prix_fcfa > 0
               AND s.medicament_id IN (SELECT medicament_id FROM public.lignes_import WHERE lot_id = p_lot AND medicament_id IS NOT NULL)
             GROUP BY s.medicament_id HAVING count(*) >= 5) m
     WHERE li.lot_id = p_lot AND li.medicament_id = m.medicament_id AND li.prix IS NOT NULL AND m.mediane > 0
       AND abs(li.prix - m.mediane) > 0.5 * m.mediane
       AND NOT jsonb_path_exists(li.problemes, '$[*] ? (@.code == "prix_ecart_median")');
    UPDATE public.lots_import SET statut = 'previewed', compteurs = public.import_compter_interne(p_lot) WHERE id = p_lot;
    RETURN public.import_compter_interne(p_lot);
END $f$;

-- ── 5. Aperçu et corrections ──────────────────────────────────────────
-- Filtres : tous | reconnu | a_confirmer | non_reconnu | erreur | avertissement
CREATE OR REPLACE FUNCTION public.import_lire_lot(p_lot uuid, p_filtre text DEFAULT 'tous', p_limite int DEFAULT 100, p_decalage int DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE l public.lots_import%ROWTYPE := public.lot_du_pharmacien(p_lot);
BEGIN
    RETURN jsonb_build_object(
        'lot', jsonb_build_object('id', l.id, 'nom_fichier', l.nom_fichier, 'mode', l.mode, 'statut', l.statut, 'cree_le', l.cree_le, 'valide_le', l.valide_le),
        'compteurs', public.import_compter_interne(p_lot),
        'lignes', COALESCE((SELECT jsonb_agg(jsonb_build_object('numero', li.numero, 'brut', li.brut, 'prix', li.prix, 'en_stock', li.en_stock, 'etat', li.etat,
                  'confiance', li.confiance, 'methode', li.methode, 'problemes', li.problemes, 'candidats', li.candidats, 'resolution', li.resolution,
                  'medicament', CASE WHEN li.medicament_id IS NOT NULL THEN (SELECT public.libelle_fiche(m) FROM public.medicaments m WHERE m.id = li.medicament_id) END,
                  'medicament_id', li.medicament_id) ORDER BY li.numero)
              FROM (SELECT * FROM public.lignes_import x WHERE x.lot_id = p_lot
                      AND (p_filtre = 'tous' OR (p_filtre = 'reconnu' AND x.etat IN ('reconnu', 'suggestion')) OR (p_filtre = 'a_confirmer' AND x.etat = 'a_confirmer')
                           OR (p_filtre = 'non_reconnu' AND x.etat = 'non_reconnu') OR (p_filtre = 'erreur' AND x.etat = 'erreur')
                           OR (p_filtre = 'avertissement' AND jsonb_path_exists(x.problemes, '$[*] ? (@.niveau == "avertissement")')))
                     ORDER BY x.numero OFFSET GREATEST(p_decalage, 0) LIMIT LEAST(GREATEST(p_limite, 1), 500)) li), '[]'::jsonb));
END $f$;

-- Actions : accepter (la suggestion), mapper (choix manuel d'une fiche), ignorer.
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
        UPDATE public.lignes_import SET medicament_id = p_medicament, methode = 'manual', confiance = 1.00, resolution = 'mapped_manually' WHERE lot_id = p_lot AND numero = p_numero;
    ELSE RAISE EXCEPTION 'Action inconnue' USING ERRCODE = '22023'; END IF;
    UPDATE public.lots_import SET statut = 'parsed' WHERE id = p_lot AND statut = 'previewed';   -- toute correction demande une nouvelle finalisation
    RETURN public.import_compter_interne(p_lot);
END $f$;

CREATE OR REPLACE FUNCTION public.import_chercher_catalogue(p_q text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE v text := public.normaliser_texte_medicament(p_q);
BEGIN
    PERFORM public.exiger_pharmacien_interne();
    IF char_length(v) < 2 THEN RETURN '[]'::jsonb; END IF;
    RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'libelle', t.libelle, 'restreint', t.restreint) ORDER BY t.rang, t.libelle)
        FROM (SELECT m.id, public.libelle_fiche(m) AS libelle, m.restreint,
                     greatest(similarity(public.normaliser_texte_medicament(m.nom), v), similarity(public.normaliser_texte_medicament(m.nom_commercial), v)) AS rang
                FROM public.medicaments m
               WHERE m.statut_catalogue = 'actif' AND (public.normaliser_texte_medicament(m.nom || ' ' || coalesce(m.nom_commercial, '') || ' ' || coalesce(m.dosage, '')) LIKE '%' || replace(v, ' ', '%') || '%')
               ORDER BY 4 DESC, 2 LIMIT 15) t), '[]'::jsonb);
END $f$;

-- Demande d'ajout d'un produit inconnu au catalogue (jamais d'ajout automatique : le catalogue est sous contrôle de l'admin).
CREATE OR REPLACE FUNCTION public.import_demander_ajout(p_lot uuid, p_numero int) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE l public.lots_import%ROWTYPE := public.lot_du_pharmacien(p_lot); li public.lignes_import%ROWTYPE;
BEGIN
    SELECT * INTO li FROM public.lignes_import WHERE lot_id = p_lot AND numero = p_numero;
    IF NOT FOUND THEN RAISE EXCEPTION 'Ligne introuvable' USING ERRCODE = 'P0002'; END IF;
    IF li.etat <> 'non_reconnu' THEN RAISE EXCEPTION 'Seuls les produits non reconnus peuvent être demandés' USING ERRCODE = '55000'; END IF;
    IF EXISTS (SELECT 1 FROM public.demandes_catalogue d WHERE d.pharmacie_id = l.pharmacie_id AND d.statut = 'ouverte' AND lower(d.nom_brut) = lower(li.brut ->> 'nom') AND coalesce(d.dosage_brut, '') = coalesce(li.brut ->> 'dosage', '')) THEN RETURN; END IF;
    INSERT INTO public.demandes_catalogue (pharmacie_id, nom_brut, dosage_brut) VALUES (l.pharmacie_id, left(li.brut ->> 'nom', 200), NULLIF(left(li.brut ->> 'dosage', 100), ''));
END $f$;

CREATE OR REPLACE FUNCTION public.import_abandonner_lot(p_lot uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE l public.lots_import%ROWTYPE := public.lot_du_pharmacien(p_lot, true);
BEGIN
    IF l.statut NOT IN ('parsed', 'previewed') THEN RAISE EXCEPTION 'Seul un import non validé peut être abandonné' USING ERRCODE = '55000'; END IF;
    UPDATE public.lots_import SET statut = 'failed' WHERE id = p_lot;
    DELETE FROM public.lignes_import WHERE lot_id = p_lot;      -- aucune donnée de fichier conservée pour un import abandonné
END $f$;

-- ── 6. Validation : une seule transaction ─────────────────────────────
CREATE OR REPLACE FUNCTION public.import_valider_lot(p_lot uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $f$
DECLARE
    l public.lots_import%ROWTYPE := public.lot_du_pharmacien(p_lot, true);
    v_crees int; v_maj int; v_arch int := 0; v_ignores int; v_publiee boolean;
BEGIN
    IF l.statut <> 'previewed' THEN RAISE EXCEPTION 'L''aperçu doit être finalisé avant la validation' USING ERRCODE = '55000'; END IF;
    PERFORM public.dedoublonner_lot_interne(p_lot);
    DROP TABLE IF EXISTS _a_ecrire;
    CREATE TEMP TABLE _a_ecrire ON COMMIT DROP AS
    SELECT li.numero, li.medicament_id, li.prix, li.en_stock FROM public.lignes_import li
      JOIN public.medicaments m ON m.id = li.medicament_id AND m.statut_catalogue = 'actif'
     WHERE li.lot_id = p_lot AND li.resolution IN ('accepted', 'mapped_manually') AND li.etat <> 'erreur' AND li.prix BETWEEN 1 AND 500000;
    IF NOT EXISTS (SELECT 1 FROM _a_ecrire) THEN RAISE EXCEPTION 'Aucune ligne à écrire : acceptez ou corrigez au moins une ligne' USING ERRCODE = '55000'; END IF;

    -- État précédent (annulation)
    UPDATE public.lignes_import li SET valeur_prec = COALESCE(
        (SELECT jsonb_build_object('existait', true, 'prix_fcfa', s.prix_fcfa, 'en_stock', s.en_stock, 'statut_stock', s.statut_stock, 'date_maj', s.date_maj,
                                   'confirme_le', s.confirme_le, 'source', s.source, 'mis_a_jour_par', s.mis_a_jour_par)
           FROM public.stocks s WHERE s.pharmacie_id = l.pharmacie_id AND s.medicament_id = li.medicament_id),
        jsonb_build_object('existait', false))
      FROM _a_ecrire e WHERE li.lot_id = p_lot AND li.numero = e.numero;

    -- Écriture
    WITH maj AS (
        INSERT INTO public.stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock, date_maj, source, mis_a_jour_par)
        SELECT l.pharmacie_id, e.medicament_id, e.prix, e.en_stock, now(), 'pharmacien', auth.uid() FROM _a_ecrire e
        ON CONFLICT (pharmacie_id, medicament_id) DO UPDATE SET
            prix_fcfa = EXCLUDED.prix_fcfa, en_stock = EXCLUDED.en_stock,
            statut_stock = CASE WHEN NOT EXCLUDED.en_stock THEN 'rupture' WHEN public.stocks.statut_stock = 'faible' THEN 'faible' ELSE 'en_stock' END,
            date_maj = EXCLUDED.date_maj, source = 'pharmacien', mis_a_jour_par = EXCLUDED.mis_a_jour_par
        RETURNING medicament_id, prix_fcfa, en_stock, statut_stock, date_maj, (xmax = 0) AS cree)
    UPDATE public.lignes_import li SET valeur_nouv = jsonb_build_object('prix_fcfa', m.prix_fcfa, 'statut_stock', m.statut_stock, 'date_maj', m.date_maj)
      FROM maj m, _a_ecrire e WHERE li.lot_id = p_lot AND li.numero = e.numero AND e.medicament_id = m.medicament_id;
    SELECT count(*) FILTER (WHERE NOT (valeur_prec ->> 'existait')::boolean), count(*) FILTER (WHERE (valeur_prec ->> 'existait')::boolean)
      INTO v_crees, v_maj FROM public.lignes_import WHERE lot_id = p_lot AND valeur_nouv IS NOT NULL;

    -- Mode « Remplacer tout mon stock » : les absents du fichier passent en archivé (restaurables)
    IF l.mode = 'replace' THEN
        INSERT INTO public.lots_import_archives (lot_id, stock_id, valeur_prec)
        SELECT p_lot, s.id, jsonb_build_object('statut_stock', s.statut_stock, 'en_stock', s.en_stock)
          FROM public.stocks s WHERE s.pharmacie_id = l.pharmacie_id AND s.statut_stock <> 'archive' AND s.medicament_id NOT IN (SELECT medicament_id FROM _a_ecrire);
        UPDATE public.stocks s SET statut_stock = 'archive' WHERE s.id IN (SELECT stock_id FROM public.lots_import_archives WHERE lot_id = p_lot);
        GET DIAGNOSTICS v_arch = ROW_COUNT;
    END IF;

    SELECT count(*) INTO v_ignores FROM public.lignes_import WHERE lot_id = p_lot AND valeur_nouv IS NULL;
    UPDATE public.lots_import SET statut = 'committed', valide_le = now(),
        compteurs = public.import_compter_interne(p_lot) || jsonb_build_object('crees', v_crees, 'mis_a_jour', v_maj, 'ignores', v_ignores, 'archives', v_arch) WHERE id = p_lot;
    PERFORM public.journaliser_onboarding(NULL, l.pharmacie_id, auth.uid(), 'pharmacy', 'import_valide', jsonb_build_object('lot', p_lot, 'crees', v_crees, 'mis_a_jour', v_maj, 'archives', v_arch));
    v_publiee := public.evaluer_publication_interne(l.pharmacie_id);
    RETURN jsonb_build_object('crees', v_crees, 'mis_a_jour', v_maj, 'ignores', v_ignores, 'archives', v_arch, 'publiee', v_publiee, 'annulable_jusqu_a', now() + interval '24 hours');
END $f$;

-- ── 7. Annulation sous 24 h : restaure les valeurs précédentes (sauf lignes modifiées depuis) ──
CREATE OR REPLACE FUNCTION public.import_annuler_lot(p_lot uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE
    l public.lots_import%ROWTYPE := public.lot_du_pharmacien(p_lot, true);
    v_suppr int; v_rest int; v_arch int; v_conflits int;
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
    RETURN jsonb_build_object('supprimes', v_suppr, 'restaures', v_rest, 'archives_restaures', v_arch, 'modifies_depuis', v_conflits);
END $f$;

-- ── 8. Historique ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.import_historique() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $f$
DECLARE v_ph uuid := public.exiger_pharmacien_interne();
BEGIN
    RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', l.id, 'nom_fichier', l.nom_fichier, 'mode', l.mode, 'statut', l.statut, 'cree_le', l.cree_le,
              'valide_le', l.valide_le, 'annule_le', l.annule_le, 'compteurs', l.compteurs, 'auteur_moi', l.auteur_id = auth.uid(),
              'annulable', l.statut = 'committed' AND l.valide_le > now() - interval '24 hours') ORDER BY l.cree_le DESC)
        FROM (SELECT * FROM public.lots_import WHERE pharmacie_id = v_ph AND statut <> 'failed' ORDER BY cree_le DESC LIMIT 50) l), '[]'::jsonb);
END $f$;

-- ── 9. Tâche d'onboarding « Importer mes stocks » : au moins 1 import validé (SPEC 1 §5 tâche 4) ──

CREATE OR REPLACE FUNCTION public.calculer_onboarding(p_pharmacie uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $f$
DECLARE
    ph public.pharmacies%ROWTYPE;
    e jsonb;
    v_min int := COALESCE((SELECT (valeur #>> '{}')::int FROM public.config_routage WHERE cle = 'publication_min_items_frais'), 10);
    v_jours numeric := COALESCE((SELECT (valeur #>> '{}')::numeric FROM public.config_routage WHERE cle = 'publication_fraicheur_jours'), 7);
    v_stocks int;
    v_frais int;
    v_telegram boolean;
    v_items jsonb;
    v_faits int;
BEGIN
    SELECT * INTO ph FROM public.pharmacies WHERE id = p_pharmacie;
    IF NOT FOUND THEN RETURN NULL; END IF;
    e := COALESCE((SELECT etat FROM public.etat_onboarding_pharmacie WHERE pharmacie_id = p_pharmacie), '{}');
    SELECT count(*), count(*) FILTER (WHERE confirme_le > now() - make_interval(secs => v_jours * 86400))
      INTO v_stocks, v_frais FROM public.stocks WHERE pharmacie_id = p_pharmacie AND statut_stock <> 'archive';
    v_telegram := EXISTS (SELECT 1 FROM public.contacts_pharmacie c WHERE c.pharmacie_id = p_pharmacie AND c.canal = 'telegram'
                          AND c.verifie_le IS NOT NULL AND c.desabonne_le IS NULL AND c.bloque_le IS NULL);
    v_items := jsonb_build_array(
        jsonb_build_object('cle', 'mot_de_passe', 'fait', e ->> 'mot_de_passe_defini_le' IS NOT NULL),
        jsonb_build_object('cle', 'ma_pharmacie', 'fait', e ->> 'gps_confirme_le' IS NOT NULL AND ph.latitude IS NOT NULL AND ph.longitude IS NOT NULL
                                                         AND ph.horaires IS NOT NULL AND ph.horaires <> '{}'::jsonb AND ph.horaires <> 'null'::jsonb,
                           'horaires', ph.horaires IS NOT NULL AND ph.horaires <> '{}'::jsonb AND ph.horaires <> 'null'::jsonb,
                           'gps_present', ph.latitude IS NOT NULL AND ph.longitude IS NOT NULL, 'gps_confirme', e ->> 'gps_confirme_le' IS NOT NULL),
        jsonb_build_object('cle', 'telegram', 'fait', v_telegram OR e ->> 'sans_telegram_le' IS NOT NULL, 'telegram_actif', v_telegram,
                           'sans_telegram', e ->> 'sans_telegram_le' IS NOT NULL),
        -- Au moins un import validé (et non annulé) ; `nb_stocks` reste informatif.
        jsonb_build_object('cle', 'import', 'fait', EXISTS (SELECT 1 FROM public.lots_import WHERE pharmacie_id = p_pharmacie AND statut = 'committed'), 'nb_stocks', v_stocks),
        jsonb_build_object('cle', 'confirmation', 'fait', e ->> 'stocks_confirmes_le' IS NOT NULL),
        jsonb_build_object('cle', 'seuil', 'fait', v_frais >= v_min, 'items_frais', v_frais, 'min_items_frais', v_min));
    SELECT count(*) INTO v_faits FROM jsonb_array_elements(v_items) i WHERE (i ->> 'fait')::boolean;
    RETURN jsonb_build_object('items', v_items, 'faits', v_faits, 'total', 6, 'statut', ph.statut, 'est_publiee', ph.est_publiee,
        'publiable', ph.statut = 'verifie' AND v_faits = 6, 'fraicheur_jours', v_jours, 'min_items_frais', v_min, 'items_frais', v_frais);
END $f$;

-- ── 10. Droits d'exécution ────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.import_creer_lot(text, text), public.import_ajouter_lignes(uuid, jsonb), public.import_finaliser_lot(uuid),
    public.import_lire_lot(uuid, text, int, int), public.import_corriger_ligne(uuid, int, text, uuid), public.import_chercher_catalogue(text),
    public.import_demander_ajout(uuid, int), public.import_abandonner_lot(uuid), public.import_valider_lot(uuid), public.import_annuler_lot(uuid),
    public.import_historique() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.import_creer_lot(text, text), public.import_ajouter_lignes(uuid, jsonb), public.import_finaliser_lot(uuid),
    public.import_lire_lot(uuid, text, int, int), public.import_corriger_ligne(uuid, int, text, uuid), public.import_chercher_catalogue(text),
    public.import_demander_ajout(uuid, int), public.import_abandonner_lot(uuid), public.import_valider_lot(uuid), public.import_annuler_lot(uuid),
    public.import_historique() TO authenticated;

COMMIT;
