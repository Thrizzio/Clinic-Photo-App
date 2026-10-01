-- Supabase PostgreSQL Schema for Clinic Photos App (V5)
-- Execute this script in your Supabase SQL Editor.

-- 1. Enable UUID generation if not already available
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 2. Patients table (Canonical cloud patient identity)
CREATE TABLE IF NOT EXISTS patients (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    display_name TEXT NOT NULL,
    normalized_name TEXT NOT NULL,
    phone_display TEXT,
    normalized_phone TEXT,
    drive_folder_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- Index for fast business identity matching: (normalized_name, normalized_phone)
CREATE INDEX IF NOT EXISTS idx_patients_business_id
ON patients (normalized_name, normalized_phone);

-- Index for Drive folder lookup
CREATE INDEX IF NOT EXISTS idx_patients_drive_folder
ON patients (drive_folder_id);

-- 3. Patient sources mapping table (Maps external system IDs, e.g. Sheets, to canonical patients)
CREATE TABLE IF NOT EXISTS patient_sources (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    source TEXT NOT NULL, -- e.g. 'google_sheets'
    external_id TEXT NOT NULL, -- e.g. '1000048'
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT uq_patient_sources_source_ext UNIQUE (source, external_id)
);

CREATE INDEX IF NOT EXISTS idx_patient_sources_patient_id
ON patient_sources (patient_id);

-- 4. Enable Row Level Security (RLS)
ALTER TABLE patients ENABLE ROW LEVEL SECURITY;
ALTER TABLE patient_sources ENABLE ROW LEVEL SECURITY;

-- 5. Policies for authenticated / anon clinic app users
-- In a private clinic application, allow read/write via anon key with clinic auth
CREATE POLICY "Allow clinic app all on patients"
ON patients FOR ALL
USING (true)
WITH CHECK (true);

CREATE POLICY "Allow clinic app all on patient_sources"
ON patient_sources FOR ALL
USING (true)
WITH CHECK (true);
