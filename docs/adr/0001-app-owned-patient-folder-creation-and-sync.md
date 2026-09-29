# ADR 0001: App-Owned Idempotent Patient Folder Creation and Google Sheets Writeback

## Context
In Clinic Clinical Photo App V2, the app relied on pre-existing Google Drive folder URLs populated in the clinic's `Visits` Google Sheet. If a patient lacked a Google Drive folder link in the sheet (`FolderStatus.missing`), the app blocked photo capture and required out-of-band folder creation (such as via manual folder creation or Google Apps Script).

To streamline clinical workflow for a single doctor, Version 3 of the specification requires the Flutter Android client to directly own patient folder creation under a configured clinic parent Drive folder (`<Patient ID> - <Patient Name>`), write generated folder URLs back to blank `Visits` rows in Google Sheets, and strictly avoid duplicate folder creation or silent conflict resolution.

## Decision
1. **App Ownership (No Apps Script)**: The Flutter client owns folder search, creation, and Google Sheets link writeback. No Google Apps Script or external webhook infrastructure is deployed.
2. **Deterministic 9-Step Resolution**:
   - Step 1: Use valid cached `driveFolderId` if available.
   - Step 2: Otherwise use valid existing `Photos (Drive)` folder link from the sheet.
   - Step 3: Otherwise search the configured parent Drive folder for exact name `${patient.id} - ${patient.name}`.
   - Step 4: Exactly one match -> reuse that folder ID.
   - Step 5: Zero matches -> create new folder under parent.
   - Step 6: Persist resolved folder ID locally in SQLite cache.
   - Step 7: Batch write folder URL (`https://drive.google.com/drive/folders/$folderId`) to all rows with that Patient ID where `Photos (Drive)` is blank.
   - Step 8: Mark patient `FolderStatus.available`.
   - Step 9: On failure, preserve recoverable state; never pretend success.
3. **Idempotence & Conflict Safety**:
   - Folder creation is strictly idempotent. Repeated calls reuse the created folder.
   - If multiple folders with the exact same name are found under the parent folder, the app marks the patient as `FolderStatus.conflict` and halts automatic routing to prevent misfiling clinical images.
4. **Lazy Resolution**:
   - Folders are resolved/created only when a patient is selected for photo capture or when an unassigned session is assigned to a patient with a missing folder.
   - Startup sync does NOT query Google Drive for every patient, preventing API quota exhaustion and preserving instantaneous (<50ms) startup time.

## Alternatives Considered
- **Eager Folder Creation during Sync**: Searching/creating folders for thousands of patients during background sync would cause severe rate limiting and degrade startup performance.
- **External Apps Script Webhook**: Adds deployment dependencies, Google Workspace domain permission issues, and invisible failure points outside the doctor's Android device.

## Consequences
- Single-doctor clinic operates 100% autonomously without server/backend setup.
- App requires write authorization for Google Drive and Google Sheets.
- In offline scenarios, patients without an existing cached folder cannot have new folders created until connectivity is restored, preserving clinical data safety.
