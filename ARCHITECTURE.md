# Architecture

## Status
Version 4 (V4) — Flutter Android single-doctor clinical photo capture app. V4 shifts from "Google Sheet Patient-ID → Drive folder" coupling to "Local Patient Identity (Name + Phone) → Drive Photo Management" architecture. Features local UUID primary keys, `(normalized_name, normalized_phone)` business identity, read-only Google Sheets import stream, in-app doctor patient creation, Drive-first cloud unassigned sessions, zero-bandwidth server-side Drive moves, progressive thumbnail loading, authoritative IST chronology, and Material 3 dark theme.

## Modules
- `lib/config.dart`: Developer constants (Google OAuth scopes, headers: `Patient ID`, `Patient Name`, `Photos (Drive)`, `Drive Folder ID`). No clinic secrets or sheet IDs.
- `lib/models/`:
  - `patient.dart`: Canonical domain model (`id` [UUID], `displayName`, `normalizedName`, `phoneDisplay`, `normalizedPhone`, `legacyPatientId`, `source: clinicSheet | doctorCreated | merged`, `driveFolderId`, `folderStatus: available | missing | creating | conflict`, `isUploadable`, `matchesBusinessIdentity`).
  - `capture_session.dart`: Unassigned/assigned photo capture session (`id`, `patientId`, `createdAt`, `status`, `photoCount`, `driveFolderId`).
  - `upload_item.dart`: Persistent queue item (`id`, `sessionId`, `patientId`, `driveFolderId`, `localPath`, `fileName`, `status`, `retryCount`, `lastError`, `driveFileId`, `createdAt`, `capturedAt`, `sequenceNumber`).
  - `clinic_config.dart`: In-app clinic settings (`spreadsheetId`, `spreadsheetUrl`, `sheetTabName`, `parentDriveFolderId`, `hasCompletedSetup`, `lastPatientSync`, `lastSyncedRow`, `lastFullSync`).
- `lib/services/`:
  - `google_auth.dart`: Google Sign-In 7.x wrapper & authenticated HTTP client (`extension_google_sign_in_as_googleapis_auth`).
  - `config_service.dart`: SharedPreferences persistence for clinic configuration, `parentDriveFolderId`, `lastSyncedRow`, `lastFullSync`, and user-selected `themeMode` (`system`, `light`, `dark`) with reactive `themeModeNotifier`.
  - `sheets.dart`: Google Sheets API v4 metadata discovery (tabs), dynamic header row & column discovery (`discoverHeaderIndices` with phone alias discovery), header normalization, Drive folder URL parsing, relational workbook multi-tab parsing (`Visits` → `Patients` → `Appointments`), and read-only import stream (no writeback to Sheet).
  - `drive.dart`: Google Drive API v3 photo uploader, folder search with strict parent verification (`findFoldersByName`), canonical folder creator (`createFolder`), server-side mover (`moveFile`), safe deletion (`deleteFile`), unassigned root/session creator (`getOrCreateUnassignedRootFolder`, `getOrCreateUnassignedSessionFolder`), and photo listing (`listPatientPhotos`).
  - `patient_folder_service.dart`: Orchestrator for idempotent patient Drive folder resolution targeting `<Patient Name> - <Phone Number>` (or `<Patient Name>`) and legacy `<Legacy Patient ID> - <Patient Name>` reuse with parent validation.
  - `database.dart`: Local SQLite database (v7 schema) supporting local UUID primary keys, `idx_patients_business_id` index, multi-mode local search (`SearchFilterMode: all, name, phone`), deterministic application-level deduplication, unassigned capture sessions, and persistent upload queue. Crash recovery resets `uploading` to `waiting`.
  - `upload_queue.dart`: Asynchronous upload loop, gentle bounded retries, connectivity change listener, unassigned capture sessions, session assignment, instant camera return, and authoritative IST filename generation (`YYYYMMDD_HHMMSS_SSS_<sequence>.jpg`).
- `lib/screens/`:
  - `welcome_screen.dart`: Welcome and Google account sign-in.
  - `clinic_setup_screen.dart`: Multi-step setup wizard (URL input, tab picker, header validation, parent Drive folder setup) with semantic theme colors.
  - `patients_screen.dart`: Search-first patient selector (All, Name, Phone filters), top-right AppBar actions (`[person_add_outlined]` and `[settings_outlined]`), bottom-right FAB with count badge (`Icons.inbox_outlined`), docked bottom navigation status bar with FAB-aware scroll padding, and zero Patient ID display.
  - `camera_screen.dart`: Rapid clinical photo capture with sequence numbering, zero Patient ID display, and non-blocking shutter.
  - `unassigned_photos_screen.dart`: Clinical inbox listing unassigned capture sessions with timestamps, photo counts, and quick actions (`[View Photos]`, `[Assign]`).
  - `session_detail_screen.dart`: Inspection screen showing local photo thumbnails, multi-select deletion mode, and `[Assign to Patient]` bottom bar.
  - `patient_photos_screen.dart`: Chronological gallery viewer with progressive thumbnail loading, shimmering skeleton placeholders, authoritative IST timestamp formatting, server-side `Move to Unassigned`, and safe `Delete Photo`.
  - `settings_screen.dart`: 4 clear sections (Appearance with Theme selector, Clinic / Storage, Data, Account), full reconciliation sync, safe reconfiguration, and sign-out.
