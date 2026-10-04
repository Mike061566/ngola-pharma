-- ============================================================
-- N'Gola Pharma — PR 2 : outbox de notifications et worker
-- SPEC 2 §6 (canaux, repli, retry, coût), §4.0bis (liste blanche en mode démo), §8.
-- PRODUCTION : à exécuter à la main, après relecture, après 20261004020000.
--
-- Cette migration n'envoie rien. Elle prépare l'outbox pour le worker (Edge Function `traiter-outbox`, fournisseur
-- `mock` par défaut) : colonnes de suivi, prélèvement par lots avec verrou SKIP LOCKED, comptage du budget de
-- messages, contacts bloqués, valeurs de configuration du worker.
-- ============================================================
BEGIN;

-- ── 1. Contacts : marqués « bloqué » quand le fournisseur rejette définitivement l'adresse ──
-- (Telegram 403 / 400 : bot bloqué, utilisateur désactivé, discussion introuvable — SPEC 2 §6.1)
ALTER TABLE public.contacts_pharmacie ADD COLUMN IF NOT EXISTS bloque_le timestamptz;

-- Éligibilité au routage : un contact bloqué ou désabonné ne compte pas comme « contact actif ».
CREATE OR REPLACE FUNCTION public.pharmacie_eligible_routage(p_pharmacie_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
    SELECT COALESCE((SELECT p.statut = 'verifie' AND p.est_publiee FROM public.pharmacies p WHERE p.id = p_pharmacie_id), false)
       AND EXISTS (SELECT 1 FROM public.contacts_pharmacie c
                   WHERE c.pharmacie_id = p_pharmacie_id AND c.desabonne_le IS NULL AND c.bloque_le IS NULL)
$$;

-- ── 2. Outbox : suivi du repli de canal, liste blanche de démonstration, exemption de budget ──
ALTER TABLE public.notifications_outbox
    ADD COLUMN IF NOT EXISTS contact_id uuid REFERENCES public.contacts_pharmacie(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS cle_base text,                                   -- ex. identifiant d'envoi ; sert à dériver les clés de repli
    ADD COLUMN IF NOT EXISTS canaux_tentes text[] NOT NULL DEFAULT '{}',      -- canaux déjà essayés pour ce message (repli)
    ADD COLUMN IF NOT EXISTS est_destinataire_demo boolean NOT NULL DEFAULT false,  -- liste blanche du mode démo
    ADD COLUMN IF NOT EXISTS exempte_budget boolean NOT NULL DEFAULT false;   -- alerte urgente d'une pharmacie de garde
-- Statut `suppressed_demo` : voir SPEC 2 §4.0bis (déjà autorisé par la contrainte de la PR 1).

-- Colonnes non secrètes visibles par l'admin connecté (l'adresse chiffrée reste masquée, comme en PR 1).
GRANT SELECT (contact_id, cle_base, canaux_tentes, est_destinataire_demo, exempte_budget, id_message_fournisseur)
    ON public.notifications_outbox TO authenticated;
GRANT SELECT (bloque_le) ON public.contacts_pharmacie TO authenticated;

-- ── 3. Prélèvement par lots (SKIP LOCKED) ─────────────────────────────
-- Plusieurs workers peuvent tourner en parallèle sans prendre les mêmes lignes. Le prélèvement pose un BAIL :
-- `prochaine_tentative_le` est repoussée de p_bail_s secondes ; si le worker meurt, la ligne redevient disponible
-- à l'échéance du bail (livraison « au moins une fois »). `tentatives` est incrémenté au prélèvement, donc un
-- message qui fait planter le worker est borné par le nombre maximal de tentatives.
CREATE OR REPLACE FUNCTION public.reclamer_notifications(p_limite int, p_bail_s int DEFAULT 120)
RETURNS SETOF public.notifications_outbox
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
    WITH lot AS (
        SELECT id FROM public.notifications_outbox
        WHERE statut = 'queued' AND prochaine_tentative_le <= now()
        ORDER BY prochaine_tentative_le, cree_le
        LIMIT GREATEST(p_limite, 0)
        FOR UPDATE SKIP LOCKED
    )
    UPDATE public.notifications_outbox o
    SET prochaine_tentative_le = now() + make_interval(secs => GREATEST(p_bail_s, 1)),
        tentatives = o.tentatives + 1,
        mis_a_jour_le = now()
    FROM lot
    WHERE o.id = lot.id
    RETURNING o.*
$$;

-- Messages payants (SMS, email) acceptés par le fournisseur depuis minuit, heure du Cameroun (budget quotidien).
CREATE OR REPLACE FUNCTION public.compter_messages_payants_du_jour()
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
    SELECT count(*)::int FROM public.notifications_outbox
    WHERE canal IN ('sms', 'email') AND statut IN ('sent', 'delivered', 'read')
      AND mis_a_jour_le >= date_trunc('day', now() AT TIME ZONE 'Africa/Douala') AT TIME ZONE 'Africa/Douala'
$$;

-- Réservé au serveur (service role) : ces fonctions manipulent des adresses chiffrées.
REVOKE ALL ON FUNCTION public.reclamer_notifications(int, int), public.compter_messages_payants_du_jour()
    FROM PUBLIC, anon, authenticated;

-- ── 4. Configuration du worker (modifiable par l'admin, SPEC 2 §0.5) ───
INSERT INTO public.config_routage (cle, valeur) VALUES
    ('retry_delais_s',                   '[30, 120, 300]'),   -- §6.2 : 3 relances après la 1re tentative, puis canal suivant
    ('worker_lot_taille',                '20'),
    ('worker_bail_s',                    '120'),
    ('debit_global_par_s',               '20'),               -- §6.1 : plafond du worker (Telegram tolère ~30/s)
    ('debit_par_discussion_ms',          '1000')              -- §6.1 : 1 message/s par discussion
ON CONFLICT (cle) DO NOTHING;

COMMIT;
