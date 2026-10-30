-- pgTAP — « Meilleurs prix » : la vue publique expose la date de mise à jour du prix retenu (colonne ajoutée en fin de vue,
-- colonnes existantes inchangées, lecture anonyme conservée).
BEGIN;
SELECT plan(7);

INSERT INTO quartiers (id, nom, slug) VALUES ('00000000-0000-0000-0000-00000000f001', 'Quartier test', 'quartier-test');
INSERT INTO pharmacies (id, nom, slug, quartier_id, latitude, longitude, statut, horaires) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Pharmacie chère', 'chere', '00000000-0000-0000-0000-00000000f001', 3.85, 11.50, 'verifie', '{}'),
    ('00000000-0000-0000-0000-0000000000d2', 'Pharmacie moins chère', 'moins-chere', '00000000-0000-0000-0000-00000000f001', 3.86, 11.51, 'verifie', '{}');
INSERT INTO medicaments (id, nom, dosage, forme) VALUES
    ('00000000-0000-0000-0000-00000000e001', 'Produit test', '100mg', 'comprimé');
INSERT INTO stocks (pharmacie_id, medicament_id, prix_fcfa, en_stock, date_maj) VALUES
    ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000e001', 2000, true, '2026-10-01 08:00:00+01'),
    ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-00000000e001', 1500, true, '2026-10-20 09:30:00+01');

SELECT is((SELECT data_type::text FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'v_meilleurs_prix' AND column_name = 'date_maj'),
          'timestamp with time zone', 'v_meilleurs_prix : colonne date_maj (timestamptz)');
SELECT is((SELECT ordinal_position::int FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'v_meilleurs_prix' AND column_name = 'date_maj'),
          12, 'date_maj ajoutée en fin de vue');
SELECT is((SELECT string_agg(column_name::text, ',' ORDER BY ordinal_position) FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = 'v_meilleurs_prix' AND ordinal_position <= 11),
          'medicament_id,medicament_nom,dci,dosage,pharmacie_id,pharmacie_nom,quartier_id,quartier_nom,prix_fcfa,en_stock,pharmacie_est_demo',
          'colonnes existantes inchangées, dans le même ordre (rétro-compatible)');

SET LOCAL ROLE anon;
SELECT lives_ok($$SELECT date_maj FROM v_meilleurs_prix$$, 'anonyme : date_maj lisible');
SELECT is((SELECT prix_fcfa FROM v_meilleurs_prix WHERE medicament_id = '00000000-0000-0000-0000-00000000e001'), 1500, 'le prix le plus bas reste retenu');
SELECT is((SELECT date_maj FROM v_meilleurs_prix WHERE medicament_id = '00000000-0000-0000-0000-00000000e001'), '2026-10-20 09:30:00+01'::timestamptz,
          'la date affichée est celle du stock retenu (pas celle d''une autre pharmacie)');
RESET ROLE;

UPDATE stocks SET en_stock = false WHERE pharmacie_id = '00000000-0000-0000-0000-0000000000d2';
SELECT is((SELECT date_maj FROM v_meilleurs_prix WHERE medicament_id = '00000000-0000-0000-0000-00000000e001'), '2026-10-01 08:00:00+01'::timestamptz,
          'rupture chez la moins chère : date du nouveau meilleur prix');

SELECT * FROM finish();
ROLLBACK;
