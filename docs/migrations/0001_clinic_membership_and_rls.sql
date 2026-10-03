-- ==============================================================================
-- Migration: 0001_clinic_membership_and_rls.sql
-- Description: Establishes clinic data boundary, clinic_members table,
--              hardened SECURITY DEFINER function, patient/clinic consistency,
--              and clinic-scoped RLS policies.
-- Invariants:
--   1. Clinic entity (clinics.id) is completely decoupled from user (auth.users.id).
--   2. No automatic user provisioning or seeding from auth.users.
--   3. Hardened is_clinic_member() function with explicit search_path and permissions.
--   4. Role anon has ZERO access to clinics, clinic_members, patients, patient_sources.
--   5. patient_sources uniqueness is clinic-scoped: UNIQUE(clinic_id, source, external_id).
--   6. patient_sources.clinic_id must match referenced patients.clinic_id on INSERT and UPDATE.
-- ==============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ==============================================================================
-- 1. CLINICS TABLE
-- ==============================================================================
CREATE TABLE IF NOT EXISTS public.clinics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Seed initial Main Clinic with deterministic UUID for single-clinic deployment
-- (Zero automatic user seeding is performed)
INSERT INTO public.clinics (id, name)
VALUES ('c0000000-0000-0000-0000-000000000001', 'Main Clinic')
ON CONFLICT (id) DO NOTHING;

