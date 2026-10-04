-- Migration: 0003_allow_patient_deletion.sql
-- Description: Enables delete operations on public.patients for single-clinic anon access.

BEGIN;

DROP POLICY IF EXISTS "Allow anon and auth delete clinic patients" ON public.patients;

CREATE POLICY "Allow anon and auth delete clinic patients"
ON public.patients FOR DELETE TO anon, authenticated
USING (true);

GRANT DELETE ON public.patients TO anon, authenticated;

COMMIT;
