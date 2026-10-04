# Architecture

## Status
Version 5 (V5) — Flutter Android single-doctor clinical photo capture app. V5 establishes a robust four-component architecture separating canonical cloud identity, offline-first local working storage, external operational imports, and cloud photo storage:
1. **Supabase**: Canonical cloud store for patient identity and external source mappings (`patients` and `patient_sources`). Configured for single-clinic direct access using the anon key with `clinic_id NOT NULL DEFAULT 'c0000000-0000-0000-0000-000000000001'` (no Supabase Auth or email/password login required for MVP).
2. **SQLite**: Offline working store, local patient cache, and persistent photo capture & upload queue.
3. **Google Sheets**: External operational import stream (read-only clinic spreadsheet).
4. **Google Drive**: Clinical photo storage organized by patient folders (`<Patient Name> - <Phone Number>` or legacy `<Legacy Patient ID> - <Patient Name>`).

Key V5 capabilities:
- Canonical UUID patient identity with business identity deduplication `(normalized_name, normalized_phone)`.
- Invariant: doctor-created patients are NEVER deleted by Google Sheets synchronization.
- Day 1 in-app creation + Day 5 Google Sheet addition links seamlessly into the canonical UUID record without duplicates.
- Offline-first photo capture: shutter saves to disk and SQLite immediately; renders immediately in gallery with status badges (`Pending`, `Uploading`, `Uploaded`, `Failed`); uploads asynchronously in background.
- Local photo disk cache retention for instant offline viewing.
- Unassigned capture sessions and multi-select photo moves with zero cellular bandwidth re-upload.
- Authoritative IST chronology (`UTC+05:30`) and Material 3 design with dark mode.

---

## Component Boundaries & Responsibilities

```
+--------------------------------------------------------------------------------+
|                               DOCTOR MOBILE APP                                |
|                                                                                |
|  +--------------------------------+       +---------------------------------+  |
|  |     UI Layer (Screens/Widgets) |       |  UploadQueueService (Worker)    |  |
|  |  - Instant shutter capture     |       |  - Background upload loop       |  |
|  |  - Immediate gallery rendering |       |  - Auto-create Drive folders    |  |
|  |  - Badges (Pending/Uploaded)   |       |  - Exponential retry & backoff  |  |
|  +--------------------------------+       +---------------------------------+  |
|                   |                                       |                    |
|                   v                                       v                    |
|  +--------------------------------------------------------------------------+  |
|  |                     SQLite AppDatabase (Local Cache)                     |  |
|  |  - patients (UUID, name, phone, source, drive_folder_id, sync_status)   |  |
|  |  - patient_sources (id, patient_id, source, external_id, created_at)    |  |
|  |  - capture_sessions (unassigned & assigned capture sessions)             |  |
|  |  - uploads (upload queue with local_path, drive_file_id, status)         |  |
|  +--------------------------------------------------------------------------+  |
+--------------------------------------------------------------------------------+
       |                                      |                         |
       | Sync / Match                         | Sync Patients           | Upload Photos
       v                                      v                         v
+-----------------------+          +--------------------+    +-------------------+
|  Supabase (Cloud DB)  |          |   Google Sheets    |    |   Google Drive    |
| - Canonical Patients  |          | - External stream  |    | - Patient Folders |
| - Source Mappings     |          | - Clinic Visits    |    | - Clinical Photos |
| - Multi-device Truth  |          | - Read-only import |    | - Unassigned Root |
+-----------------------+          +--------------------+    +-------------------+
```

---

## Modules

