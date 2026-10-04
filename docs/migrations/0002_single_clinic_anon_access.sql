-- Migration: 0002_single_clinic_anon_access.sql
-- Description: Switches Supabase access model to single-clinic anonymous API access.
-- Preserves all existing patient records and UUIDs.
-- Sets single-clinic default for clinic_id (keeping NOT NULL).
-- Grants least-privilege permissions to role 'anon' strictly on 'patients' and 'patient_sources'.

BEGIN;

-- 1. Remove obsolete clinic membership RLS policies from patients and patient_sources
DROP POLICY IF EXISTS "Authenticated users can read clinic patients" ON public.patients;
DROP POLICY IF EXISTS "Authenticated users can create clinic patients" ON public.patients;
DROP POLICY IF EXISTS "Authenticated users can update clinic patients" ON public.patients;
DROP POLICY IF EXISTS "Authenticated users can delete clinic patients" ON public.patients;

DROP POLICY IF EXISTS "Authenticated users can read clinic patient sources" ON public.patient_sources;
DROP POLICY IF EXISTS "Authenticated users can create clinic patient sources" ON public.patient_sources;
DROP POLICY IF EXISTS "Authenticated users can update clinic patient sources" ON public.patient_sources;
DROP POLICY IF EXISTS "Authenticated users can delete clinic patient sources" ON public.patient_sources;

-- 2. Add single-clinic default for clinic_id while keeping NOT NULL
ALTER TABLE public.patients ALTER COLUMN clinic_id SET DEFAULT 'c0000000-0000-0000-0000-000000000001';
ALTER TABLE public.patient_sources ALTER COLUMN clinic_id SET DEFAULT 'c0000000-0000-0000-0000-000000000001';

-- 3. Restore clean (source, external_id) uniqueness constraint for seamless upsert
ALTER TABLE public.patient_sources DROP CONSTRAINT IF EXISTS uq_patient_sources_clinic_source_external;
ALTER TABLE public.patient_sources DROP CONSTRAINT IF EXISTS uq_patient_sources_source_external;
ALTER TABLE public.patient_sources ADD CONSTRAINT uq_patient_sources_source_external UNIQUE (source, external_id);

-- 4. Create focused policies allowing anon and authenticated access to the clinic tables
CREATE POLICY "Allow anon and auth read clinic patients"
ON public.patients FOR SELECT TO anon, authenticated
USING (true);

CREATE POLICY "Allow anon and auth insert clinic patients"
ON public.patients FOR INSERT TO anon, authenticated
WITH CHECK (true);

CREATE POLICY "Allow anon and auth update clinic patients"
ON public.patients FOR UPDATE TO anon, authenticated
USING (true)
WITH CHECK (true);

CREATE POLICY "Allow anon and auth read clinic patient sources"
ON public.patient_sources FOR SELECT TO anon, authenticated
USING (true);

CREATE POLICY "Allow anon and auth insert clinic patient sources"
ON public.patient_sources FOR INSERT TO anon, authenticated
WITH CHECK (true);

CREATE POLICY "Allow anon and auth update clinic patient sources"
ON public.patient_sources FOR UPDATE TO anon, authenticated
USING (true)
WITH CHECK (true);

CREATE POLICY "Allow anon and auth delete clinic patient sources"
ON public.patient_sources FOR DELETE TO anon, authenticated
USING (true);

-- 5. Explicitly grant least-privilege table permissions to anon and authenticated roles
GRANT SELECT, INSERT, UPDATE ON public.patients TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.patient_sources TO anon, authenticated;

-- Ensure clinics and clinic_members remain completely inaccessible to anon
REVOKE ALL ON public.clinics FROM anon;
REVOKE ALL ON public.clinic_members FROM anon;

COMMIT;
