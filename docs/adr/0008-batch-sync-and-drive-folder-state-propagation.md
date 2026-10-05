# 0008. Batch Sync Optimization and Cross-Device Drive Folder State Propagation

Date: 2026-10-05

## Status
Accepted

## Context
1. **Sync Latency (N+1 Queries)**: During patient synchronization, `PatientSyncService` performed up to 5 sequential network round-trips per patient inside loops (`getPatientIdBySource`, `getPatientById`, `findPatientByBusinessIdentity`, `upsertPatient`, `linkPatientSource`). For 77 patients, this resulted in ~385 sequential HTTP requests, causing patient sync to take an unreasonably long time. Furthermore, opening `PatientsScreen` unconditionally triggered a full Google Sheets import (`_syncSheetInBackground(forceFullSync: true)`), adding unnecessary external network overhead on every screen mount.
2. **Cross-Device Drive Folder State Failure**: When Phone A created a Google Drive folder for a patient (`drive_folder_id = X`), the folder was saved locally in SQLite, but Phone A did not mark the patient as `pending_cloud` or push it immediately to Supabase. Even when uploaded, `RemoteSupabasePatientService.upsertPatient` included `'drive_folder_id': null` when null/empty, which caused PostgREST `onConflict: 'id'` to overwrite valid cloud folder IDs with `NULL`. Furthermore, `Patient.merge` defaulted folder status to incoming sheet rows (which lack folder IDs), resetting `folderStatus` to `FolderStatus.missing`. Consequently, Phone B saw "Folder auto-creates on photo capture" instead of "Folder ready".

## Decision
We separated sync responsibilities, eliminated N+1 network calls with batching and in-memory reconciliation, and established strict non-destructive folder merge rules:

1. **Separation of Sync Responsibilities**:
   - **Normal Patient Database Sync (`SQLite ↔ Supabase`)**: Runs automatically in the background on screen launch (`_syncPatientDatabaseInBackground()`). It exchanges records solely between SQLite and Supabase. It NEVER queries Google Drive API and NEVER queries Google Sheets.
   - **Google Sheets Import**: Only triggered explicitly when the user requests a refresh or modifies sheet settings.
   - **Google Drive Operations**: Isolated to photo capture, upload, and patient folder initialization on demand. Never executed inside database sync loops.
2. **Batching and In-Memory Indexing**:
   - `SupabasePatientService` and `AppDatabase` now support bulk operations: `upsertPatients(List<Patient>)`, `linkPatientSources(List<PatientSourceRecord>)`, `fetchAllPatientSources()`, and `getAllPatientSources()`.
   - `reconcileSheetPatients` and `syncLocalWithSupabase` pre-fetch cloud and local tables in 2 round-trips, index them in memory by source ID and normalized business identity (name + phone), reconcile mappings locally in milliseconds, and commit bulk upserts to Supabase and SQLite. Network requests for 77 patients dropped from ~385 down to ~2–4.
3. **Authoritative Non-Destructive Drive Folder Rules**:
   - **PostgREST Safety**: `upsertPatient` and `upsertPatients` omit `'drive_folder_id'` when null/empty. PostgREST `ON CONFLICT (id) DO UPDATE` will NEVER overwrite an existing cloud Drive folder with `NULL`.
   - **Model Merge**: `Patient.merge` preserves valid existing folder IDs if incoming is null, preserves incoming folder IDs if existing is null, and flags `FolderStatus.conflict` only if both exist and differ.
   - **Immediate Push on Creation**: When `PatientFolderService.getOrCreatePatientFolder` creates a Drive folder, it saves to SQLite as `pending_cloud` and immediately pushes the update to Supabase if online.
4. **Authoritative UI Folder State**:
   - `PatientTile` derives folder readiness directly from `patient.driveFolderId != null && patient.driveFolderId!.trim().isNotEmpty`. If a Drive folder ID exists, the UI immediately shows "Folder ready" and folder action buttons, regardless of sheet status.

## Consequences
- Patient list synchronization is near-instantaneous (down from ~385 sequential round-trips to ~2-4 bulk requests).
- Google Drive API is never hit during patient list or background database syncs.
- When Phone A creates a Drive folder, Phone B receives the folder ID on its next cloud sync and renders "Folder ready" without user intervention.
- Offline-first guarantees are preserved: SQLite cached patients render immediately; background sync reconciles transparently.