- `lib/config.dart`: App-level constants, Drive scopes, table definitions, and sheet column headers.
- `lib/models/`:
  - `patient.dart`: Canonical patient model (`id` [UUID], `displayName`, `normalizedName`, `phoneDisplay`, `normalizedPhone`, `legacyPatientId`, `source: clinicSheet | doctorCreated | merged`, `driveFolderId`, `folderStatus`, `syncStatus`, `isUploadable`, `matchesBusinessIdentity`).
  - `capture_session.dart`: Capture session model (`id`, `patientId`, `createdAt`, `status`, `photoCount`, `driveFolderId`).
  - `upload_item.dart`: Persistent photo capture & upload queue record (`id`, `sessionId`, `patientId`, `driveFolderId`, `localPath`, `fileName`, `status: pending | waiting | uploading | uploaded | failed | unassigned`, `retryCount`, `lastError`, `driveFileId`, `capturedAt`, `sequenceNumber`).
  - `clinic_config.dart`: Settings model (`spreadsheetId`, `spreadsheetUrl`, `sheetTabName`, `parentDriveFolderId`, `hasCompletedSetup`, `lastPatientSync`, `lastSyncedRow`, `lastFullSync`).
- `lib/services/`:
  - `supabase_auth_service.dart`: (Deprecated for MVP single-clinic architecture). In the single-clinic MVP, patient cloud sync directly utilizes the Supabase client with the project anon key and default clinic ID (`c0000000-0000-0000-0000-000000000001`). No user password or Supabase Auth session is required. Google Sign-In is preserved solely for Google Drive and Google Sheets access.
  - `supabase_patient_service.dart`: Supabase client managing canonical `patients` and `patient_sources` tables, remote business identity lookup, and cross-source reconciliation.
  - `patient_sync_service.dart`: Reconciles external Google Sheets rows with Supabase canonical patients and updates SQLite local cache with truthful sync reporting (detects RLS 42501 violations).
  - `database.dart`: SQLite database (schema v8) with `patients`, `patient_sources`, `capture_sessions`, and `uploads` tables. `replacePatients()` is deprecated with zero production callers; Sheet sync strictly uses `upsertPatients()`. Patient list is ordered alphabetically (`display_name COLLATE NOCASE ASC, name COLLATE NOCASE ASC`). Crash recovery resets `uploading` to `waiting`.
  - `upload_queue.dart`: Manages disk persistence (`photo_queue/`), SQLite upload state machine, background uploading, Drive folder auto-creation for offline captures, unassigned sessions, and session assignment.
  - `patient_folder_service.dart`: Idempotent Google Drive folder resolver (`<Patient Name> - <Phone Number>` or legacy `<Legacy Patient ID> - <Patient Name>`).
  - `drive.dart`: Google Drive API v3 client (folder queries, uploads, server-side moves, deletions, thumbnail streaming).
  - `sheets.dart`: Google Sheets API v4 metadata discovery, dynamic headers, and read-only import stream.
  - `google_auth.dart`: Google Sign-In 7.x wrapper and authenticated HTTP client for Google APIs (Google Drive & Sheets).
  - `config_service.dart`: SharedPreferences settings persistence, doctor credentials storage, and reactive `themeModeNotifier`.
- `lib/screens/`:
  - `welcome_screen.dart`: Welcome & Google sign-in.
  - `clinic_setup_screen.dart`: Spreadsheet configuration and parent Drive folder setup.
  - `patients_screen.dart`: Search-first patient selector (All, Name, Phone filters), top-right action buttons, unassigned sessions FAB, and doctor patient creation.
  - `camera_screen.dart`: Rapid offline-first clinical photo capture with zero blocking shutter.
  - `patient_photos_screen.dart`: Gallery rendering local disk cache immediately with upload status badges, background Drive sync, multi-select moves, and safe deletions.
  - `unassigned_photos_screen.dart`: Unassigned photo sessions list with thumbnail strip, photo counts, and assignment dialog.
  - `session_detail_screen.dart`: Detailed inspection for unassigned sessions.
  - `settings_screen.dart`: Theme settings, clinic configuration, manual reconciliation sync, and sign-out.

---

## Data & Control Flow

