# ADR 0003: Relational Sheets Synchronization and Multi-Tab Name/Phone Resolution

## Context
1. In the clinic workbook, `Visits` is the operational log sheet where visit dates, fees, and `Photos (Drive)` links are recorded. However, `Patient Name` in `Visits` is formula-derived via `XLOOKUP` referencing the `Patients` directory tab.
2. In the `Patients` directory tab:
   - Walk-in patients (`1000001`–`1000032`, etc.) have their `Patient Name` and `Phone Number` stored directly.
   - Appointment-booked patients (`1000033`, `1000048`–`1000053`, etc.) have their `Appointment ID` stored directly, while `Patient Name` and `Phone Number` are produced via `XLOOKUP` formulas querying the `Appointments` tab.
3. In earlier versions of the app, Google Sheets API synchronization either read only `Visits` or performed simple column extraction from `Patients`. Because formulas evaluated to empty strings (or the `Appointments` tab was in a separate companion workbook), all appointment-booked patients (notably after Patient 47 / `1000047`) received empty names `""` and displayed "Name unavailable".
4. The clinic's Google Drive contains the master clinic workbook (`Advanced Skin Clinic`) with `Appointments`, `Patients`, and `Visits`, while the app may be configured against `Clinic Patients` or another individual spreadsheet.

## Decision
1. **Authoritative Relational Data Resolution**:
   - `Visits` remains the primary operational source for patient discovery, visit deduplication, and `Photos (Drive)` writeback.
   - Synchronization explicitly follows the clinic workbook's relational model:
     ```text
     Visits (Patient ID)
          ↓
     Patients (Patient ID -> Appointment ID, direct Name, direct Phone)
          ↓
     Appointments (Appointment ID -> Patient Name, Phone Number)
     ```
2. **Dynamic Multi-Tab Parsing**:
   - `Appointments` tab is discovered dynamically via header aliases (`Appointment ID`, `Patient Name`, `Phone Number`) and parsed into an in-memory `Map<String, AppointmentRecord>`.
   - `Patients` directory tab is parsed dynamically via header aliases (`Patient ID`, `Appointment ID`, `Patient Name`, `Phone Number`). For appointment-linked rows with empty direct names/phones, values are resolved from `appointmentsMap[appointmentId]`.
   - Patients parsed from `Visits` are enriched with canonical names and phone numbers from the directory.
3. **Companion Tab Self-Healing**:
   - If `Appointments` or `Patients` companion tabs are missing from the configured spreadsheet, the app queries the doctor's Google Drive for the clinic master workbook (`Advanced Skin Clinic`), fetches the appointment/directory records, and copies missing companion tabs using `sheets.sheets.copyTo` so the configured spreadsheet becomes fully self-contained.
4. **Preservation of Populated Data**:
   - A populated clinical name or phone number is never overwritten by a blank or placeholder value across multiple visits or sync passes (`Patient.merge` rule).
5. **Scientific Notation & Float Normalization**:
   - `Patient.normalizePhone` and `Patient.cleanPhone` normalize numbers formatted as scientific notation (`9.422301214E9`) or decimal floats (`9422301214.0`) into standard clean digits (`9422301214`).
6. **Visits Photos (Drive) Writeback Preserved**:
   - Clinical photo Drive folder URLs continue to be written back strictly to the `Photos (Drive)` column in the operational `Visits` sheet.

## Alternatives Considered
- **Direct Formula String Parsing**: Rejected because parsing raw Excel/Sheets formula strings (`_xlfn.XLOOKUP(...)`) is brittle, fragile across locale differences, and fails when references point across closed workbooks.
- **Arbitrary Fallback Tabs**: Rejected in favor of following the clinic workbook's actual three-tier operational schema (`Visits` -> `Patients` -> `Appointments`).

## Consequences
- Every patient with clinic records (`1000001` through `1000054`) reliably resolves their real clinical name and phone number.
- Pre-allocated template rows (`1000055`–`1000065`) without visits or names are handled cleanly without crashes or errors.
- Sync remains batched and fast with zero per-patient network requests.
