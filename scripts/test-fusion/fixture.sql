-- Jeu de données SYNTHÉTIQUE pour tester la fusion des fiches en double (aucune donnée de production).
INSERT INTO public.quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Quartier fusion', 'quartier-fusion');
INSERT INTO public.pharmacies (id, nom, slug, quartier_id) VALUES
 ('76beb7c3-0000-0000-0000-000000000001', 'Ma pharmacie', 'fusion-a', '00000000-0000-0000-0000-00000000f001'),
 ('76beb7c3-0000-0000-0000-000000000002', 'Pharmacie B',  'fusion-b', '00000000-0000-0000-0000-00000000f001'),
 ('76beb7c3-0000-0000-0000-000000000003', 'Pharmacie C',  'fusion-c', '00000000-0000-0000-0000-00000000f001');

INSERT INTO public.medicaments (id, nom, nom_commercial, dci, forme, dosage, created_at) VALUES
 -- Coartem : 2 fiches
 ('00000000-0000-0000-0000-0000000000a1', 'Coartem', 'Coartem', 'Artemether-Lumefantrine', 'Comprimé', '20/120mg', '2026-09-01'),
 ('00000000-0000-0000-0000-0000000000a2', 'Artemether-Lumefantrine', 'Coartem', 'Artemether-Lumefantrine', 'Comprimé', '20/120mg', '2026-09-10'),
 -- Chloroquine 100mg : 2 fiches
 ('00000000-0000-0000-0000-0000000000b1', 'Chloroquine 100mg', 'Nivaquine', 'Chloroquine', 'Comprimé', '100mg', '2026-09-01'),
 ('00000000-0000-0000-0000-0000000000b2', 'Chloroquine', 'Nivaquine', 'Chloroquine', 'Comprimé', '100mg', '2026-09-10'),
 -- Ibuprofène : 2 fiches (dosage écrit différemment)
 ('00000000-0000-0000-0000-0000000000d1', 'Ibuprofène 400mg', 'Advil', 'Ibuprofène', 'Comprimé', '400mg', '2026-09-01'),
 ('00000000-0000-0000-0000-0000000000d2', 'Ibuprofene', 'Advil', 'Ibuprofène', 'Comprimé', '400 mg', '2026-09-10'),
 -- Paracétamol : 3 fiches
 ('00000000-0000-0000-0000-0000000000c1', 'Paracétamol 500mg', 'Doliprane', 'Paracétamol', 'Comprimé', '500mg', '2026-09-01'),
 ('00000000-0000-0000-0000-0000000000c2', 'Paracetamol', 'Doliprane', 'Paracétamol', 'Comprimé', '500 mg', '2026-09-05'),
 ('00000000-0000-0000-0000-0000000000c3', 'Doliprane 500', 'doliprane', 'paracétamol', 'comprimé', '500mg', '2026-09-07'),
 -- Fiche seule, même principe actif (marque différente) : ne doit pas être touchée
 ('00000000-0000-0000-0000-0000000000e1', 'Efferalgan 500mg', 'Efferalgan', 'Paracétamol', 'Comprimé', '500mg', '2026-09-01');

INSERT INTO public.stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock, date_maj) VALUES
 -- Ma pharmacie : Coartem 5400 en stock (ancien) contre 5100 en stock (récent) ; Chloroquine 1800 rupture (ancien) contre 1500 en stock (récent)
 ('76beb7c3-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 5400, true,  '2026-09-20 10:00'),
 ('76beb7c3-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a2', 5100, true,  '2026-09-28 09:00'),
 ('76beb7c3-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000b1', 1800, false, '2026-09-20 10:00'),
 ('76beb7c3-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000b2', 1500, true,  '2026-09-25 10:00'),
 -- Pharmacie B : Coartem seulement sur une fiche ; Chloroquine à égalité de date (la ligne « en stock » gagne) ; Ibuprofène et Paracétamol
 ('76beb7c3-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000a2', 5000, true,  '2026-09-25 12:00'),
 ('76beb7c3-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000b1', 1800, false, '2026-09-23 10:00'),
 ('76beb7c3-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000b2', 1700, true,  '2026-09-23 10:00'),
 ('76beb7c3-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000d1',  600, true,  '2026-09-24 10:00'),
 ('76beb7c3-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000c1',  700, true,  '2026-09-24 10:00'),
 -- Pharmacie C : Paracétamol sur deux fiches à supprimer, aucune sur la gardée ; Efferalgan intact
 ('76beb7c3-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000c2',  800, true,  '2026-09-24 10:00'),
 ('76beb7c3-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000c3',  900, true,  '2026-09-26 10:00'),
 ('76beb7c3-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000e1', 1000, true,  '2026-09-24 10:00');

INSERT INTO public.alertes_stock (id, medicament_nom, medicament_id, canal, user_email) VALUES
 ('00000000-0000-0000-0000-00000000aa01', 'Ibuprofène 400mg', '00000000-0000-0000-0000-0000000000d2', 'email', 'ibu@test.local'),
 ('00000000-0000-0000-0000-00000000aa02', 'Médicament libre', NULL, 'email', 'libre@test.local');
