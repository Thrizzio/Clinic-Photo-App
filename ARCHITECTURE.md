# Architecture

## Status
In active development — Flutter Android single-doctor clinical photo capture app with direct Google OAuth, Sheets API, Drive API, and local SQLite upload queue.

## Modules
- `lib/config.dart`: Developer constants (Google OAuth scopes). No clinic secrets or sheet IDs.
- `lib/models/`:
  - `patient.dart`: Domain model (`id`, `name`, `driveFolderId`).
  - `upload_item.dart`: Persistent queue item (`id`, `patientId`, `driveFolderId`, `localPath`, `fileName`, `status`, `retryCount`, `lastError`, `driveFileId`, `createdAt`).
  - `clinic_config.dart`: In-app clinic settings (`spreadsheetId`, `spreadsheetUrl`, `sheetTabName`, `hasCompletedSetup`, `lastPatientSync`).
- `lib/services/`:
  - `google_auth.dart`: Google Sign-In 7.x wrapper & authenticated HTTP client (`extension_google_sign_in_as_googleapis_auth`).
  - `config_service.dart`: SharedPreferences persistence for clinic configuration and setup flag.
  - `sheets.dart`: Google Sheets API v4 metadata discovery (tabs), header parsing, and patient row validation/retrieval.
  - `drive.dart`: Google Drive API v3 photo uploader into target folder ID.
  - `database.dart`: Local SQLite database with `patients` and `uploads` tables. Crash recovery resets `uploading` to `waiting`.
  - `upload_queue.dart`: Asynchronous upload loop, gentle bounded retries, connectivity change listener, and instant camera return.
- `lib/screens/`:
  - `welcome_screen.dart`: Welcome and Google account sign-in.
  - `clinic_setup_screen.dart`: Multi-step one-time setup wizard (URL input, tab picker, column/row validation summary).
  - `patients_screen.dart`: Search-first patient selector with background sync and minimal upload status indicator.
  - `camera_screen.dart`: Rapid clinical photo capture with patient header context and immediate shutter return.
  - `settings_screen.dart`: Database info, manual sync, safe reconfiguration (`Change Patient Database`), and sign-out.
- `lib/widgets/`:
  - `patient_tile.dart`: Clean, clinical patient list item with large touch targets.
  - `upload_status.dart`: Minimal status indicator pill ("↑ 2 uploading", "✓ All photos uploaded", "! 1 failed [Retry]").

## Data Flow
1. **Google OAuth**: Doctor authorizes once. Credentials securely managed by Google Identity Services on Android.
2. **Setup (One-Time)**: Doctor pastes Sheet URL -> App extracts ID & discovers tabs -> Doctor selects tab -> App validates headers (`Patient ID | Patient Name | Drive Folder ID` in any order) -> Initial sync to SQLite cache -> `hasCompletedSetup = true`.
3. **Patient Selection**: Reads cached patients instantly from SQLite; background sync updates cache; local case-insensitive search by ID or name; tap patient -> opens camera.
4. **Clinical Photo Capture**: Tap shutter -> Camera saves image to private app storage (`photo_queue/`) -> SQLite inserts record (`waiting`) -> Camera UI is immediately ready for next capture.
5. **Direct Drive Upload**: Asynchronous worker pulls `waiting` item -> sets status to `uploading` -> uploads to `driveFolderId` -> on Drive confirmation, deletes local image file and deletes SQLite record.

## Key Decisions
1. **Direct Google OAuth & APIs**: No custom backend or server. Directly connects to Sheets API v4 and Drive API v3 with doctor's Google account.
2. **Broad Drive Scope for Internal Clinic**: Uses `https://www.googleapis.com/auth/drive` to access existing clinic patient folders. Strictly internal/private use for one doctor.
3. **Google Sheet as Routing Layer**: `Patient ID | Patient Name | Drive Folder ID` eliminates fuzzy search and folder resolver complexity. Patients without Drive Folder ID cannot be selected.
4. **Ephemeral SQLite Upload Queue**: SQLite only protects pending work. Upon confirmed upload, local file and SQLite record are deleted.
5. **Crash Recovery & Bounded Retries**: Startup resets `uploading` to `waiting`. Retries bounded to 5s -> 15s -> 30s -> 60s -> manual retry.