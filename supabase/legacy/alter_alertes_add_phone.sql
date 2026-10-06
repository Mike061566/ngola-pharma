-- ============================================================
-- N'Gola Pharma — Phase 3b : Ajouter support téléphone/WhatsApp
-- Exécuter dans Supabase SQL Editor APRÈS create_alertes_stock.sql
-- ============================================================

-- 1. Ajouter colonne téléphone + canal préféré
ALTER TABLE alertes_stock
    ADD COLUMN IF NOT EXISTS user_phone TEXT,
    ADD COLUMN IF NOT EXISTS canal TEXT DEFAULT 'email'
        CHECK (canal IN ('email', 'whatsapp', 'ussd'));

-- 2. Rendre user_email nullable (on peut avoir tel sans email)
ALTER TABLE alertes_stock ALTER COLUMN user_email DROP NOT NULL;

-- 3. Contrainte : au moins un contact fourni
ALTER TABLE alertes_stock
    ADD CONSTRAINT contact_required
    CHECK (user_email IS NOT NULL OR user_phone IS NOT NULL);

-- 4. Index sur téléphone
CREATE INDEX IF NOT EXISTS idx_alertes_stock_phone ON alertes_stock(user_phone);

-- 5. Vérification
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'alertes_stock'
ORDER BY ordinal_position;
