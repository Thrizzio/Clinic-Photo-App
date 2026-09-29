import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Sync Performance & Reconciliation Tests (Section 23.5)', () {
    test('1. Incremental range formatting: Range string is Visits!A{lastSyncedRow}:Z{lastSyncedRow + 500}', () {
      final range1 = SheetsService.buildIncrementalRange('Visits', 100);
      expect(range1, 'Visits!A100:Z600');

      final range2 = SheetsService.buildIncrementalRange('Visits', 550, 500);
      expect(range2, 'Visits!A550:Z1050');

      final rangeCustom = SheetsService.buildIncrementalRange('ClinicVisits', 200, 250);
      expect(rangeCustom, 'ClinicVisits!A200:Z450');
    });

    test('2. Full reconciliation: Correctly resolves and deduplicates across full sheet', () {
      final rows = <List<dynamic>>[
        ['Patient ID', 'Patient Name', 'Photos (Drive)', 'Date', 'Notes'],
        ['P001', 'Alice Green', 'https://drive.google.com/drive/folders/folder_p001_aaa', '2026-01-01', 'First visit'],
        ['P002', 'Bob White', '', '2026-01-02', 'No folder yet'],
        ['P001', 'Alice Green', 'https://drive.google.com/drive/folders/folder_p001_aaa', '2026-02-01', 'Follow-up visit with same folder'],
        ['P003', 'Charlie Red', 'https://drive.google.com/drive/folders/folder_p003_xxx', '2026-01-05', 'Visit 1'],
        ['P003', 'Charlie Red', 'https://drive.google.com/drive/folders/folder_p003_yyy', '2026-02-05', 'Visit 2 with conflicting folder!'],
      ];

      final headerIndices = SheetsService.discoverHeaderIndices(rows);
      final patientsMap = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );

      expect(patientsMap.length, 3);

      // P001: deduplicated with available folder
      expect(patientsMap['P001']?.folderStatus, FolderStatus.available);
      expect(patientsMap['P001']?.driveFolderId, 'folder_p001_aaa');

      // P002: missing folder
      expect(patientsMap['P002']?.folderStatus, FolderStatus.missing);
      expect(patientsMap['P002']?.driveFolderId, isNull);

      // P003: conflicting folders across visits
      expect(patientsMap['P003']?.folderStatus, FolderStatus.conflict);
      expect(patientsMap['P003']?.driveFolderId, isNull);
    });

    test('3. Large sheet handling: Parses 10,000+ rows efficiently without errors', () {
      final rows = <List<dynamic>>[];
      // Header row
      rows.add(['Patient ID', 'Patient Name', 'Photos (Drive)', 'Department', 'Phone']);

      // Generate 10,000 data rows (representing 2,000 patients with 5 visits each)
      for (var i = 1; i <= 10000; i++) {
        final patientNum = (i % 2000) + 1;
        final patientId = 'P${patientNum.toString().padLeft(4, '0')}';
        final folderUrl = patientNum % 5 == 0
            ? '' // some missing
            : 'https://drive.google.com/drive/folders/folder_${patientNum.toString().padLeft(4, '0')}_12345';

        rows.add([patientId, 'Patient $patientNum', folderUrl, 'Cardiology', '555-0199']);
      }

      final stopwatch = Stopwatch()..start();
      final headerIndices = SheetsService.discoverHeaderIndices(rows);
      final patientsMap = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );
      stopwatch.stop();

      expect(patientsMap.length, 2000);
      expect(stopwatch.elapsedMilliseconds, lessThan(3000)); // Should process 10k rows in well under 3 seconds
    });
  });
}
