# Architecture

## Status
Version 5 (V5) — Flutter Android single-doctor clinical photo capture app. V5 establishes a robust four-component architecture separating canonical cloud identity, offline-first local working storage, external operational imports, and cloud photo storage:
1. **Supabase**: Canonical cloud store for patient identity and external source mappings (`patients` and `patient_sources`).
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
|  |  - patient_sources (patient_id, source_system, source_patient_id)        |  |
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
  - `supabase_patient_service.dart`: Supabase client managing canonical `patients` and `patient_sources` tables, remote business identity lookup, and cross-source reconciliation.
  - `patient_sync_service.dart`: Reconciles external Google Sheets rows with Supabase canonical patients and updates SQLite local cache.
  - `database.dart`: SQLite database (schema v8) with `patients`, `patient_sources`, `capture_sessions`, and `uploads` tables. Crash recovery resets `uploading` to `waiting`.
  - `upload_queue.dart`: Manages disk persistence (`photo_queue/`), SQLite upload state machine, background uploading, Drive folder auto-creation for offline captures, unassigned sessions, and session assignment.
  - `patient_folder_service.dart`: Idempotent Google Drive folder resolver (`<Patient Name> - <Phone Number>` or legacy `<Legacy Patient ID> - <Patient Name>`).
  - `drive.dart`: Google Drive API v3 client (folder queries, uploads, server-side moves, deletions, thumbnail streaming).
  - `sheets.dart`: Google Sheets API v4 metadata discovery, dynamic headers, and read-only import stream.
  - `google_auth.dart`: Google Sign-In 7.x wrapper and authenticated HTTP client.
  - `config_service.dart`: SharedPreferences settings persistence and reactive `themeModeNotifier`.
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
- Primary key is an immutable UUID v4 (`Patient.id`).
- Business identity is the tuple `(normalized_name, normalized_phone)`.
- When a doctor creates a patient in-app (`+ New Patient`), the patient is saved locally in SQLite (`syncStatus: pending_cloud`) and pushed to Supabase when online.
- When Google Sheets is imported or synchronized:
  1. `PatientSyncService.reconcileSheetPatients` processes incoming sheet rows.
  2. For each row, it checks Supabase/SQLite for existing match by:
     - External source mapping (`source_system: 'clinic_sheet'`, `source_patient_id: legacyPatientId`).
     - Business identity `(normalized_name, normalized_phone)`.
  3. If matched, the canonical UUID is preserved, legacy ID is linked, and `source` updates to `merged`.
  4. If new, a new canonical UUID is assigned.
  5. **Hard Invariant**: Google Sheets sync NEVER deletes doctor-created patients or patients absent from the sheet.

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