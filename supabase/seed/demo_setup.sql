-- ============================================================
-- N'Gola Pharma — Données de démonstration (développement / démo uniquement)
-- 7 quartiers, 3 pharmacies, 20 médicaments, stocks. À exécuter à la main APRÈS la baseline
-- sur une base de développement. JAMAIS en production (les données réelles y existent déjà).
-- ============================================================

-- ============================================================
-- ÉTAPE 6 : DONNÉES DE DÉMO — À SUPPRIMER/REMPLACER POUR UN VRAI CLIENT
-- ============================================================
-- Cette section reprend les données de démo de Yaoundé (7 quartiers,
-- 52 pharmacies, 20 médicaments, stocks factices) de setup_complet.sql.
-- Pour un vrai client, commenter/supprimer ce bloc et importer les
-- vraies données (voir étape 5 du RUNBOOK_DEPLOIEMENT_CLIENT.md :
-- npm run seed avec les CSV du client, ou INSERT adaptés).

-- Quartiers
INSERT INTO quartiers (nom, slug, description) VALUES
    ('Centre-Ville', 'centre-ville', 'Cœur administratif et commercial de Yaoundé'),
    ('Bastos', 'bastos', 'Quartier résidentiel et diplomatique'),
    ('Essos', 'essos', 'Quartier populaire et animé'),
    ('Mvan', 'mvan', 'Pôle universitaire et jeune'),
    ('Ngousso', 'ngousso', 'Quartier en pleine expansion'),
    ('Odza', 'odza', 'Zone aéroportuaire et périurbaine'),
    ('Nlongkak', 'nlongkak', 'Quartier central résidentiel')
ON CONFLICT (slug) DO NOTHING;

-- Médicaments (20)
-- Idempotent : une fiche déjà présente (même nom + dosage, ou même produit : DCI + marque + dosage + forme)
-- n'est jamais recréée, avec ou sans index unique (uq_medicaments_nom_dosage, voir la migration de fusion).
INSERT INTO medicaments (nom, nom_commercial, dci, forme, dosage, categorie, ordonnance, description)
SELECT v.* FROM (VALUES
    ('Paracétamol 500mg', 'Doliprane', 'Paracétamol', 'Comprimé', '500mg', 'Antalgique', false, 'Antalgique et antipyrétique courant'),
    ('Paracétamol 1000mg', 'Efferalgan', 'Paracétamol', 'Comprimé effervescent', '1000mg', 'Antalgique', false, 'Antalgique effervescent'),
    ('Ibuprofène 400mg', 'Advil', 'Ibuprofène', 'Comprimé', '400mg', 'Anti-inflammatoire', false, 'Anti-inflammatoire non stéroïdien'),
    ('Aspirine 500mg', 'Aspro', 'Acide acétylsalicylique', 'Comprimé', '500mg', 'Antalgique', false, 'Antalgique anti-inflammatoire'),
    ('Amoxicilline 500mg', 'Clamoxyl', 'Amoxicilline', 'Gélule', '500mg', 'Antibiotique', true, 'Antibiotique bêta-lactamine'),
    ('Métronidazole 500mg', 'Flagyl', 'Métronidazole', 'Comprimé', '500mg', 'Antibiotique', true, 'Antiparasitaire et antibactérien'),
    ('Coartem', 'Coartem', 'Artemether-Lumefantrine', 'Comprimé', '20/120mg', 'Antipaludéen', true, 'Traitement du paludisme'),
    ('Quinine 500mg', 'Quinimax', 'Quinine', 'Comprimé', '500mg', 'Antipaludéen', true, 'Antipaludéen classique'),
    ('Oméprazole 20mg', 'Mopral', 'Oméprazole', 'Gélule', '20mg', 'Gastro-entérologie', false, 'Inhibiteur de la pompe à protons'),
    ('Métformine 500mg', 'Glucophage', 'Métformine', 'Comprimé', '500mg', 'Diabétologie', true, 'Antidiabétique oral'),
    ('Vitamine C 500mg', 'Vitascorbol', 'Acide ascorbique', 'Comprimé', '500mg', 'Vitamines', false, 'Complément en vitamine C'),
    ('Multivitamines', 'Supradyn', 'Multivitamines', 'Comprimé effervescent', '', 'Vitamines', false, 'Complexe multivitaminé'),
    ('Chloroquine 100mg', 'Nivaquine', 'Chloroquine', 'Comprimé', '100mg', 'Antipaludéen', true, 'Prophylaxie du paludisme'),
    ('Diclofénac 50mg', 'Voltarène', 'Diclofénac', 'Comprimé', '50mg', 'Anti-inflammatoire', false, 'AINS puissant'),
    ('Cotrimoxazole', 'Bactrim', 'Sulfaméthoxazole-Triméthoprime', 'Comprimé', '800/160mg', 'Antibiotique', true, 'Antibiotique à large spectre'),
    ('Cétirizine 10mg', 'Zyrtec', 'Cétirizine', 'Comprimé', '10mg', 'Antihistaminique', false, 'Antiallergique non sédatif'),
    ('Lopéramide 2mg', 'Imodium', 'Lopéramide', 'Gélule', '2mg', 'Gastro-entérologie', false, 'Antidiarrhéique'),
    ('Salbutamol', 'Ventoline', 'Salbutamol', 'Aérosol', '100µg/dose', 'Pneumologie', true, 'Bronchodilatateur d''urgence'),
    ('Fer + Acide folique', 'Tardyféron', 'Fer-Acide folique', 'Comprimé', '80mg+0.35mg', 'Hématologie', false, 'Traitement de l''anémie'),
    ('Ciprofloxacine 500mg', 'Ciflox', 'Ciprofloxacine', 'Comprimé', '500mg', 'Antibiotique', true, 'Fluoroquinolone à large spectre')
) AS v(nom, nom_commercial, dci, forme, dosage, categorie, ordonnance, description)
WHERE NOT EXISTS (
    SELECT 1 FROM medicaments m
    WHERE ((lower(btrim(m.nom)), lower(regexp_replace(coalesce(m.dosage, ''), '\s', '', 'g'))) = (lower(btrim(v.nom)), lower(regexp_replace(coalesce(v.dosage, ''), '\s', '', 'g'))))
       OR concat_ws('|', lower(btrim(coalesce(m.dci, ''))), lower(btrim(coalesce(m.nom_commercial, ''))), lower(regexp_replace(coalesce(m.dosage, ''), '\s', '', 'g')), lower(btrim(coalesce(m.forme, ''))), CASE WHEN btrim(coalesce(m.dci, '')) = '' AND btrim(coalesce(m.nom_commercial, '')) = '' THEN lower(btrim(m.nom)) END) = concat_ws('|', lower(btrim(coalesce(v.dci, ''))), lower(btrim(coalesce(v.nom_commercial, ''))), lower(regexp_replace(coalesce(v.dosage, ''), '\s', '', 'g')), lower(btrim(coalesce(v.forme, ''))), CASE WHEN btrim(coalesce(v.dci, '')) = '' AND btrim(coalesce(v.nom_commercial, '')) = '' THEN lower(btrim(v.nom)) END)
)
ON CONFLICT DO NOTHING;

