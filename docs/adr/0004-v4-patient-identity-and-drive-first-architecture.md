# ADR 0004: V4 Patient Identity (Name + Phone) and Drive-First Architecture

## Context
1. In V1–V3, the application coupled patient identity directly to Google Sheets' internal spreadsheet key (`Patient ID`, e.g. `1000001`). The doctor in the consultation or procedure room does not know or use spreadsheet row keys.
2. Patients frequently arrive from affiliated clinics/hospitals, or need immediate pre-procedure photography before reception has entered them into the clinic Google Sheet.
3. Writing Google Drive folder URLs back to the `Photos (Drive)` column of the Google Sheet created a tight external dependency that was slow, error-prone, and unnecessary since the app itself stores and manages patient-to-Drive folder mappings.
4. Unassigned photos had no persistent Google Drive representation until assigned, posing data loss risks if local storage were cleared.
5. Legacy photo filenames embedded Patient ID and UTC timestamps, causing date-shift bugs across the midnight boundary in Indian Standard Time (IST, UTC+05:30).

## Decision

### 1. Local UUID Primary Key & Business Identity
- **Primary Key**: The application uses a local generated UUID (`id`) as the internal primary key for all patients.
- **Business Identity**: The tuple `(normalized_name, normalized_phone)` is the authoritative business identity.
- **Phone Requirement**:
  - Doctor-created patients: Name is **required**, and Phone is **required** (valid 10-digit Indian mobile number).
  - Imported Sheet patients: Name is required; missing phone numbers are stored as `normalized_phone = NULL` and treated as incomplete records.
- **Database Schema (SQLite v7)**:
  - SQLite maintains a non-unique index `idx_patients_business_id ON patients(normalized_name, normalized_phone)`.
  - There is **no literal SQLite UNIQUE constraint**, avoiding database crashes on messy historical sheet imports. Deduplication is handled deterministically at the application layer.

### 2. Hard Invariant: Doctor-Created Patient Later Added to Sheets
- **Operational Scenario**:
  ```text
  Doctor creates: "Abhijit Gaikwad - 9373264424" in-app (generates UUID, creates Drive folder)
          ↓ days later
  Reception adds Abhijit to clinic Sheet: Patient ID = 1000048, Name = Abhijit Gaikwad, Phone = 9373264424
          ↓ sync
  App matches (normalized_name, normalized_phone)
          ↓
  Local UUID retained
  legacy_patient_id = 1000048
  source = 'merged'
  Drive folder remains untouched
  ```
- **Rule**: When an imported Sheet patient matches an existing doctor-created patient, never create a second patient or second Drive folder. Attach the legacy Patient ID to the existing local patient and preserve its existing Drive folder and all photos.

### 3. Drive Folder Identity & Parent Verification
- **Canonical Naming**: `<Patient Name> - <Phone Number>` (or `<Patient Name>` if phone is missing for historical records).
- **Legacy Compatibility**: Folders named `<Legacy Patient ID> - <Patient Name>` are discovered and reused.
- **Parent Verification**: Candidate folders are strictly validated to exist directly within the configured clinic parent folder (`'$configuredParentId' in parents`). Matching folder names located elsewhere in Drive are ignored.

### 4. Google Sheets Read-Only Import
- Google Sheets is treated strictly as an import stream for patient and appointment discovery.
- The app ceases all writeback to the `Photos (Drive)` column in the Google Sheet. The `Photos (Drive)` column is optional in Sheet headers.

### 5. First-Class Cloud Unassigned State
- Unassigned photos upload immediately to `Configured Parent / Unassigned Photos / session_YYYYMMDD_HHMMSS`.
- Assigning an unassigned session to a patient performs a fast, zero-bandwidth Google Drive server-side file move (`files.update` with `addParents` and `removeParents`), not a re-upload.

### 6. Clinical Photo Viewer Capabilities
- Direct **Move to Unassigned** server-side action inside the photo viewer.
- Safe **Delete Photo**: Google Drive deletion confirms successfully before local queue/database records are removed.

### 7. Deterministic Chronology & Authoritative IST Timestamps
- Filenames follow `YYYYMMDD_HHMMSS_SSS_<sequence>.jpg` generated using authoritative Indian Standard Time (`UTC+05:30`), eliminating UTC midnight boundary shifts and stripping Patient ID from filenames.
- Gallery and viewer sort photos descending (newest first).
- UI displays timestamps formatted in IST (`d MMM yyyy, hh:mm a`).

### 8. Material 3 Dark Theme & Clinical Inbox Polish
- Complete light/dark theme support with `ThemeMode.system`.
- Standardized clinical inbox icon (`Icons.inbox_outlined`) for unassigned sessions across all screens.
- Progressive thumbnail loading with animated shimmering skeleton placeholders.
- Real-time upload queue progress indicators.

## Alternatives Considered
- **Literal SQLite UNIQUE Constraint**: Rejected because historical clinic spreadsheets contain duplicate or incomplete entries that would abort transactions mid-sync.
- **Re-uploading on Session Assignment**: Rejected in favor of Drive server-side `addParents`/`removeParents` which executes in ~200ms without cellular data consumption.
- **UTC Timestamps in Filenames**: Rejected because doctors think and operate in Indian Standard Time; UTC filenames caused photos taken at 12:15 AM to sort into yesterday's date.

## Consequences
- The doctor can create patients and capture photos anytime, anywhere, completely decoupled from Google Sheets availability.
- All patient photos are safely stored in Google Drive and cleanly organized by patient identity.
- Backward compatibility with legacy folders and numeric IDs is 100% preserved.
- Zero Patient ID exposure on doctor-facing clinical screens.