-- ==============================================================================
-- 2. CLINIC MEMBERS TABLE
-- ==============================================================================
CREATE TABLE IF NOT EXISTS public.clinic_members (
    clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'staff' CHECK (role IN ('owner', 'admin', 'staff')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (clinic_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_clinic_members_user_id ON public.clinic_members (user_id);
CREATE INDEX IF NOT EXISTS idx_clinic_members_clinic_id ON public.clinic_members (clinic_id);

-- ==============================================================================
-- 3. HARDENED SECURITY DEFINER MEMBERSHIP FUNCTION
-- ==============================================================================
CREATE OR REPLACE FUNCTION public.is_clinic_member(c_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Strict membership check against schema-qualified clinic_members table
  RETURN EXISTS (
    SELECT 1 FROM public.clinic_members
    WHERE clinic_id = c_id
      AND user_id = auth.uid()
  );
END;
$$;

-- Secure function permissions: revoke from public, grant strictly to authenticated
REVOKE ALL ON FUNCTION public.is_clinic_member(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_clinic_member(UUID) TO authenticated;

-- ==============================================================================
-- 4. PATIENTS TABLE SCHEMA UPDATE
-- ==============================================================================
-- Clean up old clinic_id column (avoiding unnecessary CASCADE)
ALTER TABLE public.patients DROP COLUMN IF EXISTS clinic_id;

-- Add proper foreign key to clinics table (NOT NULL)
ALTER TABLE public.patients ADD COLUMN clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_patients_clinic_id ON public.patients (clinic_id);

-- ==============================================================================
-- 5. PATIENT SOURCES TABLE SCHEMA UPDATE
-- ==============================================================================
-- Clean up old clinic_id column (avoiding unnecessary CASCADE)
ALTER TABLE public.patient_sources DROP COLUMN IF EXISTS clinic_id;

-- Add proper foreign key to clinics table (NOT NULL)
ALTER TABLE public.patient_sources ADD COLUMN clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_patient_sources_clinic_id ON public.patient_sources (clinic_id);

-- Transition uniqueness constraint from (source, external_id) to (clinic_id, source, external_id)
ALTER TABLE public.patient_sources DROP CONSTRAINT IF EXISTS uq_patient_sources_source_external;
ALTER TABLE public.patient_sources DROP CONSTRAINT IF EXISTS uq_patient_sources_clinic_source_external;

ALTER TABLE public.patient_sources ADD CONSTRAINT uq_patient_sources_clinic_source_external
    UNIQUE (clinic_id, source, external_id);

-- ==============================================================================
-- 6. ROW LEVEL SECURITY (RLS) POLICIES
-- ==============================================================================

-- Enable RLS on all clinical tables
ALTER TABLE public.clinics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clinic_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_sources ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------------------------
-- 6.1 Clinics RLS
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "Members can view their clinics" ON public.clinics;
CREATE POLICY "Members can view their clinics"
ON public.clinics FOR SELECT TO authenticated
USING (public.is_clinic_member(id));

-- ------------------------------------------------------------------------------
-- 6.2 Clinic Members RLS
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "Members can view their memberships" ON public.clinic_members;
CREATE POLICY "Members can view their memberships"
ON public.clinic_members FOR SELECT TO authenticated
USING (user_id = auth.uid() OR public.is_clinic_member(clinic_id));

-- ------------------------------------------------------------------------------
-- 6.3 Patients RLS (Clinic Membership Boundary)
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "Authenticated users can read patients" ON public.patients;
DROP POLICY IF EXISTS "Authenticated users can create patients" ON public.patients;
DROP POLICY IF EXISTS "Authenticated users can update patients" ON public.patients;
DROP POLICY IF EXISTS "Authenticated users can delete patients" ON public.patients;
DROP POLICY IF EXISTS "Authenticated users can read clinic patients" ON public.patients;
DROP POLICY IF EXISTS "Authenticated users can create clinic patients" ON public.patients;
DROP POLICY IF EXISTS "Authenticated users can update clinic patients" ON public.patients;
DROP POLICY IF EXISTS "Authenticated users can delete clinic patients" ON public.patients;

CREATE POLICY "Authenticated users can read clinic patients"
ON public.patients FOR SELECT TO authenticated
USING (public.is_clinic_member(clinic_id));

CREATE POLICY "Authenticated users can create clinic patients"
ON public.patients FOR INSERT TO authenticated
WITH CHECK (public.is_clinic_member(clinic_id));

CREATE POLICY "Authenticated users can update clinic patients"
ON public.patients FOR UPDATE TO authenticated
USING (public.is_clinic_member(clinic_id))
WITH CHECK (public.is_clinic_member(clinic_id));

CREATE POLICY "Authenticated users can delete clinic patients"
ON public.patients FOR DELETE TO authenticated
USING (public.is_clinic_member(clinic_id));

-- ------------------------------------------------------------------------------
-- 6.4 Patient Sources RLS (Clinic Membership Boundary + Clinic Consistency)
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "Authenticated users can read patient sources" ON public.patient_sources;
DROP POLICY IF EXISTS "Authenticated users can create patient sources" ON public.patient_sources;
DROP POLICY IF EXISTS "Authenticated users can update patient sources" ON public.patient_sources;
DROP POLICY IF EXISTS "Authenticated users can delete patient sources" ON public.patient_sources;
DROP POLICY IF EXISTS "Authenticated users can read clinic patient sources" ON public.patient_sources;
DROP POLICY IF EXISTS "Authenticated users can create clinic patient sources" ON public.patient_sources;
DROP POLICY IF EXISTS "Authenticated users can update clinic patient sources" ON public.patient_sources;
DROP POLICY IF EXISTS "Authenticated users can delete clinic patient sources" ON public.patient_sources;

CREATE POLICY "Authenticated users can read clinic patient sources"
ON public.patient_sources FOR SELECT TO authenticated
USING (public.is_clinic_member(clinic_id));

-- INSERT enforces that caller belongs to clinic_id AND referenced patient belongs to the SAME clinic_id
CREATE POLICY "Authenticated users can create clinic patient sources"
ON public.patient_sources FOR INSERT TO authenticated
WITH CHECK (
    public.is_clinic_member(clinic_id)
    AND EXISTS (
        SELECT 1 FROM public.patients p
        WHERE p.id = patient_sources.patient_id AND p.clinic_id = patient_sources.clinic_id
    )
);

-- UPDATE enforces that caller belongs to clinic_id AND referenced patient belongs to the SAME clinic_id
CREATE POLICY "Authenticated users can update clinic patient sources"
ON public.patient_sources FOR UPDATE TO authenticated
USING (public.is_clinic_member(clinic_id))
WITH CHECK (
    public.is_clinic_member(clinic_id)
    AND EXISTS (
        SELECT 1 FROM public.patients p
        WHERE p.id = patient_sources.patient_id AND p.clinic_id = patient_sources.clinic_id
    )
);

CREATE POLICY "Authenticated users can delete clinic patient sources"
ON public.patient_sources FOR DELETE TO authenticated
USING (public.is_clinic_member(clinic_id));

COMMIT;
