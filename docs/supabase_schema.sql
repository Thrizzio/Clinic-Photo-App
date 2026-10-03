-- Clinic Photo App
-- Canonical patient identity + external source mappings

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- 1. PATIENTS
-- ============================================================

CREATE TABLE IF NOT EXISTS patients (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    display_name TEXT NOT NULL,
    normalized_name TEXT NOT NULL,

    phone_display TEXT,
    normalized_phone TEXT,

    -- Google Drive folder belonging to this patient
    drive_folder_id TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_patients_business_identity
    ON patients (normalized_name, normalized_phone);

CREATE INDEX IF NOT EXISTS idx_patients_drive_folder
    ON patients (drive_folder_id);


-- ============================================================
-- 2. EXTERNAL PATIENT SOURCES
-- ============================================================
-- Maps external records such as Google Sheets Patient IDs
-- to the canonical Supabase patient.
--
-- Example:
-- source = 'google_sheets'
-- external_id = '1000048'
--
-- This does NOT become the patient's identity.

CREATE TABLE IF NOT EXISTS patient_sources (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    patient_id UUID NOT NULL
        REFERENCES patients(id)
        ON DELETE CASCADE,

    source TEXT NOT NULL,
    external_id TEXT NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_patient_sources_source_external
        UNIQUE (source, external_id)
);

CREATE INDEX IF NOT EXISTS idx_patient_sources_patient_id
    ON patient_sources (patient_id);


-- ============================================================
-- 3. ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE patients ENABLE ROW LEVEL SECURITY;
ALTER TABLE patient_sources ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 4. BASIC AUTHENTICATED-USER POLICIES
-- ============================================================
-- Multiple authenticated users can use the same database.
-- For the initial version, every authenticated app user can
-- access the shared patient database.
--
-- This is intentionally simple. Per-user/per-clinic ownership
-- can be added later if the product requires it.

DROP POLICY IF EXISTS "Authenticated users can read patients" ON patients;
DROP POLICY IF EXISTS "Authenticated users can create patients" ON patients;
DROP POLICY IF EXISTS "Authenticated users can update patients" ON patients;
DROP POLICY IF EXISTS "Authenticated users can delete patients" ON patients;
DROP POLICY IF EXISTS "Authenticated users can read clinic patients" ON patients;
DROP POLICY IF EXISTS "Authenticated users can create clinic patients" ON patients;
DROP POLICY IF EXISTS "Authenticated users can update clinic patients" ON patients;
DROP POLICY IF EXISTS "Authenticated users can delete clinic patients" ON patients;

CREATE POLICY "Authenticated users can read patients"
ON patients
FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Authenticated users can create patients"
ON patients
FOR INSERT
TO authenticated
WITH CHECK (true);

CREATE POLICY "Authenticated users can update patients"
ON patients
FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);

CREATE POLICY "Authenticated users can delete patients"
ON patients
FOR DELETE
TO authenticated
USING (true);


DROP POLICY IF EXISTS "Authenticated users can read patient sources" ON patient_sources;
DROP POLICY IF EXISTS "Authenticated users can create patient sources" ON patient_sources;
DROP POLICY IF EXISTS "Authenticated users can update patient sources" ON patient_sources;
DROP POLICY IF EXISTS "Authenticated users can delete patient sources" ON patient_sources;
DROP POLICY IF EXISTS "Authenticated users can read clinic patient sources" ON patient_sources;
DROP POLICY IF EXISTS "Authenticated users can create clinic patient sources" ON patient_sources;
DROP POLICY IF EXISTS "Authenticated users can update clinic patient sources" ON patient_sources;
DROP POLICY IF EXISTS "Authenticated users can delete clinic patient sources" ON patient_sources;

CREATE POLICY "Authenticated users can read patient sources"
ON patient_sources
FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Authenticated users can create patient sources"
ON patient_sources
FOR INSERT
TO authenticated
WITH CHECK (true);

CREATE POLICY "Authenticated users can update patient sources"
ON patient_sources
FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);

CREATE POLICY "Authenticated users can delete patient sources"
ON patient_sources
FOR DELETE
TO authenticated
USING (true);
