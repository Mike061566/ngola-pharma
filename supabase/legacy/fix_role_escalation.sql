-- ============================================================
-- N'Gola Pharma — Fix : auto-élévation de privilège via profils_insert
--
-- Faille trouvée pendant l'audit du 2026-09-22 : la policy
-- "profils_insert" d'origine (voir setup_consolide.sql / anciens
-- scripts) autorise WITH CHECK (id = auth.uid()) uniquement — elle
-- ne restreint jamais la valeur du champ `role` que l'utilisateur
-- envoie. Concrètement, n'importe quel compte (y compris un compte
-- créé via signup public, avec la seule clé anon publique) peut
-- s'auto-attribuer role='admin' ou role='pharmacien' et n'importe
-- quel pharmacie_id, en un seul appel :
--
--   supabase.from('profils').upsert({ id: auth.uid(), role: 'admin' })
--
-- Reproduit et confirmé sur le projet ueycknsdwthmtmpzptqp le
-- 2026-09-22.
--
-- Ce script restreint l'auto-inscription à role='patient' sans
-- pharmacie_id. L'attribution des rôles pharmacien/admin devient
-- réservée aux admins existants (via auth_role() = 'admin') ou au
-- SQL Editor.
-- ============================================================

DROP POLICY IF EXISTS "profils_insert" ON profils;

CREATE POLICY "profils_insert" ON profils FOR INSERT
    WITH CHECK (
        id = auth.uid()
        AND (
            -- Auto-inscription publique : uniquement en tant que patient, sans pharmacie
            (role = 'patient' AND pharmacie_id IS NULL)
            -- Un admin existant peut créer un profil avec n'importe quel rôle
            OR auth_role() = 'admin'
        )
    );

-- Le même trou existe potentiellement sur UPDATE : la policy
-- "profils_update" d'origine (USING (id = auth.uid())) autorise
-- aussi un utilisateur à modifier SON PROPRE rôle après coup, pas
-- seulement à la création. Même correctif nécessaire.
DROP POLICY IF EXISTS "profils_update" ON profils;

CREATE POLICY "profils_update" ON profils FOR UPDATE
    USING (id = auth.uid())
    WITH CHECK (
        id = auth.uid()
        AND (
            -- Un utilisateur non-admin ne peut pas changer son propre rôle
            role = (SELECT role FROM profils WHERE id = auth.uid())
            OR auth_role() = 'admin'
        )
    );

-- ============================================================
-- VÉRIFICATION
-- ============================================================
DO $$
BEGIN
    RAISE NOTICE '✅ profils_insert et profils_update corrigées : un compte non-admin ne peut plus s''auto-attribuer un rôle pharmacien/admin, ni le modifier après coup.';
END $$;
