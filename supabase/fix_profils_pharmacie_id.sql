-- ============================================================
-- N'Gola Pharma — Correctif : profils.pharmacie_id modifiable par un admin seulement
--
-- Faille : la policy `profils_update` (fix_role_escalation.sql / setup_consolide.sql)
-- empêchait un utilisateur de changer son propre `role`, mais pas sa colonne
-- `pharmacie_id`. Un pharmacien pouvait donc se rattacher à une AUTRE officine
-- (`profils.update({ pharmacie_id: <autre> })`) et obtenir, via auth_pharmacie_id(),
-- le droit de modifier ses stocks et ses informations.
--
-- Correctif : hors admin, `role` ET `pharmacie_id` doivent rester identiques à leur
-- valeur actuelle. Un admin peut modifier n'importe quel profil (rattachement d'un
-- pharmacien à son officine depuis la console admin).
--
-- Idempotent. Aucune donnée n'est lue ni modifiée : seule la policy est remplacée.
-- Test : supabase/tests/profils_pharmacie_id.test.sql (pgTAP).
-- ============================================================

DROP POLICY IF EXISTS "profils_update" ON profils;

CREATE POLICY "profils_update" ON profils FOR UPDATE
    USING (id = auth.uid() OR auth_role() = 'admin')
    WITH CHECK (
        auth_role() = 'admin'
        OR (
            id = auth.uid()
            AND role = auth_role()
            AND pharmacie_id IS NOT DISTINCT FROM auth_pharmacie_id()
        )
    );
