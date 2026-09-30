# Architecture

## Status
Version 3 (V3) — Flutter Android single-doctor clinical photo capture app with direct Google OAuth, Sheets API, Drive API, Visits deduplication, app-owned idempotent patient Drive folder creation, Google Sheets link writeback, sequence-numbered photo naming, unassigned capture sessions, photo deletion review, patient photo viewer, and persistent SQLite upload queue.

## Modules
- `lib/config.dart`: Developer constants (Google OAuth scopes, headers: `Patient ID`, `Patient Name`, `Photos (Drive)`, `Drive Folder ID`). No clinic secrets or sheet IDs.
- `lib/models/`:
  - `patient.dart`: Canonical domain model (`id`, `name`, `phoneNumber`, `phoneNumberNormalized`, `driveFolderId`, `folderStatus: available | missing | creating | conflict`, `isUploadable`, `hasValidName`, `displayName`, `Patient.merge`, `updatedAt`).
  - `capture_session.dart`: Unassigned/assigned photo capture session (`id`, `patientId`, `createdAt`, `status`, `photoCount`).
  - `upload_item.dart`: Persistent queue item (`id`, `sessionId`, `patientId`, `driveFolderId`, `localPath`, `fileName`, `status`, `retryCount`, `lastError`, `driveFileId`, `createdAt`, `capturedAt`, `sequenceNumber`).
  - `clinic_config.dart`: In-app clinic settings (`spreadsheetId`, `spreadsheetUrl`, `sheetTabName`, `parentDriveFolderId`, `hasCompletedSetup`, `lastPatientSync`, `lastSyncedRow`, `lastFullSync`).
- `lib/services/`:
  - `google_auth.dart`: Google Sign-In 7.x wrapper & authenticated HTTP client (`extension_google_sign_in_as_googleapis_auth`).
  - `config_service.dart`: SharedPreferences persistence for clinic configuration, `parentDriveFolderId`, `lastSyncedRow`, and `lastFullSync`.
  - `sheets.dart`: Google Sheets API v4 metadata discovery (tabs), dynamic header row & column discovery (`discoverHeaderIndices` with phone alias discovery), header normalization, Drive folder URL parsing (`extractDriveFolderId`), Visits deduplication (`resolvePatientsFromVisits`), incremental sync (`fetchIncrementalPatients`), full reconciliation (`validateAndFetchPatients`), and blank row folder URL writeback (`writePatientFolderUrl`).
  - `drive.dart`: Google Drive API v3 photo uploader, folder search (`findFoldersByName`), folder creator (`createFolder`), and patient photo listing (`listPatientPhotos`).
  - `patient_folder_service.dart`: Orchestrator for idempotent 9-step `getOrCreatePatientFolder(patient)`.
  - `database.dart`: Local SQLite database (v6 schema with phone search indexes) supporting multi-mode local search (`SearchFilterMode: all, name, phone, patientId`) across indexed `patients`, `capture_sessions`, and `uploads` tables. Crash recovery resets `uploading` to `waiting` (leaving `unassigned` untouched).
  - `upload_queue.dart`: Asynchronous upload loop, gentle bounded retries, connectivity change listener, unassigned capture sessions, session assignment with deterministic photo renaming, and instant camera return.
- `lib/screens/`:
  - `welcome_screen.dart`: Welcome and Google account sign-in.
  - `clinic_setup_screen.dart`: Multi-step setup wizard (URL input, tab picker, header validation, parent Drive folder setup).
  - `patients_screen.dart`: Search-first patient selector, `+ New / Unassigned Patient` action, `Unassigned Photos (N)` banner, background incremental sync, and minimal upload status indicator.
  - `camera_screen.dart`: Rapid clinical photo capture supporting both Existing Patient Mode (Workflow A) and Unassigned Session Mode (Workflow B) with sequence numbering and non-blocking shutter.
  - `unassigned_photos_screen.dart`: Lists unassigned capture sessions with timestamps, photo counts, and quick actions (`[View Photos]`, `[Assign]`).
  - `session_detail_screen.dart`: Inspection screen showing local photo thumbnails, multi-select deletion mode, and `[Assign to Patient]` bottom bar.
  - `patient_photos_screen.dart`: Chronological gallery viewer of photos stored in a patient's Drive folder with full-screen pinch-to-zoom.
  - `settings_screen.dart`: Database info, parent Drive folder info, `Sync Now (Full Reconciliation)`, last synced row count, safe reconfiguration, and sign-out.
