# 0006. V5 Supabase Canonical Patient Identity, Offline SQLite Cache, and Sheets Integration

Date: 2026-10-02

## Status
Accepted

## Context
In V4, the application made strides toward UUID identity and business matching `(normalized_name, normalized_phone)`. However, the architecture retained several lingering assumptions:
1. `replacePatients` in SQLite wiped the `patients` table on full Google Sheets synchronization, deleting any doctor-created patients that did not yet appear in Google Sheets.
2. Google Sheets was treated as an implicit authority on whether a patient should exist in the local database.
3. `enqueuePhoto` blocked photo capture if `patient.isUploadable` was false (i.e. if the patient's Google Drive folder had not yet been created online).
4. `upload_queue.dart` deleted local photo files immediately upon successful upload to Google Drive, preventing offline-first viewing in the patient gallery.
5. `patient_photos_screen.dart` only listed photos from Google Drive via `listPatientPhotos`, displaying an empty gallery when offline or when a Drive folder was absent.

## Decision
We decouple the four core data responsibilities:
1. **Supabase / PostgreSQL**: The canonical cloud patient identity store owning master records (`patients`: `id` UUID, `display_name`, `normalized_name`, `phone_display`, `normalized_phone`, `drive_folder_id`) and external identity mappings (`patient_sources`: `patient_id` UUID, `source`, `external_id`).
2. **SQLite (v8)**: Offline-first application working store and cache. Mirrors canonical UUIDs, caches `patient_sources`, tracks local photo files and upload/move/delete queues. SQLite patient ID is always the canonical Supabase UUID.
3. **Google Sheets**: External operational integration. Data from Google Sheets is reconciled into Supabase and SQLite. Sheets absence **NEVER** deletes canonical patients.
4. **Google Drive**: Pure clinical photo storage (patient folders, unassigned session folders). Folders are storage pointers, not technical identity.
5. **Offline-First Photo Persistence**:
   - Camera shutter saves files immediately to private app storage (`photo_queue/patients/<patient_id>/`).
   - Photos can be taken immediately regardless of Drive folder availability (`status: pending`).
   - Gallery renders local photos immediately from SQLite and local files, exposing upload status badges.
   - After upload confirmation, local files are retained in app storage as a reliable offline cache.

## Consequences
- Doctor-created patients remain permanently in SQLite and Supabase; subsequent Google Sheets synchronizations merge sources without deleting patients.
- Patients can be created and photographed completely offline.
- Zero cellular/network blocking on shutter press or gallery opening.
- External clinic Patient IDs (e.g. `1000048`) are mapped deterministically via `patient_sources` rather than acting as primary keys.