-- Pharmacies de démo (extrait minimal pour tester le flux — pas les 52 de Yaoundé,
-- voir setup_complet.sql sur GitHub pour la liste complète si besoin d'un jeu plus riche)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie du Centre', 'pharmacie-du-centre', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Avenue Kennedy, Centre-Ville', 3.8667, 11.5167, '+237 222 23 45 67', 'verifie', 'admin'),
    ('Pharmacie de Bastos', 'pharmacie-de-bastos', (SELECT id FROM quartiers WHERE slug='bastos'), 'Rue Joseph Mballa Eloumden, Bastos', 3.8830, 11.5070, '+237 222 20 11 22', 'verifie', 'admin'),
    ('Pharmacie d''Essos', 'pharmacie-d-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Carrefour Essos', 3.8740, 11.5330, '+237 222 22 11 22', 'non_verifie', 'admin')
ON CONFLICT (slug) DO NOTHING;

-- Stocks de démonstration
DO $$
DECLARE
    ph_ids UUID[];
    med_ids UUID[];
    prix INTEGER[] := ARRAY[1200, 1500, 1800, 2500, 3500, 2000, 4500, 3000, 1800, 2200,
                            1100, 1600, 1900, 2300, 3200];
    i INTEGER; j INTEGER; idx INTEGER := 1;
BEGIN
    SELECT array_agg(id ORDER BY nom) INTO ph_ids FROM pharmacies LIMIT 3;
    SELECT array_agg(id ORDER BY nom) INTO med_ids FROM medicaments LIMIT 5;

    FOR i IN 1..3 LOOP
        FOR j IN 1..5 LOOP
            INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock, source)
            VALUES (ph_ids[i], med_ids[j], prix[idx], true, 'admin')
            ON CONFLICT (pharmacie_id, medicament_id) DO NOTHING;
            idx := idx + 1;
        END LOOP;
    END LOOP;
END $$;

UPDATE pharmacies SET est_de_garde = true, garde_jusqu_a = now() + interval '24 hours'
WHERE slug = 'pharmacie-du-centre';

-- ============================================================
-- VÉRIFICATION FINALE
-- ============================================================
DO $$
DECLARE
    n_quartiers INTEGER; n_pharmacies INTEGER; n_medicaments INTEGER;
    n_stocks INTEGER; n_garde INTEGER; n_profils_policies INTEGER;
BEGIN
    SELECT count(*) INTO n_quartiers FROM quartiers;
    SELECT count(*) INTO n_pharmacies FROM pharmacies;
    SELECT count(*) INTO n_medicaments FROM medicaments;
    SELECT count(*) INTO n_stocks FROM stocks;
    SELECT count(*) INTO n_garde FROM pharmacies WHERE est_de_garde = true;
    SELECT count(*) INTO n_profils_policies FROM pg_policies WHERE tablename = 'profils';

    RAISE NOTICE '✅ Setup consolidé terminé : % quartiers, % pharmacies (% de garde), % médicaments, % stocks',
        n_quartiers, n_pharmacies, n_garde, n_medicaments, n_stocks;

    IF n_profils_policies <> 3 THEN
        RAISE WARNING '⚠️  % policies trouvées sur profils (3 attendues) — vérifier avant de continuer', n_profils_policies;
    ELSE
        RAISE NOTICE '✅ profils : 3 policies RLS en place (select/update/insert), pas de récursion';
    END IF;
END $$;
