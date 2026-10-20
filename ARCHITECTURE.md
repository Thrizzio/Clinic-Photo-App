# Architecture

## Status
Version 6 (V6) — Flutter Android clinical photo capture app. V6 introduces shared cloud-photo discovery, camera reference selection from the full-screen photo viewer, background-first synchronization with truthful offline indicators, concurrent-safe silent Google authentication, recent-activity patient sorting (`max(last_viewed_at, updated_at, created_at)`), and a managed remote-photo cache service with 500 MB to 400 MB LRU eviction and 30-day retention.

Key V6 capabilities:
- Canonical UUID patient identity with business identity deduplication `(normalized_name, normalized_phone)`.
- Invariant: doctor-created patients are NEVER deleted by Google Sheets synchronization.
- Day 1 in-app creation + Day 5 Google Sheet addition links seamlessly into the canonical UUID record without duplicates.
- Offline-first photo capture: shutter saves to disk and SQLite immediately; renders immediately in gallery; uploads asynchronously in background.
- Shared cloud-photo discovery: remote patient photos enumerating directly from Google Drive folders, streaming lightweight thumbnails without full-res download overhead.
- Reference-image camera overlays: selectable from full-screen viewer or picker; overlay is strictly Flutter UI and never written into captured JPEG bytes.
- Background-first synchronization: SQLite patient records display immediately; cloud reconciliation runs silently; no technical sync badges or spinners in doctor workflow; non-intrusive offline notice only when network is genuinely disconnected.
- Concurrent-safe Google authentication: Zone-scoped locking prevents race conditions and repeated consent prompts during background syncing.
- Recent-activity ordering: SQLite schema v11 deterministic sort by `max(last_viewed_at, updated_at, created_at)` with case-insensitive name and stable UUID tie-breaking. Viewing patients records `last_viewed_at` without marking clinical data dirty or triggering cloud sync.
- Managed remote-photo cache (`RemotePhotoCacheService`): separate app-private directory `remote_photo_cache/` for thumbnails and full-res photos, 30-day retention, 500 MB budget with LRU eviction to 400 MB, and verified local capture retention (30 days post-verified upload without pending recovery). Cloud originals strictly protected from eviction.

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
|  |  - Camera reference overlays   |       |  - Exponential retry & backoff  |  |
|  |  - Background-first sync UI    |       |  - Verified capture retention   |  |
|  +--------------------------------+       +---------------------------------+  |
|                   |                                       |                    |
|                   |       +-------------------------------+                    |
|                   v       v                                                    |
|  +-----------------------------------+    +---------------------------------+  |
|  | SQLite AppDatabase (Schema v11)   |    | RemotePhotoCacheService         |  |
|  |  - patients (UUID, name, phone,   |    |  - Thumbnails & full-res cache  |  |
|  |    source, drive_folder_id,       |    |  - 500 MB budget, 400 MB LRU    |  |
|  |    updated_at, last_viewed_at)    |    |  - 30-day access TTL            |  |
|  |  - patient_sources & sessions     |    |  - Cloud originals protected    |  |
|  |  - uploads & remote_photo_cache   |    +---------------------------------+  |
|  +-----------------------------------+                                         |
+--------------------------------------------------------------------------------+
       |                                      |                         |
       | Sync / Match                         | Sync Patients           | Upload Photos / Cache
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
  - `patient.dart`: Canonical patient model (`id` [UUID], `displayName`, `normalizedName`, `phoneDisplay`, `normalizedPhone`, `legacyPatientId`, `source: clinicSheet | doctorCreated | merged`, `driveFolderId`, `folderStatus`, `syncStatus`, `createdAt`, `updatedAt`, `lastViewedAt`, `effectiveActivityAt`, `isUploadable`, `matchesBusinessIdentity`).
  - `capture_session.dart`: Capture session model (`id`, `patientId`, `createdAt`, `status`, `photoCount`, `driveFolderId`).
  - `upload_item.dart`: Persistent photo capture & upload queue record (`id`, `sessionId`, `patientId`, `driveFolderId`, `localPath`, `fileName`, `status: pending | waiting | uploading | uploaded | failed | unassigned`, `retryCount`, `lastError`, `driveFileId`, `capturedAt`, `sequenceNumber`).
  - `remote_cache_entry.dart`: Managed cache metadata record (`driveFileId`, `cacheType: thumbnail | full`, `filePath`, `fileSize`, `patientId`, `createdAt`, `lastAccessedAt`).
  - `clinic_config.dart`: Settings model (`spreadsheetId`, `spreadsheetUrl`, `sheetTabName`, `parentDriveFolderId`, `hasCompletedSetup`, `lastPatientSync`, `lastSyncedRow`, `lastFullSync`).
