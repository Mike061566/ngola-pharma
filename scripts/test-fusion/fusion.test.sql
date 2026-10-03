-- Test de la migration de fusion et de son retour arrière, sur données synthétiques.
-- Lancé par scripts/test-fusion.sh (variables psql : migration, rollback = fichiers sans BEGIN/COMMIT).
-- TOUT est annulé en fin de test (ROLLBACK). Résultat lu par le script shell : lignes « TEST OK » / « ERREUR TEST ».
\set ON_ERROR_STOP off
\pset pager off
BEGIN;

CREATE FUNCTION pg_temp.verifie(ok boolean, nom text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF ok IS TRUE THEN RAISE NOTICE 'TEST OK : %', nom; ELSE RAISE WARNING 'ERREUR TEST : %', nom; END IF;
END $$;

-- Empreinte de l'état (fiches, stocks, alertes)
CREATE FUNCTION pg_temp.empreinte() RETURNS text LANGUAGE sql AS $$
    SELECT md5(coalesce((SELECT string_agg(m::text, '|' ORDER BY m.id) FROM public.medicaments m), '')) || '/' ||
           md5(coalesce((SELECT string_agg(s::text, '|' ORDER BY s.id) FROM public.stocks s), '')) || '/' ||
           md5(coalesce((SELECT string_agg(a::text, '|' ORDER BY a.id) FROM public.alertes_stock a), ''))
$$;

\ir fixture.sql
CREATE TEMP TABLE _etat AS SELECT pg_temp.empreinte() AS avant, (SELECT count(*) FROM public.medicaments) AS fiches, (SELECT count(*) FROM public.stocks) AS stocks;

-- ═══ 1. Fusion : chemin nominal ═══
SAVEPOINT nominal;
\i :migration
SELECT pg_temp.verifie((SELECT count(*) FROM public.medicaments) = (SELECT fiches FROM _etat) - 5, 'fusion : 5 fiches supprimées');
SELECT pg_temp.verifie((SELECT count(*) FROM public.stocks) = (SELECT stocks FROM _etat) - 4, 'fusion : 4 lignes de stock supprimées');
SELECT pg_temp.verifie(
    (SELECT count(*) FROM sauvegarde_fusion.stocks_avant WHERE action = 'deplace') = 1 AND
    (SELECT count(*) FROM sauvegarde_fusion.stocks_avant WHERE action = 'supprime') = 4 AND
    (SELECT count(*) FROM sauvegarde_fusion.stocks_avant WHERE action = 'mis_a_jour') = 2 AND
    (SELECT count(*) FROM sauvegarde_fusion.alertes_avant) = 1,
    'fusion : sauvegarde = 1 déplacé, 4 supprimés, 2 remplacés, 1 alerte');

-- Ma pharmacie : Coartem 5100 en stock, Chloroquine 1500 en stock (une seule ligne par produit)
SELECT pg_temp.verifie((SELECT count(*) FROM public.stocks s JOIN public.medicaments m ON m.id = s.medicament_id
    WHERE s.pharmacie_id = '76beb7c3-0000-0000-0000-000000000001' AND m.nom_commercial = 'Coartem') = 1
  AND (SELECT s.prix_fcfa || '/' || s.en_stock FROM public.stocks s JOIN public.medicaments m ON m.id = s.medicament_id
    WHERE s.pharmacie_id = '76beb7c3-0000-0000-0000-000000000001' AND m.nom_commercial = 'Coartem') = '5100/true',
    'Ma pharmacie : Coartem 5100 en stock, une ligne');
SELECT pg_temp.verifie((SELECT count(*) FROM public.stocks s JOIN public.medicaments m ON m.id = s.medicament_id
    WHERE s.pharmacie_id = '76beb7c3-0000-0000-0000-000000000001' AND m.dci = 'Chloroquine') = 1
  AND (SELECT s.prix_fcfa || '/' || s.en_stock FROM public.stocks s JOIN public.medicaments m ON m.id = s.medicament_id
    WHERE s.pharmacie_id = '76beb7c3-0000-0000-0000-000000000001' AND m.dci = 'Chloroquine') = '1500/true',
    'Ma pharmacie : Chloroquine 1500 en stock, une ligne');
-- Égalité de date : la ligne « en stock » gagne
SELECT pg_temp.verifie((SELECT s.prix_fcfa || '/' || s.en_stock FROM public.stocks s JOIN public.medicaments m ON m.id = s.medicament_id
    WHERE s.pharmacie_id = '76beb7c3-0000-0000-0000-000000000002' AND m.dci = 'Chloroquine') = '1700/true',
    'Pharmacie B : égalité de date, la ligne en stock gagne');
-- Déplacement sur la fiche gardée (c1 : la plus ancienne à égalité de stocks)
SELECT pg_temp.verifie((SELECT s.prix_fcfa || '/' || s.medicament_id FROM public.stocks s
    WHERE s.pharmacie_id = '76beb7c3-0000-0000-0000-000000000003' AND s.medicament_id = '00000000-0000-0000-0000-0000000000c1')
    = '900/00000000-0000-0000-0000-0000000000c1', 'Pharmacie C : la ligne la plus récente (900) est déplacée sur la fiche gardée');
-- Fiche voisine non fusionnée
SELECT pg_temp.verifie((SELECT prix_fcfa FROM public.stocks WHERE medicament_id = '00000000-0000-0000-0000-0000000000e1') = 1000
    AND EXISTS (SELECT 1 FROM public.medicaments WHERE id = '00000000-0000-0000-0000-0000000000e1'), 'Efferalgan (autre marque) intact');
-- Alerte rattachée
SELECT pg_temp.verifie((SELECT medicament_id FROM public.alertes_stock WHERE id = '00000000-0000-0000-0000-00000000aa01')
    = '00000000-0000-0000-0000-0000000000d1', 'alerte Ibuprofène rattachée à la fiche gardée');
SELECT pg_temp.verifie((SELECT medicament_id IS NULL FROM public.alertes_stock WHERE id = '00000000-0000-0000-0000-00000000aa02')
    AND (SELECT count(*) FROM public.alertes_stock) = 2, 'alerte sans fiche : intacte, aucune alerte perdue');
-- Unicité
SELECT pg_temp.verifie(to_regclass('public.uq_medicaments_nom_dosage') IS NOT NULL, 'index unique présent');
SAVEPOINT apres_unicite;
INSERT INTO public.medicaments (nom, dosage) VALUES ('  ZZ Nom ', NULL);   -- 'zz nom' / '' : libre
SAVEPOINT doublon_nom;
INSERT INTO public.medicaments (nom, dosage) VALUES ('zz nom', '');       -- même nom normalisé, dosage vide : doit échouer
ROLLBACK TO SAVEPOINT doublon_nom;
SELECT pg_temp.verifie((SELECT count(*) FROM public.medicaments WHERE lower(btrim(nom)) = 'zz nom') = 1,
    'unicité : un nom en double (casse, espaces, dosage vide) est refusé');
ROLLBACK TO SAVEPOINT apres_unicite;

-- ═══ 2. Retour arrière : état identique à l'avant-fusion ═══
\i :rollback
SELECT pg_temp.verifie(pg_temp.empreinte() = (SELECT avant FROM _etat), 'retour arrière : fiches, stocks et alertes strictement identiques à l''état initial');
SELECT pg_temp.verifie(to_regclass('public.uq_medicaments_nom_dosage') IS NULL, 'retour arrière : index unique retiré');
ROLLBACK TO SAVEPOINT nominal;
SELECT pg_temp.verifie(pg_temp.empreinte() = (SELECT avant FROM _etat), 'état initial retrouvé après annulation du bloc de test');

-- ═══ 3. Garde-fou : une autre clé étrangère vers medicaments fait échouer la migration, sans rien modifier ═══
SAVEPOINT garde_fk;
CREATE TABLE public.zz_reference_medicament (med_id uuid REFERENCES public.medicaments(id));
\i :migration
ROLLBACK TO SAVEPOINT garde_fk;
SELECT pg_temp.verifie(pg_temp.empreinte() = (SELECT avant FROM _etat) AND to_regclass('sauvegarde_fusion.stocks_avant') IS NOT NULL
    AND (SELECT count(*) FROM sauvegarde_fusion.medicaments_supprimes) = 0, 'garde-fou FK : échec, aucune donnée modifiée');

-- ═══ 4. Index unique impossible : la migration échoue en entier ═══
SAVEPOINT index_impossible;
DROP INDEX IF EXISTS public.uq_medicaments_nom_dosage;
INSERT INTO public.medicaments (nom, nom_commercial, dci, dosage, forme) VALUES
    ('Zz Produit', 'm1', 'dci-un', '10mg', 'Comprimé'), ('zz produit', 'm2', 'dci-deux', '10 mg', 'Sirop');
\i :migration
ROLLBACK TO SAVEPOINT index_impossible;
SELECT pg_temp.verifie(pg_temp.empreinte() = (SELECT avant FROM _etat), 'index impossible : migration annulée en entier');

-- ═══ 5. Contrôle final : une anomalie annule TOUTE la transaction ═══
-- Un trigger fait disparaître une alerte pendant la fusion : le contrôle « aucune alerte perdue » doit tout annuler.
SAVEPOINT controle_final;
CREATE FUNCTION public.zz_supprime_alerte() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN DELETE FROM public.alertes_stock WHERE id = OLD.id; RETURN NULL; END $$;
CREATE TRIGGER zz_trigger AFTER UPDATE ON public.alertes_stock FOR EACH ROW EXECUTE FUNCTION public.zz_supprime_alerte();
\i :migration
ROLLBACK TO SAVEPOINT controle_final;
SELECT pg_temp.verifie(pg_temp.empreinte() = (SELECT avant FROM _etat), 'contrôle final : anomalie détectée, fusion annulée en entier');

ROLLBACK;