- `lib/widgets/`:
  - `new_patient_dialog.dart`: In-app patient creation modal with required Name, required 10-digit Indian Phone validation, and local SQLite deduplication alert with `Open Patient` button.
  - `patient_tile.dart`: Clean, clinical patient list item with patient name initials avatar, display name, and phone. Zero Patient ID or UUID exposure.
  - `unassigned_session_tile.dart`: Session card with clinical inbox icon, formatted timestamp, photo count badge, and action buttons.
  - `patient_assignment_sheet.dart`: Searchable modal bottom sheet to select and validate patient for session assignment with name initials avatars and zero Patient ID exposure.
  - `photo_thumbnail.dart`: Grid thumbnail widget for Google Drive photos with loading and fallback.
  - `selection_thumbnail.dart`: Thumbnail widget with checkmark selection badge for session photo deletion mode.
  - `upload_status.dart`: Minimal status indicator pill using semantic theme tokens.

## Data & Control Flow
1. **Business Identity & Local Patient Creation**:
   - Primary key is an internal local UUID.
   - Authoritative business identity is `(normalized_name, normalized_phone)`.
   - Doctor creates patient directly in-app (`+ New Patient`): Name (required) and 10-digit phone (required).
   - If an existing patient matches `(normalized_name, normalized_phone)`, dialog alerts the doctor and provides an instant `Open Patient` shortcut.
2. **Hard Invariant: Doctor-Created Patient Later Added to Google Sheets**:
   - When an incoming Google Sheet row matches an existing doctor-created patient by `(normalized_name, normalized_phone)`:
     - The existing local UUID is strictly retained.
     - `legacy_patient_id` is attached (e.g. `1000048`).
     - `source` transitions to `'merged'`.
     - The existing Drive folder ID and all captured photos remain 100% untouched. Never creates a duplicate patient or duplicate Drive folder.
3. **Google Sheets as Read-Only Stream**:
   - Google Sheets serves purely as an external import stream.
   - The app does not write Drive folder URLs back to the `Photos (Drive)` column in `Visits`.
4. **Drive Folder Naming & Strict Parent Verification**:
   - Canonical folder name: `<Patient Name> - <Phone Number>` (or `<Patient Name>` for legacy records without a phone).
   - Folders named `<Legacy Patient ID> - <Patient Name>` under the clinic parent are recognized and reused.
   - Strict parent check: candidate folders must have `parents.contains(parentFolderId)`, preventing rogue matching outside the clinic parent folder.
5. **First-Class Cloud Unassigned State & Zero-Bandwidth Move**:
   - Unassigned photos upload immediately to `Configured Parent / Unassigned Photos / session_YYYYMMDD_HHMMSS`.
   - When the doctor assigns an unassigned session to a patient, the app executes a Google Drive server-side file move (`files.update` with `addParents` and `removeParents`), moving photos instantly in ~200ms with zero cellular bandwidth re-upload.
6. **Viewer Actions: Move to Unassigned & Safe Deletion**:
   - Photo viewer supports server-side `Move to Unassigned`, detaching photos from a patient and placing them in an unassigned session folder on Drive.
   - Safe photo deletion: Google Drive deletion completes and confirms before any local queue/database records are removed. If Drive deletion fails, local records remain intact.
7. **Deterministic IST Chronology & Filenames**:
   - Photo filenames: `YYYYMMDD_HHMMSS_SSS_<sequence>.jpg` authoritatively formatted in Indian Standard Time (`UTC+05:30`), completely removing Patient ID from filenames and UI.
   - Photos sort descending (newest first).
   - Timestamps format in IST (`d MMM yyyy, hh:mm a`).
8. **UI & Theme Architecture**:
   - Material 3 theme with instant Light / Dark / System theme switching via `SegmentedButton` in Settings.
   - Persisted across app restarts in SharedPreferences via `ConfigService.setThemeMode` and dynamically reactive via `themeModeNotifier`.
   - Top-right AppBar layout: `Patients [person_add_outlined] [settings_outlined]`.
   - Bottom-right FAB: Unassigned Photos with `Icons.inbox_outlined` and badge count.
   - Content accessibility: bottom navigation bar and list padding prevent any content or text hiding behind the FAB.
   - Zero Patient ID and internal UUID exposure in doctor-facing UI; identity is displayed as Name and Phone number.
   - Progressive thumbnail loading with shimmering skeleton placeholders.