- `lib/services/`:
  - `database.dart`: SQLite database (schema v11) with `patients`, `patient_sources`, `capture_sessions`, `uploads`, and `remote_photo_cache` tables. Deterministic patient sorting orders by `effectiveActivityAt DESC, display_name COLLATE NOCASE ASC, id ASC`. Crash recovery resets `uploading` to `waiting`.
  - `remote_photo_cache.dart`: Managed local cache for remote Drive photos with thumbnail streaming, full-res retrieval, 30-day retention, 500 MB budget, LRU eviction to 400 MB, and verified local capture cleanup.
  - `drive.dart`: Google Drive API v3 client (folder queries, uploads, server-side moves, deletions, thumbnail streaming, pagination, remote patient photo enumeration).
  - `google_auth.dart`: Google Sign-In 7.x wrapper and authenticated HTTP client with Zone-scoped concurrency locking and bounded interactive re-authorization.
  - `upload_queue.dart`: Manages disk persistence (`photo_queue/`), SQLite upload state machine, background uploading, Drive folder auto-creation for offline captures, verified capture retention, and unassigned sessions.
  - `patient_folder_service.dart`: Idempotent Google Drive folder resolver (`<Patient Name> - <Phone Number>` or legacy `<Legacy Patient ID> - <Patient Name>`).
  - `sheets.dart`: Google Sheets API v4 metadata discovery, dynamic headers, and read-only import stream.
  - `supabase_patient_service.dart`: Supabase client managing canonical `patients` and `patient_sources` tables for single-clinic MVP with anon access, remote business identity lookup, and cross-source reconciliation.
  - `patient_sync_service.dart`: Reconciles external Google Sheets rows with Supabase canonical patients and updates SQLite local cache with truthful sync reporting (detects RLS 42501 violations).
  - `collage_service.dart`: Pure Dart clinical collage generator using `package:image` with EXIF orientation correction (`bakeOrientation`), horizontal side-by-side comparison, and 3–6 image balanced grids.
  - `photo_export_service.dart`: Cross-platform photo sharing via standard Android share sheet (`ACTION_SEND`, `ACTION_SEND_MULTIPLE`) and public gallery export via scoped MediaStore (`gal`).
  - `config_service.dart`: SharedPreferences settings persistence, doctor credentials storage, and reactive `themeModeNotifier`.
- `lib/screens/`:
  - `welcome_screen.dart`: Welcome & Google sign-in.
  - `clinic_setup_screen.dart`: Spreadsheet configuration and parent Drive folder setup.
  - `patients_screen.dart`: Search-first patient selector with silent background synchronization, non-intrusive offline indicator on genuine network loss, and activity-sorted list.
  - `camera_screen.dart`: Rapid offline-first clinical photo capture with zero blocking shutter, reference image overlay, and shared cloud-photo discovery in the reference picker.
  - `patient_photos_screen.dart`: Gallery rendering local disk cache immediately with upload status badges, background Drive sync with existing folder discovery, photo sharing, gallery saving, collage creation, "Use as reference" full-screen viewer action, multi-select moves, and safe deletions.
  - `collage_preview_screen.dart`: High-definition zoom/pan preview screen for generated clinical collages with direct share and gallery saving.
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

### 5. High-Performance Batch Sync & Cross-Device Drive Folder Propagation
- **Separation of Sync Lifecycles**:
  - **Normal Patient Database Sync (`SQLite ↔ Supabase`)**: Runs automatically in the background on startup (`_syncPatientDatabaseInBackground()`). It exchanges records solely between SQLite and Supabase. It strictly NEVER queries Google Drive API and NEVER queries Google Sheets.
  - **Google Sheets Sync**: Isolated to explicit user requests (manual "Refresh") or settings reconfiguration (`_syncSheetInBackground()`).
  - **Google Drive Operations**: Isolated to photo capture, upload, and patient folder resolution on demand. Drive API is never hit during normal patient list or background database syncs.
