# 10. Collage Persistence into Patient Gallery, Phone-Based Drive Reconciliation, and Safe Area Ergonomics

Date: 2026-10-20

## Context
In clinical photography workflows, doctors frequently generate 2 to 6 photo collages (e.g. side-by-side pre-op vs post-op comparisons) to visually document progress. Several functional and UX issues were identified:
1. **Collage Ephemerality Defect**: While collages could be shared or saved to the device's public photo gallery, they were not saved into the patient's record or gallery inside the app. Opening the patient's photos did not show previously generated collages, and collages were never synced to the patient's Google Drive folder.
2. **Patient Reconciliation Mismatch (Rajni vs Rajani Suttati)**:
   - A patient existed in the Google Sheet / SQLite as `Rajani Suttati` with phone number `9422301089`.
   - On Google Drive, the clinical folder had been created as `Rajni Suttati - 9422301089` (missing the second 'a').
   - Searching `Rajni` in the app returned 0 results because SQL `LIKE` was substring-based and strict.
   - When attempting to resolve the patient's folder, `PatientFolderService` only matched exact canonical name strings (`Rajani Suttati - 9422301089`), failing to discover the existing Drive folder and risking creating an erroneous duplicate folder.
3. **Android 14/15 Navigation Bar & Keyboard Safe-Area Overlaps**:
   - The bottom action row in `CollagePreviewScreen`, `PatientPhotosScreen`, `PatientsScreen`, and `PatientAssignmentSheet` was partially obscured by Android gesture navigation bars and on-screen keyboards.
4. **Duplicate Patient Creation Risk**:
   - Creating a new patient via `NewPatientDialog` with an already-registered phone number did not warn the doctor or offer to link to the existing patient record.

## Decision
1. **Durable Collage Persistence into Patient Gallery & Upload Queue**:
   - Added `UploadQueueService.enqueueCollage` which saves the generated collage JPEG into durable app-private storage: `photo_queue/patients/<patientId>/Collage_YYYY-MM-DD_HHmmss.jpg`.
   - Inserts an `UploadItem` into SQLite `uploads` with `sessionId: 'collage'`, patient ID, and folder ID.
   - Collages participate directly in the existing background upload worker, crash recovery, and offline caching without requiring a separate database table.
   - `UploadItem.isCollage` detects collages via `sessionId == 'collage'` or filename prefix `Collage_`.
   - `PatientPhotosScreen` renders a prominent `COLLAGE` badge overlay on collage photo tiles in the patient gallery.
   - `CollagePreviewScreen` provides explicit dual actions: "Save to Patient" (app storage + Drive queue) and "To Device Photos" (public MediaStore gallery).
2. **Phone-Based Drive Folder Discovery & Transliteration Search**:
   - `DriveService.findFoldersByPartialName`: Queries Google Drive using `name contains '$queryPart'`.
   - `PatientFolderService._findMatchingFoldersByPhone` & `discoverExistingPatientFolder`: Searches for folders containing the patient's 10-digit normalized phone number under the configured parent folder. Resolves `Rajni Suttati - 9422301089` to `Rajani Suttati` deterministically and safely updates the patient record with the discovered `driveFolderId`.
   - `Patient.matchesNameVowelTolerant`: Generates a vowel-flexible regex (`[aeiou]*` between consonants) allowing common transliteration variations (e.g. `rajni` <-> `rajani`, `pooja` <-> `puja`) to match names.
   - `SqliteAppDatabase.searchPatients` and `InMemoryAppDatabase.searchPatients`: Integrate vowel-tolerant fallback while strictly honoring `SearchFilterMode` (name mode tests only name, phone mode tests only phone, ID mode tests only ID).
3. **Patient Phone Deduplication Warning in UI**:
   - Added `AppDatabase.getPatientByNormalizedPhone` in `SqliteAppDatabase` and `InMemoryAppDatabase`.
   - In `NewPatientDialog`, entering a phone number that already belongs to an existing patient immediately displays a clear confirmation dialog asking to open the existing patient rather than creating a duplicate.
4. **Android Navigation Bar & Keyboard Ergonomics**:
   - Wrapped bottom toolbars in `SafeArea(bottom: true)`.
   - Dynamically hide the bottom count bar in `PatientsScreen` when `MediaQuery.of(context).viewInsets.bottom > 0` (keyboard active) to prioritize scrollable list visibility and prevent keyboard overlap.
   - Added bottom safe padding to `GridView` in `PatientPhotosScreen` (`88 + paddingOf(context).bottom`).

## Alternatives Considered
- *Separate Collages Table in SQLite*: Discarded because `UploadItem` already supports offline storage, background retry, Drive file ID linking, and session grouping. Introducing a parallel table would duplicate upload queue logic without architectural benefit.
- *Fuzzy String Distance / Levenshtein in SQLite*: Discarded because SQLite on Android lacks native Levenshtein functions without compiling external C extensions. Phone-based folder matching combined with Dart vowel-flexible regex matching is zero-dependency, deterministic, fast, and robust.
- *Merging "Save to Patient" and "Save to Device" into one button*: Discarded because saving to public device photos pollutes the personal camera roll, whereas clinical photos are app-private medical records intended for the patient's Drive folder.

## Consequences
- Collages are immediately visible in the patient's gallery and safely queued for Google Drive sync.
- Name variations in Google Drive folders are seamlessly reconciled via unique normalized phone numbers.
- Zero keyboard or navigation bar occlusion on edge-to-edge Android displays.
- Zero breaking changes to existing database schemas or upload worker architecture.
