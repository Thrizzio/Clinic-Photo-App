# 0007. Single-Clinic Direct Database Architecture for MVP

Date: 2026-10-04

## Status
Accepted

## Context
In ADR 0006, Supabase authentication was introduced to enforce PostgreSQL Row-Level Security (`TO authenticated`) with multi-tenant clinic memberships (`clinic_members`) and doctor email/password authentication.
In practice for the initial clinic deployment:
1. The app serves a single doctor/clinic team accessing a dedicated clinic database.
2. Managing a secondary Supabase authentication flow (separate from Google Sign-In used for Google Drive and Google Sheets) introduced setup friction, auth initialization failures, and unneeded complexity.
3. The clinic requires multiple mobile devices to synchronize the same patient roster without requiring doctors or clinic staff to register separate Supabase user accounts or enter credentials during setup.

## Decision
For the MVP single-clinic deployment, we simplify the cloud database architecture:
1. **Single Clinic Model**: A default single clinic record is established in Supabase (`id = 'c0000000-0000-0000-0000-000000000001'`).
2. **Schema Invariant (`clinic_id NOT NULL`)**: `clinic_id` on `patients` and `patient_sources` remains `NOT NULL`, backed by a database default `DEFAULT 'c0000000-0000-0000-0000-000000000001'::uuid`. All rows inserted automatically inherit the clinic ID.
3. **Anon Key Direct Access**: Supabase Row-Level Security policies on `patients` and `patient_sources` allow `SELECT`, `INSERT`, `UPDATE`, and `DELETE` directly to the `anon` role for the single clinic default.
4. **No Supabase Auth Flow**: Eliminates `SupabaseAuthService` from the app lifecycle, eliminating doctor email/password forms and token exchange complexity.
5. **Google Sign-In Isolation**: Google Sign-In remains solely responsible for authenticating with Google Drive (photo storage) and Google Sheets (patient import).
6. **Revoked Tenant Tables**: All access to `clinics` and `clinic_members` is revoked from the `anon` role.

## Consequences
- Multi-device patient sync works out of the box immediately using the project `anonKey` without requiring doctor user registration or login.
- Setup is simplified: doctor signs in with Google once to authorize Sheets/Drive, enters the Sheet/Drive IDs, and starts using the app immediately.
- SQLite remains the authoritative offline-first cache and photo queue.
- Re-enabling multi-clinic isolation in the future is straightforward: `clinic_id` is already present, indexed, and `NOT NULL` on all tables.