- **Batching & In-Memory Indexing**:
  - Eliminates N+1 per-patient HTTP queries by pre-fetching cloud patients and source mappings once upfront, indexing them in memory by source ID and normalized business identity `(normalized_name, normalized_phone)`.
  - Commits updates in bulk via `upsertPatients()` and `linkPatientSources()` in both Supabase and SQLite. Network round-trips for 77 patients dropped from ~385 sequential calls down to ~2–4 bulk requests.
- **Cross-Device Drive Folder Preservation**:
  - `RemoteSupabasePatientService.upsertPatient` and `upsertPatients` omit `'drive_folder_id'` when null/empty, guaranteeing that PostgREST `onConflict: 'id'` never overwrites an existing cloud Drive folder with `NULL`.
  - `Patient.merge` authoritatively preserves valid existing folders against incoming null values, and flags `FolderStatus.conflict` only when two different non-empty folder IDs exist.
  - When Phone A creates a Drive folder (`patientFolderService.getOrCreatePatientFolder`), it marks the patient `pending_cloud` and immediately syncs the folder ID to Supabase if online.
  - When Phone B syncs from Supabase, its UI immediately derives folder status from `patient.driveFolderId != null && patient.driveFolderId!.isNotEmpty`, enabling immediate direct photo capture without requiring the user to recreate the folder.

### 6. Photo Deletion Permission Model & Anti-Resurrection Architecture
- **Clinic-Wide Authorization**:
  - In this single-clinic MVP, photo ownership does NOT determine deletion permissions. Any user of the clinic app can delete any clinical photo belonging to a patient in the clinic.
  - No per-user uploader check (`uploadedBy == currentUser`) is enforced for deletion authorization. Useful uploader metadata in Drive/auditing is preserved without restricting deletion.
- **Drive Permission Handling**:
  - In Shared Drives (Google Workspace), deletion executes via `files.delete(fileId, supportsAllDrives: true)`.
  - In personal Google Drive (where non-owners get 403 Forbidden on `files.delete`), the service executes a fallback that removes the file from the patient parent folder via `files.update(removeParents: parentFolderId, supportsAllDrives: true)`. This disconnects the photo from the patient folder so it never appears in patient photo listings again.
- **Folder Protection Invariant**:
  - Photo deletion deletes ONLY the specific photo. It strictly NEVER deletes or alters the patient's Google Drive folder or other photos.
- **Offline Deletion & Anti-Resurrection**:
  - When a user deletes a photo offline, the UI removes it immediately, local file cache and SQLite records are cleaned up, a tombstone is recorded in `deleted_photo_tombstones`, and a record is added to `pending_photo_deletions`.
  - Background worker `UploadQueueService.processPendingPhotoDeletions` syncs pending deletions to Drive upon reconnecting.
  - When Device A synchronizes with Drive, if an uploaded photo is absent from the Drive folder, Device A reconciles the deletion, removes its local upload record and disk cache, and records a tombstone, ensuring Device A never resurrects the deleted photo.

### 7. Shared Cloud-Photo Discovery & Camera Reference Workflow
- **Remote Candidate Enumeration**:
  - `DriveService.listRemotePatientPhotos` queries the patient's Google Drive folder directly, paginating through files matching image MIME types.
  - Local upload records and cached files are rendered immediately in the candidate picker.
  - Remote photos captured by other devices appear asynchronously without waiting for local record synchronization.
  - Photos are deduplicated by `driveFileId` and local filename to avoid duplicate entries.
- **Lightweight Thumbnail Streaming**:
  - Remote candidates stream thumbnail bytes lazily via `drive.files.get(alt: Media)` or Drive thumbnail links, caching thumbnails in `remote_photo_cache/thumbnails/`.
  - Full-resolution photos are NEVER fetched merely to populate the thumbnail picker.
- **Viewer-to-Camera Reference Handoff**:
  - The full-screen photo viewer provides a direct "Use as reference" action.
  - If the image is locally cached or in `photo_queue`, its bytes are passed directly into `CameraScreen(initialReferenceBytes: bytes)`.
  - If remote, bytes are retrieved on demand from `RemotePhotoCacheService` with non-blocking loading feedback.
  - The camera reference overlay is strictly a Flutter UI composition layer (`Opacity` widget) and is never written into the captured JPEG image bytes.