- `lib/widgets/`:
  - `patient_tile.dart`: Clean, clinical patient list item with status badges for `missing` or `conflict` Drive folders.
  - `unassigned_session_tile.dart`: Session card with formatted timestamp, thumbnail counts, and action buttons.
  - `patient_assignment_sheet.dart`: Searchable modal bottom sheet to select and validate patient for session assignment.
  - `photo_thumbnail.dart`: Grid thumbnail widget for Google Drive photos with loading and fallback.
  - `selection_thumbnail.dart`: Thumbnail widget with checkmark selection badge for session photo deletion mode.
  - `upload_status.dart`: Minimal status indicator pill ("↑ 2 uploading", "✓ All photos uploaded", "! 1 failed [Retry]").

## Data & Control Flow
1. **Google OAuth**: Doctor authorizes once. Credentials securely managed by Google Identity Services on Android with scopes for Google Sheets and Google Drive.
2. **Visits Sheet as Source of Truth & Relational Name/Phone Resolution**:
   - Primary operational visit log source is the clinic's `Visits` table.
   - Multiple rows with the same `Patient ID` are deduplicated into one local `Patient` record in SQLite.
   - Clinical photo Drive folder URLs are stored and written back strictly to the `Photos (Drive)` column in `Visits`.
   - Name & phone resolution follows the workbook's relational model:
     - `Visits` (Patient ID, Photos (Drive)) -> `Patients` (Patient ID -> Appointment ID, direct Name, direct Phone) -> `Appointments` (Appointment ID -> Patient Name, Phone Number).
     - Directly populated clinical data is preserved and never overwritten by subsequent blank visit rows.
     - Phone numbers are cleaned, stored in canonical display format, and indexed in normalized digit form (`phoneNumberNormalized`) for instant local SQLite search across All, Name, Phone, and Patient ID.
   - Drive folder URLs are extracted via `extractDriveFolderId()`.
   - Repeated identical folders -> `FolderStatus.available` (`isUploadable = true`).
   - Blank rows + 1 valid folder -> `FolderStatus.available` (`isUploadable = true`).
   - Different non-empty folders -> `FolderStatus.conflict` (`isUploadable = false`, blocked from capture; never guess).
   - Blank folders across all visits -> `FolderStatus.missing` (lazily created by app when photographed or assigned).
3. **App-Owned Patient Drive Folders (No Apps Script)**:
   - When an unassigned session is assigned or an existing patient with `missing` folder is photographed, the app searches the configured parent Drive folder for `<Patient ID> - <Patient Name>`.
   - 1 match -> reused; 0 matches -> created; >1 matches -> `conflict`.
   - The resolved folder ID is persisted in SQLite, and the full URL is written back to blank `Visits` rows for that `Patient ID` in Google Sheets.
4. **Incremental Sync & Full Reconciliation**:
   - App startup loads cached SQLite patients immediately (<50ms).
   - Background sync reads newly appended rows (`Visits!A{lastSyncedRow + 1}:ZZ`), resolves directory and appointment companion records, merging updates via `Patient.merge`.
   - Settings offers `Sync Now (Full Reconciliation)` to re-read all rows from row 1.
5. **Workflow A (Existing Patient Capture)**:
   - Doctor searches and selects patient -> `CameraScreen` opens -> Shutter press saves image to `photo_queue/patients/<Patient ID>/<Patient ID>_<timestamp>_<sequence>.jpg` -> SQLite inserts record (`waiting`) -> Background loop uploads to patient's Drive folder.
6. **Workflow B (Unassigned Photo Sessions & Assignment)**:
   - Doctor taps `+ New / Unassigned Patient` -> `CaptureSession` created in SQLite -> Camera opens immediately.
   - Photos saved in `photo_queue/unassigned/<session_id>/unassigned_<timestamp>_<sequence>.jpg` with `UploadStatus.unassigned`.
   - Sessions have no expiration; survive restarts, battery dying, or days passing.
   - Doctor inspects thumbnails in `SessionDetailScreen`, can multi-select and delete unwanted photos.
   - Upon assignment to patient, photos are atomically renamed and moved to `photo_queue/patients/<patientId>/<sessionId>/<patientId>_<timestamp>_<sequence>.jpg`, and database records transition to `waiting` status.
7. **Confirmed Drive Upload Clean-up**:
   - When Drive API confirms file creation, SQLite record and local file are deleted.
   - For session items, once all photos in the session are confirmed, the session row and its private storage directory are deleted.
8. **Patient Photo Gallery**:
   - Doctor views chronological photos stored in patient's Google Drive folder directly within the app.