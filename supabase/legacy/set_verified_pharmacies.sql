-- ============================================================
-- N'Gola Pharma — Phase 2 : Passer des pharmacies en "vérifié"
-- Exécuter dans Supabase SQL Editor
-- ============================================================

-- 10 pharmacies réparties dans différents quartiers de Yaoundé
UPDATE pharmacies
SET statut = 'verifie', verified_at = now()
WHERE slug IN (
    'pharmacie-du-centre',            -- Centre-Ville
    'pharmacie-kennedy',              -- Centre-Ville
    'pharmacie-de-bastos',            -- Bastos
    'pharmacie-santa-lucia',          -- Bastos
    'pharmacie-d-essos',              -- Essos
    'pharmacie-lumiere',              -- Essos
    'pharmacie-du-campus',            -- Mvan
    'pharmacie-bien-etre-mvan',       -- Mvan
    'pharmacie-de-ngousso',           -- Ngousso
    'pharmacie-la-moderne-nlongkak'   -- Nlongkak
);

-- Vérification
SELECT nom, slug, statut, verified_at
FROM pharmacies
WHERE statut = 'verifie'
ORDER BY nom;
