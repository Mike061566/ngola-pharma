-- ============================================================
-- N'Gola Pharma — Script de seed
-- Exécuter après la migration 001_schema.sql
-- ============================================================

-- 1. Quartiers
INSERT INTO quartiers (nom, slug, description) VALUES
    ('Centre-Ville', 'centre-ville', 'Cœur administratif et commercial de Yaoundé'),
    ('Bastos', 'bastos', 'Quartier résidentiel et diplomatique'),
    ('Essos', 'essos', 'Quartier populaire et animé'),
    ('Mvan', 'mvan', 'Pôle universitaire et jeune'),
    ('Ngousso', 'ngousso', 'Quartier en pleine expansion'),
    ('Odza', 'odza', 'Zone aéroportuaire et périurbaine'),
    ('Nlongkak', 'nlongkak', 'Quartier central résidentiel');

-- 2. Pharmacies (52 — toutes en statut non_verifie par défaut)
-- Centre-Ville (12)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie du Centre', 'pharmacie-du-centre', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Avenue Kennedy, Centre-Ville', 3.8667, 11.5167, '+237 222 23 45 67', 'non_verifie', 'admin'),
    ('Pharmacie de la Poste Centrale', 'pharmacie-de-la-poste-centrale', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Rue de la Poste, Centre-Ville', 3.8670, 11.5185, '+237 222 23 12 34', 'non_verifie', 'admin'),
    ('Pharmacie du Marché Central', 'pharmacie-du-marche-central', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Boulevard du 20 Mai, Centre-Ville', 3.8685, 11.5170, '+237 222 23 56 78', 'non_verifie', 'admin'),
    ('Pharmacie de l''Hôtel de Ville', 'pharmacie-de-l-hotel-de-ville', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Place de l''Hôtel de Ville', 3.8660, 11.5195, '+237 222 23 89 01', 'non_verifie', 'admin'),
    ('Pharmacie Biyem-Assi', 'pharmacie-biyem-assi', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Carrefour Biyem-Assi', 3.8540, 11.4985, '+237 222 23 22 33', 'non_verifie', 'admin'),
    ('Pharmacie Kennedy', 'pharmacie-kennedy', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Avenue Kennedy', 3.8672, 11.5150, '+237 222 23 44 55', 'non_verifie', 'admin'),
    ('Pharmacie du Plateau', 'pharmacie-du-plateau', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Quartier du Plateau', 3.8700, 11.5180, '+237 222 23 66 77', 'non_verifie', 'admin'),
    ('Pharmacie Mvog-Ada', 'pharmacie-mvog-ada', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Carrefour Mvog-Ada', 3.8595, 11.5135, '+237 222 23 88 99', 'non_verifie', 'admin'),
    ('Pharmacie de la Cathédrale', 'pharmacie-de-la-cathedrale', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Rue de la Cathédrale', 3.8678, 11.5200, '+237 222 23 11 22', 'non_verifie', 'admin'),
    ('Pharmacie Warda', 'pharmacie-warda', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Avenue Monseigneur Vogt', 3.8655, 11.5175, '+237 222 23 33 44', 'non_verifie', 'admin'),
    ('Pharmacie Elig-Essono', 'pharmacie-elig-essono', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Carrefour Elig-Essono', 3.8690, 11.5210, '+237 222 23 55 66', 'non_verifie', 'admin'),
    ('Pharmacie du 20 Mai', 'pharmacie-du-20-mai', (SELECT id FROM quartiers WHERE slug='centre-ville'), 'Boulevard du 20 Mai', 3.8695, 11.5165, '+237 222 23 77 88', 'non_verifie', 'admin');

-- Bastos (8)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie de Bastos', 'pharmacie-de-bastos', (SELECT id FROM quartiers WHERE slug='bastos'), 'Rue Joseph Mballa Eloumden, Bastos', 3.8830, 11.5070, '+237 222 20 11 22', 'non_verifie', 'admin'),
    ('Pharmacie du Lac', 'pharmacie-du-lac', (SELECT id FROM quartiers WHERE slug='bastos'), 'Quartier du Lac, Bastos', 3.8850, 11.5100, '+237 222 20 33 44', 'non_verifie', 'admin'),
    ('Pharmacie les Ambassades', 'pharmacie-les-ambassades', (SELECT id FROM quartiers WHERE slug='bastos'), 'Avenue Charles de Gaulle, Bastos', 3.8815, 11.5055, '+237 222 20 55 66', 'non_verifie', 'admin'),
    ('Pharmacie Santa Lucia', 'pharmacie-santa-lucia', (SELECT id FROM quartiers WHERE slug='bastos'), 'Rue 1.828, Bastos', 3.8840, 11.5085, '+237 222 20 77 88', 'non_verifie', 'admin'),
    ('Pharmacie Golf', 'pharmacie-golf', (SELECT id FROM quartiers WHERE slug='bastos'), 'Près du Golf Club, Bastos', 3.8870, 11.5110, '+237 222 20 99 00', 'non_verifie', 'admin'),
    ('Pharmacie Nouvelle Bastos', 'pharmacie-nouvelle-bastos', (SELECT id FROM quartiers WHERE slug='bastos'), 'Carrefour Bastos', 3.8820, 11.5065, '+237 222 20 22 33', 'non_verifie', 'admin'),
    ('Pharmacie Résidence', 'pharmacie-residence', (SELECT id FROM quartiers WHERE slug='bastos'), 'Avenue des Palmiers, Bastos', 3.8860, 11.5095, '+237 222 20 44 55', 'non_verifie', 'admin'),
    ('Pharmacie Tropicale', 'pharmacie-tropicale', (SELECT id FROM quartiers WHERE slug='bastos'), 'Rue 1.845, Bastos', 3.8845, 11.5080, '+237 222 20 66 77', 'non_verifie', 'admin');

-- Essos (15)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie d''Essos', 'pharmacie-d-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Carrefour Essos', 3.8740, 11.5330, '+237 222 22 11 22', 'non_verifie', 'admin'),
    ('Pharmacie de la Paix', 'pharmacie-de-la-paix', (SELECT id FROM quartiers WHERE slug='essos'), 'Rue d''Essos', 3.8755, 11.5345, '+237 222 22 33 44', 'non_verifie', 'admin'),
    ('Pharmacie Populaire d''Essos', 'pharmacie-populaire-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Marché d''Essos', 3.8735, 11.5320, '+237 222 22 55 66', 'non_verifie', 'admin'),
    ('Pharmacie Fraternité', 'pharmacie-fraternite', (SELECT id FROM quartiers WHERE slug='essos'), 'Avenue d''Essos', 3.8760, 11.5355, '+237 222 22 77 88', 'non_verifie', 'admin'),
    ('Pharmacie Carrefour Essos', 'pharmacie-carrefour-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Grand Carrefour Essos', 3.8745, 11.5335, '+237 222 22 99 00', 'non_verifie', 'admin'),
    ('Pharmacie du Bonheur', 'pharmacie-du-bonheur', (SELECT id FROM quartiers WHERE slug='essos'), 'Rue du Bonheur, Essos', 3.8770, 11.5360, '+237 222 22 22 33', 'non_verifie', 'admin'),
    ('Pharmacie la Providence Essos', 'pharmacie-la-providence-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Quartier Essos Nord', 3.8780, 11.5340, '+237 222 22 44 55', 'non_verifie', 'admin'),
    ('Pharmacie Espoir', 'pharmacie-espoir', (SELECT id FROM quartiers WHERE slug='essos'), 'Essos Sud', 3.8725, 11.5315, '+237 222 22 66 77', 'non_verifie', 'admin'),
    ('Pharmacie Centrale Essos', 'pharmacie-centrale-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Centre Essos', 3.8750, 11.5350, '+237 222 22 88 99', 'non_verifie', 'admin'),
    ('Pharmacie les Palmiers Essos', 'pharmacie-les-palmiers-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Avenue des Palmiers, Essos', 3.8765, 11.5325, '+237 222 22 11 33', 'non_verifie', 'admin'),
    ('Pharmacie Lumière', 'pharmacie-lumiere', (SELECT id FROM quartiers WHERE slug='essos'), 'Essos Plateau', 3.8738, 11.5355, '+237 222 22 44 66', 'non_verifie', 'admin'),
    ('Pharmacie Santé Plus Essos', 'pharmacie-sante-plus-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Carrefour Essos Est', 3.8775, 11.5370, '+237 222 22 55 77', 'non_verifie', 'admin'),
    ('Pharmacie Solidarité Essos', 'pharmacie-solidarite-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Essos Ouest', 3.8730, 11.5310, '+237 222 22 66 88', 'non_verifie', 'admin'),
    ('Pharmacie Merveilleuse Essos', 'pharmacie-merveilleuse-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Rue Merveilleuse, Essos', 3.8742, 11.5365, '+237 222 22 77 99', 'non_verifie', 'admin'),
    ('Pharmacie Bonne Santé Essos', 'pharmacie-bonne-sante-essos', (SELECT id FROM quartiers WHERE slug='essos'), 'Essos Centre-Sud', 3.8758, 11.5328, '+237 222 22 88 11', 'non_verifie', 'admin');

-- Mvan (10)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie du Campus', 'pharmacie-du-campus', (SELECT id FROM quartiers WHERE slug='mvan'), 'Entrée Université Yaoundé I, Mvan', 3.8560, 11.4960, '+237 222 21 11 22', 'non_verifie', 'admin'),
    ('Pharmacie Étudiante', 'pharmacie-etudiante', (SELECT id FROM quartiers WHERE slug='mvan'), 'Rue des Étudiants, Mvan', 3.8575, 11.4975, '+237 222 21 33 44', 'non_verifie', 'admin'),
    ('Pharmacie du Savoir', 'pharmacie-du-savoir', (SELECT id FROM quartiers WHERE slug='mvan'), 'Boulevard Universitaire, Mvan', 3.8550, 11.4950, '+237 222 21 55 66', 'non_verifie', 'admin'),
    ('Pharmacie la Référence Mvan', 'pharmacie-la-reference-mvan', (SELECT id FROM quartiers WHERE slug='mvan'), 'Carrefour Mvan', 3.8580, 11.4980, '+237 222 21 77 88', 'non_verifie', 'admin'),
    ('Pharmacie Mvan Centre', 'pharmacie-mvan-centre', (SELECT id FROM quartiers WHERE slug='mvan'), 'Centre Mvan', 3.8565, 11.4965, '+237 222 21 99 00', 'non_verifie', 'admin'),
    ('Pharmacie de l''Espérance Mvan', 'pharmacie-de-l-esperance-mvan', (SELECT id FROM quartiers WHERE slug='mvan'), 'Avenue de l''Espérance, Mvan', 3.8545, 11.4955, '+237 222 21 22 33', 'non_verifie', 'admin'),
    ('Pharmacie Jeunesse', 'pharmacie-jeunesse', (SELECT id FROM quartiers WHERE slug='mvan'), 'Quartier Jeunesse, Mvan', 3.8590, 11.4990, '+237 222 21 44 55', 'non_verifie', 'admin'),
    ('Pharmacie le Progrès Mvan', 'pharmacie-le-progres-mvan', (SELECT id FROM quartiers WHERE slug='mvan'), 'Rue du Progrès, Mvan', 3.8555, 11.4970, '+237 222 21 66 77', 'non_verifie', 'admin'),
    ('Pharmacie Bien-Être Mvan', 'pharmacie-bien-etre-mvan', (SELECT id FROM quartiers WHERE slug='mvan'), 'Mvan Nord', 3.8585, 11.4985, '+237 222 21 88 99', 'non_verifie', 'admin'),
    ('Pharmacie Soleil Mvan', 'pharmacie-soleil-mvan', (SELECT id FROM quartiers WHERE slug='mvan'), 'Mvan Est', 3.8570, 11.4995, '+237 222 21 11 33', 'non_verifie', 'admin');

-- Ngousso (5)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie de Ngousso', 'pharmacie-de-ngousso', (SELECT id FROM quartiers WHERE slug='ngousso'), 'Carrefour Ngousso', 3.8900, 11.5250, '+237 222 25 11 22', 'non_verifie', 'admin'),
    ('Pharmacie Nouvelle Ngousso', 'pharmacie-nouvelle-ngousso', (SELECT id FROM quartiers WHERE slug='ngousso'), 'Avenue Ngousso', 3.8915, 11.5265, '+237 222 25 33 44', 'non_verifie', 'admin'),
    ('Pharmacie la Grâce Ngousso', 'pharmacie-la-grace-ngousso', (SELECT id FROM quartiers WHERE slug='ngousso'), 'Ngousso Centre', 3.8905, 11.5255, '+237 222 25 55 66', 'non_verifie', 'admin'),
    ('Pharmacie Avenir Ngousso', 'pharmacie-avenir-ngousso', (SELECT id FROM quartiers WHERE slug='ngousso'), 'Ngousso Sud', 3.8890, 11.5240, '+237 222 25 77 88', 'non_verifie', 'admin'),
    ('Pharmacie Développement Ngousso', 'pharmacie-developpement-ngousso', (SELECT id FROM quartiers WHERE slug='ngousso'), 'Ngousso Nord', 3.8920, 11.5270, '+237 222 25 99 00', 'non_verifie', 'admin');

-- Odza (1)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie de l''Aéroport', 'pharmacie-de-l-aeroport', (SELECT id FROM quartiers WHERE slug='odza'), 'Route de l''Aéroport, Odza', 3.8380, 11.5520, '+237 222 24 11 22', 'non_verifie', 'admin');

-- Nlongkak (1 — on passe à 52 total)
INSERT INTO pharmacies (nom, slug, quartier_id, adresse, latitude, longitude, telephone, statut, source) VALUES
    ('Pharmacie la Moderne Nlongkak', 'pharmacie-la-moderne-nlongkak', (SELECT id FROM quartiers WHERE slug='nlongkak'), 'Carrefour Nlongkak', 3.8780, 11.5120, '+237 222 26 11 22', 'non_verifie', 'admin');

-- 3. Médicaments (20 essentiels)
INSERT INTO medicaments (nom, nom_commercial, dci, forme, dosage, categorie, ordonnance, description) VALUES
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
    ('Ciprofloxacine 500mg', 'Ciflox', 'Ciprofloxacine', 'Comprimé', '500mg', 'Antibiotique', true, 'Fluoroquinolone à large spectre');

-- 4. Stocks de démonstration (quelques prix pour les premières pharmacies)
-- On injecte des prix réalistes en FCFA pour les 5 premières pharmacies × 5 médicaments courants
DO $$
DECLARE
    ph_ids UUID[];
    med_ids UUID[];
    prix INTEGER[] := ARRAY[1200, 1500, 1800, 2500, 3500, 2000, 4500, 3000, 1800, 2200,
                            1100, 1600, 1900, 2300, 3200, 2100, 4200, 2800, 1700, 2400,
                            1300, 1450, 1750, 2600, 3600, 1950, 4800, 3100, 1850, 2150];
    i INTEGER;
    j INTEGER;
    idx INTEGER := 1;
BEGIN
    SELECT array_agg(id ORDER BY nom) INTO ph_ids FROM pharmacies LIMIT 6;
    SELECT array_agg(id ORDER BY nom) INTO med_ids FROM medicaments LIMIT 5;

    FOR i IN 1..6 LOOP
        FOR j IN 1..5 LOOP
            INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock, source)
            VALUES (ph_ids[i], med_ids[j], prix[idx], random() > 0.15, 'admin')
            ON CONFLICT (pharmacie_id, medicament_id) DO NOTHING;
            idx := idx + 1;
        END LOOP;
    END LOOP;
END $$;

-- Vérification
DO $$
DECLARE
    n_quartiers INTEGER;
    n_pharmacies INTEGER;
    n_medicaments INTEGER;
    n_stocks INTEGER;
BEGIN
    SELECT count(*) INTO n_quartiers FROM quartiers;
    SELECT count(*) INTO n_pharmacies FROM pharmacies;
    SELECT count(*) INTO n_medicaments FROM medicaments;
    SELECT count(*) INTO n_stocks FROM stocks;
    RAISE NOTICE '✅ Seed terminé : % quartiers, % pharmacies, % médicaments, % stocks',
        n_quartiers, n_pharmacies, n_medicaments, n_stocks;
END $$;
