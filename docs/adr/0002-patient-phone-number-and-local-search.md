# ADR 0002: Patient Phone Number Integration, Canonical Deduplication, and Local Multi-Mode Search

## Context
In previous revisions, the patient data model suffered from a data flow bug:
1. Synthetic placeholders like `Patient <id>` were assigned in early sync logic and persisted in SQLite. Later changes in name validation (`hasValidName`) rejected these strings, causing the Patients screen to display "Name unavailable" for nearly every patient.
2. The SQLite database contained stale test records (`P001`, `P002`) because initial migration failures aborted table truncation, leading to a discrepancy between Setup (65 unique patients) and the Patients screen (66 patients).
3. Patient phone numbers were not part of the domain model or SQLite schema, preventing search by phone number.

## Decision
1. **Canonical Patient Model**:
   - `Patient` contains `id`, `name`, `phoneNumber` (nullable `String?`), `phoneNumberNormalized` (nullable `String?`), `driveFolderId`, `folderStatus`, and `updatedAt`.
   - `phoneNumber = null` is a first-class valid state. Fake placeholder values (`"Unknown"`, `"0000000000"`, `"-"`, `"N/A"`) are cleanly stripped upon parsing and never persisted.
2. **Deterministic Phone Discovery and Merge Rules**:
   - Phone columns in Google Sheets are discovered dynamically using case-insensitive normalized header aliases (`phone`, `mobile`, `contact`, `cell`, `whatsapp`, etc.).
   - Multiple visits for the same patient ID are deduplicated.
   - Blank or placeholder values in follow-up visit rows never overwrite populated clinical names or phone numbers (`Patient.merge` rule).
3. **Phone Number Normalization**:
   - The original displayable phone number is preserved in `phone_number`.
   - `phone_number_normalized` strips all non-digits, international country prefixes (`+91`, `+`), and national trunk prefixes (`0`, `91`), allowing queries like `9876543210`, `+91 98765 43210`, and partial strings like `98765` to match identically.
4. **100% Local SQLite Search (Zero Network Per Keystroke)**:
   - Search operates purely against the local SQLite cache indexed by `idx_patients_search`.
   - A compact, in-screen filter chip control allows toggling between `All` (default: ID, name, or phone), `Name`, `Phone`, and `Patient ID` without navigating away.
5. **Canonical Count Reconciliation**:
   - Setup and full manual refresh trigger `replacePatients`, which replaces stale cache rows in a single atomic transaction.
   - Unassigned capture sessions are stored in the separate `capture_sessions` table and never included in patient counts.

## Alternatives Considered
- **Network Search via Google Sheets API**: Rejected because querying remote spreadsheets on every keystroke causes quota exhaustion, network latency, and breaks offline searching.
- **Separate Search Screen**: Rejected to preserve the fast, compact, single-screen clinical workflow.

## Consequences
- Fast, instantaneous search across name, phone, and patient ID directly on device.
- Schema upgraded to v6 with safe migration (`_ensurePatientsTableSchema`) preserving all existing patient records.
- Total test coverage across DATA, SEARCH, COUNT, and UI requirements.