### 8. Background-First Synchronization & Doctor-Facing UI
- **Zero Technical Sync In Doctor Workflow**:
  - The manual "Refresh" button, "Synced" badges, and "Local only" tech state indicators are removed from the doctor's primary view.
  - SQLite patients render synchronously/instantly on startup.
  - Background tasks (`_syncPatientDatabaseInBackground()` and `_syncSheetInBackground()`) run silently without blocking user actions.
  - Bounded concurrency locks prevent duplicate or overlapping synchronization jobs.
- **Truthful Network Awareness**:
  - A subtle offline banner renders only when network connectivity is genuinely absent (`ConnectivityResult.none`).
  - Google Auth expiration, missing scopes, or server errors are handled as non-blocking technical errors and are never misrepresented as "offline".

### 9. Deterministic Recent-Activity Patient Ordering
- **Canonical Activity Timestamp**:
  - Patient sorting orders by `max(last_viewed_at, updated_at, created_at) DESC`.
  - Deterministic tie-breaker: `display_name COLLATE NOCASE ASC, id ASC`.
- **Viewing vs. Editing Semantics**:
  - Opening a patient in `PatientPhotosScreen` updates `last_viewed_at` in SQLite without altering `updated_at` and without marking the patient dirty (`pending_cloud`) for Supabase sync.
  - `updated_at` changes only when clinical metadata or patient details are modified.

### 10. Managed Remote-Photo Cache & Retention Architecture
- **Dual-Tier App-Private Storage**:
  - Remote assets reside in an app-private directory (`remote_photo_cache/`) separate from `photo_queue/`.
  - Thumbnails (`thumbnails/`) and full-resolution images (`full/`) are tracked in SQLite `remote_photo_cache`.
- **Budget & LRU Eviction**:
  - Configurable 500 MB cache budget with hysteresis: when total cache size exceeds 500 MB, least-recently-used (LRU) files are evicted until disk usage falls below 400 MB.
  - 30-day retention after last access timestamp.
- **Safety Invariants**:
  - **Cloud Originals**: Eviction deletes ONLY local cached files. Google Drive originals are NEVER touched or deleted during cache eviction.
  - **Local Captures**: Local files in `photo_queue/` remain untouched until upload is verified against Google Drive. Verified captures are retained for 30 days before safe cleanup. Pending, failed, or ambiguous uploads are NEVER cleaned up.

### 11. Collage Persistence, Patient Gallery Integration & Safe-Area Ergonomics
- **Durable Collage Persistence**:
  - Generating a clinical collage and selecting "Save to Patient" copies the generated JPEG to `photo_queue/patients/<patientId>/Collage_YYYY-MM-DD_HHmmss.jpg`.
  - Enqueues an `UploadItem` into SQLite `uploads` with `sessionId: 'collage'`.
  - Seamlessly participates in existing background upload workers, crash recovery, and offline caching without a parallel table.
  - Gallery immediately shows persisted collages with a distinct `COLLAGE` badge.
  - "To Device Photos" remains an independent action exporting to public MediaStore via `Gal`.
- **Phone-Based Drive Folder Discovery & Transliteration Search**:
  - `PatientFolderService.discoverExistingPatientFolder` and `_resolvePatientFolder` execute phone-based Drive queries (`name contains '<phone>'`) under the configured parent folder. Resolves folders named with spelling or transliteration variations (e.g. `Rajni Suttati - 9422301089` for `Rajani Suttati`).
  - `Patient.matchesNameVowelTolerant` builds dynamic vowel-flexible regular expressions allowing search to find patients even when vowel transliterations vary (`rajni` <-> `rajani`).
  - `database.searchPatients` incorporates vowel-tolerant matching while strictly honoring `SearchFilterMode` boundaries.
- **Phone Deduplication Prompt**:
  - `NewPatientDialog` verifies phone numbers against `database.getPatientByNormalizedPhone`. If an existing patient is found, the doctor is prompted to view the existing patient rather than creating a duplicate.
- **Android Safe-Area & Keyboard Ergonomics**:
  - Wrapped bottom bars in `SafeArea(bottom: true)`.
  - Dynamically hide fixed bottom bars during active keyboard input (`viewInsets.bottom > 0`) in `PatientsScreen` to preserve screen real estate and prevent input obstruction on gesture-navigation devices.