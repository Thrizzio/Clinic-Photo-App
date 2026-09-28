# Architecture

## Status
Version 2 (V2) Complete — Flutter Android single-doctor clinical photo capture app with direct Google OAuth, Sheets API, Drive API, Visits deduplication, Drive folder resolution, Workflow B unassigned capture sessions, and persistent SQLite upload queue.

## Modules
- `lib/config.dart`: Developer constants (Google OAuth scopes, headers: `Patient ID`, `Patient Name`, `Photos (Drive)`, `Drive Folder ID`). No clinic secrets or sheet IDs.
- `lib/models/`:
  - `patient.dart`: Domain model (`id`, `name`, `driveFolderId`, `folderStatus: available | missing | conflict`, `isUploadable`, `Patient.merge`).
  - `capture_session.dart`: Unassigned/assigned photo capture session (`id`, `patientId`, `createdAt`, `status`, `photoCount`).
  - `upload_item.dart`: Persistent queue item (`id`, `sessionId`, `patientId`, `driveFolderId`, `localPath`, `fileName`, `status`, `retryCount`, `lastError`, `driveFileId`, `createdAt`).
  - `clinic_config.dart`: In-app clinic settings (`spreadsheetId`, `spreadsheetUrl`, `sheetTabName`, `hasCompletedSetup`, `lastPatientSync`, `lastSyncedRow`, `lastFullSync`).
- `lib/services/`:
  - `google_auth.dart`: Google Sign-In 7.x wrapper & authenticated HTTP client (`extension_google_sign_in_as_googleapis_auth`).
  - `config_service.dart`: SharedPreferences persistence for clinic configuration, `lastSyncedRow`, and `lastFullSync`.
  - `sheets.dart`: Google Sheets API v4 metadata discovery (tabs), dynamic header row & column discovery (`discoverHeaderIndices`), header normalization, Drive folder URL parsing (`extractDriveFolderId`), Visits deduplication (`resolvePatientsFromVisits`), incremental sync (`fetchIncrementalPatients`), and full reconciliation (`validateAndFetchPatients`).
  - `drive.dart`: Google Drive API v3 photo uploader into target folder ID.
  - `database.dart`: Local SQLite database (v2 schema) with `patients`, `capture_sessions`, and `uploads` tables. Crash recovery resets `uploading` to `waiting` (leaving `unassigned` untouched).
  - `upload_queue.dart`: Asynchronous upload loop, gentle bounded retries, connectivity change listener, unassigned capture sessions, session assignment, and instant camera return.
- `lib/screens/`:
  - `welcome_screen.dart`: Welcome and Google account sign-in.
  - `clinic_setup_screen.dart`: Multi-step setup wizard (URL input, tab picker, visits column/folder validation summary).
  - `patients_screen.dart`: Search-first patient selector, `+ New / Unassigned Patient` action, `Unassigned Photos (N)` banner, background incremental sync, and minimal upload status indicator.
  - `camera_screen.dart`: Rapid clinical photo capture supporting both Existing Patient Mode (Workflow A) and Unassigned Session Mode (Workflow B) with non-blocking shutter.
  - `unassigned_photos_screen.dart`: Lists unassigned capture sessions with timestamps, photo counts, and quick actions (`[View Photos]`, `[Assign]`).
  - `session_detail_screen.dart`: Inspection screen showing local photo thumbnails and `[Assign to Patient]` bottom bar.
  - `settings_screen.dart`: Database info, `Sync Now (Full Reconciliation)`, last synced row count, safe reconfiguration, and sign-out.
- `lib/widgets/`:
  - `patient_tile.dart`: Clean, clinical patient list item with status badges for `missing` or `conflict` Drive folders.
  - `unassigned_session_tile.dart`: Session card with formatted timestamp, thumbnail counts, and action buttons.
  - `patient_assignment_sheet.dart`: Searchable modal bottom sheet to select and validate patient for session assignment.
  - `upload_status.dart`: Minimal status indicator pill ("↑ 2 uploading", "✓ All photos uploaded", "! 1 failed [Retry]").

## Data & Control Flow
1. **Google OAuth**: Doctor authorizes once. Credentials securely managed by Google Identity Services on Android.
2. **Visits Sheet as Source of Truth**:
   - Single data source is the clinic's `Visits` table.
   - Multiple rows with the same `Patient ID` are deduplicated into one local `Patient` record in SQLite.
   - Drive folder URLs (`Photos (Drive)` or `Drive Folder ID`) are normalized via `extractDriveFolderId()`.
   - Patients with repeated identical folders -> `FolderStatus.available` (`isUploadable = true`).
   - Patients with some blank rows + 1 valid folder -> `FolderStatus.available` (`isUploadable = true`).
   - Patients with different non-empty folders -> `FolderStatus.conflict` (`isUploadable = false`, blocked from capture).
   - Patients with blank folders across all visits -> `FolderStatus.missing` (`isUploadable = false`, blocked from capture).
3. **Incremental Sync & Full Reconciliation**:
   - App startup loads cached SQLite patients immediately (<50ms).
   - Background sync reads only newly appended rows (`A{lastSyncedRow + 1}:Z`), merging updates via `Patient.merge`.
   - Settings offers `Sync Now (Full Reconciliation)` to re-read all rows from row 1.
4. **Workflow A (Existing Patient Capture)**:
   - Doctor searches and taps patient -> `CameraScreen` opens -> Shutter press saves image to `photo_queue/` -> SQLite inserts record (`waiting`) -> Background loop uploads to patient's Drive folder.
5. **Workflow B (Unassigned Photo Sessions)**:
   - Doctor taps `+ New / Unassigned Patient` -> `CaptureSession` created in SQLite -> Camera opens immediately.
   - Photos saved in `photo_queue/unassigned/<session_id>/<photo_uuid>.jpg` with `UploadStatus.unassigned`.
   - Sessions have no expiration; survive restarts, battery dying, or days passing.
   - Doctor inspects thumbnails in `SessionDetailScreen` and assigns to a patient at any time via `PatientAssignmentSheet`.
   - On assignment, records atomically transition to `waiting` with target `driveFolderId`, waking the upload loop.
6. **Confirmed Drive Upload Clean-up**:
   - When Drive API confirms file creation, SQLite record and local file are deleted.
   - For session items, once all photos in the session are confirmed, the session row and its private storage directory are deleted.