-- ============================================================
-- Clinic Photos (Doctor Clinical Photo Capture App)
-- Canonical patient identity + clinic membership + external source mappings
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- 1. CLINICS
-- ============================================================
-- The clinic is the shared tenant/data boundary.
-- A clinic can have multiple authorized Google/Supabase accounts.
CREATE TABLE IF NOT EXISTS clinics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- 2. CLINIC MEMBERSHIP
-- ============================================================
-- Maps authenticated users (auth.users.id) to clinics with roles.
-- Multiple Google accounts map to the SAME clinic.
CREATE TABLE IF NOT EXISTS clinic_members (
    clinic_id UUID NOT NULL REFERENCES clinics(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'staff' CHECK (role IN ('owner', 'admin', 'staff')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (clinic_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_clinic_members_user_id ON clinic_members (user_id);
CREATE INDEX IF NOT EXISTS idx_clinic_members_clinic_id ON clinic_members (clinic_id);

-- ============================================================
-- 3. PATIENTS
-- ============================================================
-- Canonical patient entity in Supabase.
-- Belongs to a clinic (clinic_id).
CREATE TABLE IF NOT EXISTS patients (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    clinic_id UUID NOT NULL REFERENCES clinics(id) ON DELETE CASCADE,

    display_name TEXT NOT NULL,
    normalized_name TEXT NOT NULL,

    phone_display TEXT,
    normalized_phone TEXT,

    -- Google Drive folder belonging to this patient
    drive_folder_id TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_patients_clinic_id
    ON patients (clinic_id);

CREATE INDEX IF NOT EXISTS idx_patients_business_identity
    ON patients (normalized_name, normalized_phone);

CREATE INDEX IF NOT EXISTS idx_patients_drive_folder
    ON patients (drive_folder_id);


-- ============================================================
-- 4. EXTERNAL PATIENT SOURCES
-- ============================================================
-- Maps external records such as Google Sheets Patient IDs
-- to the canonical Supabase patient within a specific clinic.
CREATE TABLE IF NOT EXISTS patient_sources (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    clinic_id UUID NOT NULL REFERENCES clinics(id) ON DELETE CASCADE,

    patient_id UUID NOT NULL
        REFERENCES patients(id)
        ON DELETE CASCADE,

    source TEXT NOT NULL,
    external_id TEXT NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_patient_sources_clinic_source_external
        UNIQUE (clinic_id, source, external_id)
);

CREATE INDEX IF NOT EXISTS idx_patient_sources_clinic_id
    ON patient_sources (clinic_id);

CREATE INDEX IF NOT EXISTS idx_patient_sources_patient_id
    ON patient_sources (patient_id);


-- ============================================================
-- 5. ROW LEVEL SECURITY (RLS) & MEMBERSHIP FUNCTION
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_clinic_member(c_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.clinic_members
    WHERE clinic_id = c_id
      AND user_id = auth.uid()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.is_clinic_member(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_clinic_member(UUID) TO authenticated;

ALTER TABLE clinics ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinic_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE patients ENABLE ROW LEVEL SECURITY;
ALTER TABLE patient_sources ENABLE ROW LEVEL SECURITY;

-- Clinics RLS
CREATE POLICY "Members can view their clinics"
ON clinics FOR SELECT TO authenticated
USING (public.is_clinic_member(id));

-- Clinic Members RLS
CREATE POLICY "Members can view their memberships"
ON clinic_members FOR SELECT TO authenticated
USING (user_id = auth.uid() OR public.is_clinic_member(clinic_id));

-- Patients RLS
CREATE POLICY "Authenticated users can read clinic patients"
ON patients FOR SELECT TO authenticated
USING (public.is_clinic_member(clinic_id));

CREATE POLICY "Authenticated users can create clinic patients"
ON patients FOR INSERT TO authenticated
WITH CHECK (public.is_clinic_member(clinic_id));

CREATE POLICY "Authenticated users can update clinic patients"
ON patients FOR UPDATE TO authenticated
USING (public.is_clinic_member(clinic_id))
WITH CHECK (public.is_clinic_member(clinic_id));

CREATE POLICY "Authenticated users can delete clinic patients"
ON patients FOR DELETE TO authenticated
USING (public.is_clinic_member(clinic_id));

-- Patient Sources RLS
CREATE POLICY "Authenticated users can read clinic patient sources"
ON patient_sources FOR SELECT TO authenticated
USING (public.is_clinic_member(clinic_id));

-- INSERT with clinic consistency check
CREATE POLICY "Authenticated users can create clinic patient sources"
ON patient_sources FOR INSERT TO authenticated
WITH CHECK (
    public.is_clinic_member(clinic_id)
    AND EXISTS (
        SELECT 1 FROM public.patients p
        WHERE p.id = patient_id AND p.clinic_id = clinic_id
    )
);

-- UPDATE with clinic consistency check
CREATE POLICY "Authenticated users can update clinic patient sources"
ON patient_sources FOR UPDATE TO authenticated
USING (public.is_clinic_member(clinic_id))
WITH CHECK (
    public.is_clinic_member(clinic_id)
    AND EXISTS (
        SELECT 1 FROM public.patients p
        WHERE p.id = patient_id AND p.clinic_id = clinic_id
    )
);

CREATE POLICY "Authenticated users can delete clinic patient sources"
ON patient_sources FOR DELETE TO authenticated
USING (public.is_clinic_member(clinic_id));
