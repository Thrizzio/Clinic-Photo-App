# 9. Background-First Workflow, Managed Remote Photo Cache, and Shared Photos

Date: 2026-10-17

## Context
In Clinic Photos (V5), several usability and architectural defects were identified:
1. **Shared Cloud Photo Discovery Defect**: When a doctor opens the camera screen to take follow-up photos for a patient, `CameraScreen._openReferencePicker` only queried local SQLite `uploads`. Photos uploaded by another clinic device only existed in Google Drive and were absent from the reference picker unless `PatientPhotosScreen` had already been visited on that device. Furthermore, remote items without local files rendered a generic cloud icon instead of actual thumbnails.
2. **Missing Reference Action in Full-Screen Viewer**: When viewing a patient's historical photos in the gallery, the doctor had no direct way to use an existing photo as the live camera reference overlay.
3. **Doctor-Facing Sync Clutter**: The patient list displayed technical sync badges ("Updating in background...", "✓ Synced", "Refresh", LinearProgressIndicator). Sync should be invisible, automatic, and background-first, displaying only a subtle offline notice when genuinely disconnected.
4. **Google Auth Concurrency & Silent Warmup**: A shared mutable boolean `_silentRequest` in `GoogleAuthService` created race conditions between foreground requests and background workers. Startup failed to warm up silent authorization cleanly, risking unexpected prompts.
5. **Patient Sorting by Recent Activity**: Patient ordering was tied solely to `updatedAt`, which was not updated when viewing a patient. Doctors need deterministic ordering based on recent activity: `max(last_viewed_at, updated_at, created_at)`.
6. **Managed Remote Photo Caching**: Downloaded remote thumbnails and full-resolution images were kept only in volatile memory or ad-hoc local files, with no LRU eviction, no size budgeting, and no 30-day retention management.

## Decision
1. **Shared Cloud-Photo Discovery**:
   - `CameraScreen._openReferencePicker` loads local candidates immediately, then asynchronously queries the patient's Google Drive folder using silent authentication.
   - Discovered remote photos are reconciled with local candidates without duplication, filtered against deletion tombstones, and cached in SQLite as uploaded reference pointers.
   - Thumbnails are loaded lazily through `RemotePhotoCacheService`.
2. **Use as Reference from Viewer**:
   - Add `onUseAsReference` action to `_FullScreenPatientPhotoGallery` in `PatientPhotosScreen`.
   - Opens `CameraScreen` with `initialReferenceBytes`. The reference overlay remains a Flutter UI layer and is never baked into captured image files.
3. **Background-First Sync & UI Simplification**:
   - Remove the sync status banner, "Synced", "Local only", and manual "Refresh" button from `PatientsScreen`.
   - Silent, non-blocking pull-to-refresh is retained.
   - A minimal offline notice (`Icons.wifi_off`, "Offline · Using local records") is shown strictly when `ConnectivityResult.none` is detected.
4. **Thread-Safe Google Auth Lifecycle**:
   - Eliminate `_silentRequest` race condition using Zone-scoped variables or explicit method signatures.
   - All background workers and thumbnail downloads use `getAuthenticatedClientSilently()`.
   - Bounded interactive recovery (maximum 1 attempt) is only initiated upon explicit user actions requiring authorization.
5. **Deterministic Activity-Based Sorting**:
   - Non-destructive SQLite migration adds `last_viewed_at TEXT` to `patients`.
   - Deterministic sort key: `max(last_viewed_at, updated_at, created_at) DESC`, with tie-breaker `display_name COLLATE NOCASE ASC`, then `id ASC`.
   - Opening a patient updates `last_viewed_at` locally without marking the patient dirty for cloud synchronization.
6. **Managed Remote Photo Cache Service**:
   - Create `RemotePhotoCacheService` managing app-private `remote_photo_cache/` (`thumbnails/` and `full/`).
   - SQLite table `remote_photo_cache` tracks `drive_file_id`, `cache_type`, `file_path`, `file_size`, `patient_id`, `created_at`, `last_accessed_at`.
   - Enforce 500 MB budget with LRU eviction down to 400 MB and 30-day TTL.
   - Invariant: Cache cleanup strictly NEVER touches `photo_queue/`, pending uploads, or Google Drive originals.
   - Upload queue retention: Verified uploaded local captures older than 30 days are safely pruned while preserving SQLite pointers.

## Alternatives Considered
- *In-memory only caching*: Discarded because repeated downloads of thumbnails across app restarts waste bandwidth and degrade offline experience.
- *Baking reference into photo capture*: Discarded because clinical records must represent authentic patient state; reference overlay is purely for positioning guidance.
- *Updating `updated_at` on patient view*: Discarded because viewing a patient is a local interaction, not a modification of the patient's clinical record, and would cause unnecessary cloud synchronization conflicts.

## Consequences
- Faster, seamless doctor workflow with zero manual sync management.
- Multi-device clinical photos are instantly available as references in the camera.
- Predictable, bounded cache disk footprint (< 500 MB) with complete safety for pending captures and cloud originals.
