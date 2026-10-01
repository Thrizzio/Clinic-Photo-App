# ADR 0005: Multi-Select Photo Management and Unassigned Session Synchronization

## Context
1. In V4, patient photos can be viewed, deleted, or moved to Unassigned Photos individually. Operating on photos one-by-one is tedious and slow for clinical workflows where procedures generate batches of 3–10 photos.
2. A critical synchronization bug existed when moving a patient photo to Unassigned:
   - The photo was moved server-side on Google Drive to `Unassigned Photos / session_YYYYMMDD_HHMMSS`.
   - A `CaptureSession` row was inserted into SQLite.
   - However, no corresponding record was inserted or updated in the `uploads` table for that photo.
   - Because `database.getUnassignedSessions()` computes photo counts via `COUNT(u.id)` from `uploads`, the session displayed as "0 photos".
   - `SessionDetailScreen` queried `uploads` for the session and found 0 items ("No photos in this session").
3. Furthermore, when assigning an unassigned session to a patient, the queue service only handled local files and did not move Drive files server-side for photos already on Google Drive.
4. Drive session folders were not verified empty before deletion, risking orphan or deleted photos if a network error interrupted a batch.

## Decision

### 1. Multi-Select in Patient Photo Viewer
- **Interaction**:
  - Normal mode: Tap opens full-screen viewer; long-press or AppBar "Select" action enters selection mode.
  - Selection mode: Visual checkmark and highlight border on selected tiles in both Light and Dark themes.
  - AppBar: Displays "X selected", with Select All / Deselect All, Move to Unassigned, and Delete actions.
  - Multi-select actions operate on all selected items in batch.

### 2. Multi-Select Move to Unassigned
- Selected photos move into **ONE** newly created unassigned session folder on Google Drive and **ONE** local `CaptureSession` record.
- Drive server-side move (`files.update` with `addParents = targetSessionFolder` and `removeParents = patientFolder`) executes for each photo without re-uploading.
- **Local DB Synchronization (Invariant Fix)**:
  - For each successfully moved Drive photo, an `UploadItem` is inserted/updated in the local `uploads` table with:
    - `session_id = unassignedSession.id`
    - `patient_id = NULL`
    - `drive_file_id = photo.id`
    - `drive_parent_folder_id = unassignedSession.drive_folder_id`
    - `status = UploadStatus.uploaded`
    - `captured_at = original photo timestamp`
    - `file_name = photo.name`
  - Local database updates occur ONLY after Drive confirms the move.
  - Successfully moved photos are immediately removed from the patient gallery.
  - Any failed moves remain in the gallery and are retryable.

### 3. Multi-Select Delete
- User confirms deletion of selected photos.
- Each photo is deleted from Google Drive first.
- Only upon Drive confirmation is the local database record and any cached/local file removed.
- Gallery immediately removes successfully deleted photos. Partial failures are preserved and reported.

### 4. Unassigned Session Assignment to Patient
- When assigning an unassigned session to a patient:
  - For photos already on Drive (`drive_file_id != null`): execute `driveService.moveFile` from session folder to `patient.driveFolderId`.
  - For local-only unassigned photos: move local file to patient directory and queue for upload (`UploadStatus.waiting`).
  - Update local records only after Drive move succeeds.
  - Empty Folder Verification: Query Drive (`listPatientPhotos(sessionFolderId)`). ONLY if zero files remain, delete the Drive session folder and delete the local session.

### 5. Unassigned Session Cards & Preview
- `UnassignedSessionTile` renders a thumbnail row, accurate photo count, IST timestamp, upload status badge, and Assign / Delete session actions.
- `SelectionThumbnail` and `SessionDetailScreen` support loading image bytes from Drive via `driveService.getFileBytes` when local files are not on disk.

## Alternatives Considered
- **Inferring Sessions Strictly from Drive Folders**: Rejected. Local SQLite is the authoritative source of truth for session metadata and upload state; querying Drive repeatedly is slow and subject to quota limits.
- **Creating Separate Sessions per Moved Photo**: Rejected. Multi-select move groups the selected photos into one session matching the doctor's intent.

## Consequences
- The "0 photos" bug is completely eliminated: `uploads` consistently tracks unassigned photos with `status = UploadStatus.uploaded`.
- Doctors can batch-move or batch-delete photos with high speed and zero redundant bandwidth.
- Unassigned session folders on Google Drive are safely cleaned up only when confirmed 100% empty.