### 1. Canonical Patient Identity & Deduplication
- Primary key is an immutable UUID v4 (`Patient.id`). External sheet IDs (e.g. `1000001`) are NEVER used as `patients.id`.
- Business identity is the tuple `(normalized_name, normalized_phone)`.
- When a doctor creates a patient in-app (`+ New Patient`), the patient is saved locally in SQLite (`syncStatus: pending_cloud`) and pushed to Supabase when online.
- When Google Sheets is imported or synchronized:
  1. Rows without a usable patient name are ignored; placeholder "Name unavailable" patients are NEVER created.
  2. `PatientSyncService.reconcileSheetPatients` processes valid incoming sheet rows.
  3. For each row, it checks Supabase/SQLite for existing match by:
     - External source mapping (`source: 'google_sheets'`, `external_id: legacyPatientId`).
     - Business identity `(normalized_name, normalized_phone)`.
  4. If matched, the canonical UUID is preserved, legacy ID is linked via `patient_sources`, and `source` updates to `merged`.
  5. If new, a canonical UUID is generated and `patient_sources` record is linked.
  6. **Hard Invariant**: Google Sheets sync NEVER deletes doctor-created patients or patients absent from the sheet.

### 2. Offline-First Photo Capture & Asynchronous Upload
- Shutter click immediately writes image file to private app storage:
  `photo_queue/patients/<patientId>/<sessionId>/YYYYMMDD_HHMMSS_SSS_<sequence>.jpg`.
- Upload record is inserted into SQLite `uploads` table:
  - If patient has a Drive folder: `status = UploadStatus.waiting`.
  - If patient does NOT have a Drive folder yet: `status = UploadStatus.pending`.
- Camera UI returns immediately without waiting for network or Drive operations.
- Patient photo gallery opens immediately and reads local SQLite uploads.
- Photos render from local disk instantly with badge overlays:
  - `Pending` (amber): Waiting for patient Drive folder creation or network.
  - `Uploading` (blue with spinner): Currently transferring to Google Drive.
  - `Uploaded` (green check): Successfully uploaded to Drive.
  - `Failed` (red error): Upload failed after max retries; tap to retry.
- When online, `UploadQueueService` background worker:
  1. Creates patient Drive folder if missing (`patientFolderService.getOrCreatePatientFolder`).
  2. Uploads file to Drive via `driveService.uploadPhoto`.
  3. Retains local disk file as local cache for offline viewing.
  4. Updates SQLite record with `driveFileId` and `status = UploadStatus.uploaded`.

### 3. Viewer Actions & Unassigned Session Synchronization
- Multi-Select Move: Doctor can select photos in patient gallery and move them to an unassigned session. Drive file is moved server-side; local cached file is moved to unassigned directory; SQLite record is updated atomically.
- Session Assignment: Unassigned sessions can be assigned to existing or offline patients. If target patient lacks a Drive folder, local photos transition to `pending` and upload when online.

### 4. Patient Deletion, Offline Queue & Cross-Device Sync
- **Patient Deletion Invariants**:
  - Anyone using the app is permitted to delete patients in the single-clinic architecture.
  - **Drive Safety Invariant**: Deleting a patient strictly NEVER deletes, moves, or touches their Google Drive folders or photos. Drive deletion APIs are never called during patient deletion.
  - Deleting a patient removes the patient locally from SQLite, removes local source mappings, and deletes the patient and `patient_sources` from Supabase (handled in foreign-key order: source mappings first, then patient row).
- **Offline Deletion Queue**:
  - If the device is offline when a user deletes a patient, the patient is removed from local SQLite immediately and queued in the `pending_deletions` table.
  - When connectivity is restored, `PatientSyncService.syncLocalWithSupabase()` retries all queued cloud deletions and removes them upon successful Supabase response.
- **Cross-Device Deletion Propagation**:
  - When Device A deletes a patient in Supabase, Device B learns of this deletion during its next `syncLocalWithSupabase()` pass.
  - If a local patient has `syncStatus == 'synced'` but is absent from Supabase, Device B recognizes it as a remote deletion, deletes the patient locally from SQLite, and records tombstones. Device B does NOT recreate the patient in Supabase.
- **Google Sheets Resurrection Prevention (Tombstones)**:
  - When a patient is deleted, their canonical UUID and external source mappings (e.g. `(google_sheets, legacyPatientId)`) are recorded in `deleted_patient_tombstones`.
  - Normal Sheets reconciliation checks `isSourceDeleted` and ignores rows matching tombstoned patients, preventing accidental delete → sync → resurrect loops.