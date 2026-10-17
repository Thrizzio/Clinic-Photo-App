-- Migration 0004: Add last_viewed_at column to patients table
-- Supports deterministic recent-activity sorting while keeping local viewing activity
-- distinct from clinical-record modification timestamps (updated_at).

ALTER TABLE public.patients
ADD COLUMN IF NOT EXISTS last_viewed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_patients_last_viewed_at
    ON public.patients (last_viewed_at);
