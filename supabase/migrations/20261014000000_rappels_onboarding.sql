-- ============================================================
-- N'Gola Pharma — onboarding, étape 4 : rappels J+1 / J+3 / J+7 et statut « dormante » (SPEC 1 §5.3).
-- PRODUCTION : à exécuter à la main, après relecture, après 20261013000000. Rétro-compatible : une table et des fonctions nouvelles.
-- Les rappels concernent les pharmacies APPROUVÉES par la procédure d'onboarding (demande approuvée) et non encore publiées ;
-- les pharmacies créées autrement (les 52 existantes) ne reçoivent rien. Aucune suppression, jamais.
-- Les messages partent par l'outbox (Edge Function `rappels-onboarding`, appelée une fois par jour par pg_cron : voir supabase/ops).
-- « Dormante » = approuvée depuis plus de 30 jours et toujours non publiée : valeur CALCULÉE (aucun état stocké, aucune suppression) ;
-- l'alerte à l'admin n'est envoyée qu'une fois (jalon 30).
-- ============================================================
BEGIN;

CREATE TABLE IF NOT EXISTS public.rappels_onboarding (
    pharmacie_id uuid NOT NULL REFERENCES public.pharmacies(id) ON DELETE CASCADE,
    jalon        smallint NOT NULL CHECK (jalon IN (1, 3, 7, 30)),    -- 30 = alerte « dormante » à l'admin
    envoye_le    timestamptz NOT NULL DEFAULT now(),
    canaux       jsonb NOT NULL DEFAULT '[]',                         -- canaux enfilés ([] = jalon sauté : exécution tardive)
    PRIMARY KEY (pharmacie_id, jalon)
);
ALTER TABLE public.rappels_onboarding ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.rappels_onboarding FROM PUBLIC, anon, authenticated;
DROP POLICY IF EXISTS "Admin lit les rappels d'onboarding" ON public.rappels_onboarding;
CREATE POLICY "Admin lit les rappels d'onboarding" ON public.rappels_onboarding FOR SELECT USING (auth_role() = 'admin');
GRANT SELECT ON public.rappels_onboarding TO authenticated;

-- Pharmacies à relancer (service role : appelée par l'Edge Function). Jamais d'adresse ni de contact ici : l'email du titulaire seulement.
CREATE OR REPLACE FUNCTION public.candidats_rappels_interne() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'pharmacie_id', p.id, 'demande_id', d.id, 'nom', p.nom, 'email', d.email_titulaire,
        'jours', floor(extract(epoch FROM now() - d.decidee_le) / 86400)::int,
        'compte_actif', d.compte_cree_le IS NOT NULL,
        'etape', COALESCE((SELECT i ->> 'cle' FROM jsonb_array_elements(x.c -> 'items') i WHERE NOT (i ->> 'fait')::boolean LIMIT 1), 'seuil'),
        'deja', COALESCE((SELECT jsonb_agg(r.jalon ORDER BY r.jalon) FROM public.rappels_onboarding r WHERE r.pharmacie_id = p.id), '[]'::jsonb),
        'est_demo', p.est_demo) ORDER BY d.decidee_le), '[]'::jsonb)
      FROM public.demandes_partenaire d
      JOIN public.pharmacies p ON p.id = d.pharmacie_id
      CROSS JOIN LATERAL (SELECT public.calculer_onboarding(p.id) AS c) x
     WHERE d.statut = 'approved' AND d.decidee_le IS NOT NULL AND p.statut = 'verifie' AND NOT p.est_publiee $$;

-- Enregistre un jalon (idempotent : un rappel n'est jamais compté deux fois).
CREATE OR REPLACE FUNCTION public.enregistrer_rappel_interne(p_pharmacie uuid, p_jalon int, p_canaux jsonb) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $f$
DECLARE v_n int;
BEGIN
    INSERT INTO public.rappels_onboarding (pharmacie_id, jalon, canaux) VALUES (p_pharmacie, p_jalon, COALESCE(p_canaux, '[]'))
    ON CONFLICT (pharmacie_id, jalon) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN
        PERFORM public.journaliser_onboarding(NULL, p_pharmacie, NULL, 'system', CASE WHEN p_jalon = 30 THEN 'alerte_dormante' ELSE 'rappel_envoye' END,
            jsonb_build_object('jalon', p_jalon, 'canaux', COALESCE(p_canaux, '[]')));
    END IF;
    RETURN v_n > 0;
END $f$;
REVOKE ALL ON FUNCTION public.candidats_rappels_interne(), public.enregistrer_rappel_interne(uuid, int, jsonb) FROM PUBLIC, anon, authenticated;

-- Console admin : pharmacies approuvées dont la mise en route n'est pas terminée (dormantes en tête).
CREATE OR REPLACE FUNCTION public.admin_pharmacies_en_retard() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $f$
BEGIN
    PERFORM public.exiger_admin();
    RETURN COALESCE((SELECT jsonb_agg(t ORDER BY (t ->> 'jours')::int DESC) FROM (
        SELECT jsonb_build_object('pharmacie_id', p.id, 'nom', p.nom, 'demande_id', d.id, 'est_demo', p.est_demo,
            'jours', floor(extract(epoch FROM now() - d.decidee_le) / 86400)::int,
            'dormante', now() - d.decidee_le > interval '30 days',
            'compte_actif', d.compte_cree_le IS NOT NULL,
            'faits', (public.calculer_onboarding(p.id) ->> 'faits')::int,
            'etape', COALESCE((SELECT i ->> 'cle' FROM jsonb_array_elements(public.calculer_onboarding(p.id) -> 'items') i WHERE NOT (i ->> 'fait')::boolean LIMIT 1), 'seuil'),
            'rappels', COALESCE((SELECT jsonb_agg(r.jalon ORDER BY r.jalon) FROM public.rappels_onboarding r WHERE r.pharmacie_id = p.id AND r.jalon < 30), '[]'::jsonb)) AS t
          FROM public.demandes_partenaire d JOIN public.pharmacies p ON p.id = d.pharmacie_id
         WHERE d.statut = 'approved' AND d.decidee_le IS NOT NULL AND NOT p.est_publiee) s), '[]'::jsonb);
END $f$;
REVOKE ALL ON FUNCTION public.admin_pharmacies_en_retard() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_pharmacies_en_retard() TO authenticated;

COMMIT;
