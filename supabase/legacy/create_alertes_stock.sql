-- ============================================================
-- N'Gola Pharma — Phase 3 : Table alertes_stock
-- Exécuter dans Supabase SQL Editor
-- ============================================================

-- 1. Créer la table
CREATE TABLE IF NOT EXISTS alertes_stock (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_email TEXT NOT NULL,
    medicament_nom TEXT NOT NULL,          -- nom du médicament recherché (texte libre)
    medicament_id UUID REFERENCES medicaments(id),  -- si on a pu le matcher
    quartier_id UUID REFERENCES quartiers(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    notified_at TIMESTAMPTZ,
    active BOOLEAN DEFAULT true
);

-- 2. Index pour les requêtes admin
CREATE INDEX IF NOT EXISTS idx_alertes_stock_active ON alertes_stock(active, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_alertes_stock_email ON alertes_stock(user_email);

-- 3. RLS : INSERT public (anon), SELECT/UPDATE admin uniquement
ALTER TABLE alertes_stock ENABLE ROW LEVEL SECURITY;

-- Politique INSERT : tout le monde peut s'inscrire à une alerte
CREATE POLICY "Tout le monde peut créer une alerte"
    ON alertes_stock FOR INSERT
    TO anon, authenticated
    WITH CHECK (true);

-- Politique SELECT : seuls les admins voient les alertes
CREATE POLICY "Admins voient les alertes"
    ON alertes_stock FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM profils
            WHERE profils.id = auth.uid()
            AND profils.role = 'admin'
        )
    );

-- Politique UPDATE : seuls les admins mettent à jour (notified_at, active)
CREATE POLICY "Admins modifient les alertes"
    ON alertes_stock FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM profils
            WHERE profils.id = auth.uid()
            AND profils.role = 'admin'
        )
    );

-- 4. Vérification
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'alertes_stock'
ORDER BY ordinal_position;
