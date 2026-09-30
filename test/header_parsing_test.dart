import 'package:clinic_photos/config.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SheetsService.parseHeaderIndices', () {
    test('parses standard column order correctly', () {
      final headers = ['Patient ID', 'Patient Name', 'Drive Folder ID'];
      final indices = SheetsService.parseHeaderIndices(headers);

      expect(indices.idColIndex, 0);
      expect(indices.nameColIndex, 1);
      expect(indices.folderColIndex, 2);
    });

    test('parses reordered columns correctly (Column order does not matter)', () {
      final headers = ['Drive Folder ID', 'Patient ID', 'Patient Name'];
      final indices = SheetsService.parseHeaderIndices(headers);

      expect(indices.folderColIndex, 0);
      expect(indices.idColIndex, 1);
      expect(indices.nameColIndex, 2);

      final headersVariant = ['Patient Name', 'Extra Notes', 'Drive Folder ID', 'Patient ID'];
      final indicesVariant = SheetsService.parseHeaderIndices(headersVariant);

      expect(indicesVariant.nameColIndex, 0);
      expect(indicesVariant.folderColIndex, 2);
      expect(indicesVariant.idColIndex, 3);
    });

    test('case-insensitive header matching', () {
      final headers = ['patient id', 'PATIENT NAME', 'drive folder id'];
      final indices = SheetsService.parseHeaderIndices(headers);

      expect(indices.idColIndex, 0);
      expect(indices.nameColIndex, 1);
      expect(indices.folderColIndex, 2);
    });

    test('throws MissingColumnException when Photos (Drive) is missing and requireFolderColumn is true', () {
      final headers = ['Patient ID', 'Patient Name', 'Notes'];

      expect(
        () => SheetsService.parseHeaderIndices(headers, requireFolderColumn: true),
        throwsA(
          isA<MissingColumnException>().having(
            (e) => e.missingColumn,
            'missingColumn',
            AppConfig.photosDriveHeader,
          ),
        ),
      );
    });

    test('accepts missing Photos (Drive) column by default in V4 read-only import', () {
      final headers = ['Patient ID', 'Patient Name', 'Notes'];
      final indices = SheetsService.parseHeaderIndices(headers);
      expect(indices.idColIndex, 0);
      expect(indices.nameColIndex, 1);
      expect(indices.folderColIndex, -1);
    });

    test('accepts Photos (Drive) as valid primary header', () {
      final headers = ['Patient ID', 'Patient Name', 'Photos (Drive)'];
      final indices = SheetsService.parseHeaderIndices(headers);

      expect(indices.idColIndex, 0);
      expect(indices.nameColIndex, 1);
      expect(indices.folderColIndex, 2);
    });

    test('throws MissingColumnException when Patient ID is missing', () {
      final headers = ['Patient Name', 'Drive Folder ID'];

      expect(
        () => SheetsService.parseHeaderIndices(headers),
        throwsA(
          isA<MissingColumnException>().having(
            (e) => e.missingColumn,
            'missingColumn',
            AppConfig.patientIdHeader,
          ),
        ),
      );
    });

    test('throws MissingColumnException when Patient Name is missing', () {
      final headers = ['Patient ID', 'Drive Folder ID'];

      expect(
        () => SheetsService.parseHeaderIndices(headers),
        throwsA(
          isA<MissingColumnException>().having(
            (e) => e.missingColumn,
            'missingColumn',
            AppConfig.patientNameHeader,
          ),
        ),
      );
    });
  });

  group('SheetsService.discoverHeaderIndices (Dynamic Discovery)', () {
    test('TEST 1: Header is on row 1 and Patient ID is column A', () {
      final rows = [
        ['Patient ID', 'Patient Name', 'Photos (Drive)'],
        ['P001', 'Alice Smith', 'https://drive.google.com/drive/folders/1ABC'],
      ];

      final indices = SheetsService.discoverHeaderIndices(rows);

      expect(indices.headerRowIndex, 0);
      expect(indices.headerRowNumber, 1);
      expect(indices.idColIndex, 0);
      expect(indices.nameColIndex, 1);
      expect(indices.folderColIndex, 2);
    });

    test('TEST 2: Header is on row 8 and Patient ID is column B', () {
      final rows = [
        ['Clinic Banner Title'],
        ['Dr. John Doe Clinic'],
        ['Date: 2026-09-28'],
        ['Confidential Patient Records'],
        [],
        ['Notes: All fees in INR'],
        [''],
        ['', 'Patient ID', 'Patient Name', 'Photos (Drive)'], // Row 8
        ['', 'P001', 'Bob Jones', 'https://drive.google.com/drive/folders/1XYZ'],
      ];

      final indices = SheetsService.discoverHeaderIndices(rows);

      expect(indices.headerRowIndex, 7);
      expect(indices.headerRowNumber, 8);
      expect(indices.idColIndex, 1);
      expect(indices.nameColIndex, 2);
      expect(indices.folderColIndex, 3);
    });

    test('TEST 3: Header is on row 5 and Patient ID is column D', () {
      final rows = [
        ['Header row 1 content'],
        ['Header row 2 content'],
        ['Header row 3 content'],
        ['Header row 4 content'],
        ['', '', '', 'Patient ID', 'Visit Date', 'Patient Name', 'Photos (Drive)'], // Row 5
        ['', '', '', 'P002', '2026-09-28', 'Charlie Brown', '2ABC1234567890123'],
      ];

      final indices = SheetsService.discoverHeaderIndices(rows);

      expect(indices.headerRowIndex, 4);
      expect(indices.headerRowNumber, 5);
      expect(indices.idColIndex, 3);
      expect(indices.nameColIndex, 5);
      expect(indices.folderColIndex, 6);
    });

    test('TEST 4: Columns are reordered', () {
      final rows = [
        ['Photos (Drive)', 'Fees Paid', 'Patient Name', 'Visit Date', 'Patient ID'],
      ];

      final indices = SheetsService.discoverHeaderIndices(rows);

      expect(indices.folderColIndex, 0);
      expect(indices.nameColIndex, 2);
      expect(indices.idColIndex, 4);
    });

    test('TEST 5: There are blank columns before Patient ID', () {
      final rows = [
        ['', '', '', '', 'Patient ID', 'Patient Name', 'Photos (Drive)'],
      ];

      final indices = SheetsService.discoverHeaderIndices(rows);

      expect(indices.idColIndex, 4);
      expect(indices.nameColIndex, 5);
      expect(indices.folderColIndex, 6);
    });

    test('TEST 6: Header contains harmless whitespace', () {
      final rows = [
        ['   Patient   ID   ', '  Patient   Name  ', '   Photos   (Drive)   '],
      ];

      final indices = SheetsService.discoverHeaderIndices(rows);

      expect(indices.idColIndex, 0);
      expect(indices.nameColIndex, 1);
      expect(indices.folderColIndex, 2);
    });

    test('TEST 7: Header uses different capitalization', () {
      final rows = [
        ['patient id', 'PATIENT NAME', 'PHOTOS (DRIVE)'],
      ];

      final indices = SheetsService.discoverHeaderIndices(rows);

      expect(indices.idColIndex, 0);
      expect(indices.nameColIndex, 1);
      expect(indices.folderColIndex, 2);
    });

    test('TEST 8: Required Patient ID header is genuinely absent', () {
      final rows = [
        ['Clinic Title'],
        ['Patient Name', 'Visit Date', 'Photos (Drive)'],
        ['John Doe', '2026-09-28', 'https://drive.google.com/drive/folders/1ABC'],
      ];

      expect(
        () => SheetsService.discoverHeaderIndices(rows),
        throwsA(
          isA<MissingColumnException>().having(
            (e) => e.missingColumn,
            'missingColumn',
            AppConfig.patientIdHeader,
          ),
        ),
      );
    });

    test('TEST 9: Patient ID exists but Patient Name is missing', () {
      final rows = [
        ['Clinic Title'],
        ['Patient ID', 'Visit Date', 'Photos (Drive)'],
        ['P001', '2026-09-28', 'https://drive.google.com/drive/folders/1ABC'],
      ];

      expect(
        () => SheetsService.discoverHeaderIndices(rows),
        throwsA(
          isA<MissingColumnException>().having(
            (e) => e.missingColumn,
            'missingColumn',
            AppConfig.patientNameHeader,
          ),
        ),
      );
    });

    test('TEST 10: Photos (Drive) exists in column O (index 14)', () {
      final row8 = List<dynamic>.filled(15, '');
      row8[1] = 'Patient ID';
      row8[2] = 'Patient Name';
      row8[14] = 'Photos (Drive)';

      final rows = [
        ...List.generate(7, (_) => <dynamic>['Banner']),
        row8,
      ];

      final indices = SheetsService.discoverHeaderIndices(rows);

      expect(indices.headerRowNumber, 8);
      expect(indices.idColIndex, 1); // Column B
      expect(indices.nameColIndex, 2); // Column C
      expect(indices.folderColIndex, 14); // Column O
    });

    test('Real-world Clinic Visits Spreadsheet structure end-to-end', () {
      // Replicates the user's exact spreadsheet structure:
      // Rows 1-7: header/banner metadata
      // Row 8: Column A empty, B: Patient ID, C: Patient Name, ..., O: Photos (Drive)
      // Row 9+: Patient rows
      final row8 = [
        '', // A: empty
        'Patient ID', // B
        'Patient Name', // C
        'Visit Date', // D
        'Fees Paid', // E
        'LAB PAID', // F
        'EXPENSES', // G
        'Notes', // H
        'Earnings', // I
        'Visit Type', // J
        'Fees Type', // K
        'Receipt Nu', // L
        'Prescription Link', // M
        'Diagnosis Notes', // N
        'Photos (Drive)', // O
      ];

      final rows = [
        ['Clinic Patient Database - Confidential'], // Row 1
        ['Updated: September 2026'], // Row 2
        [], // Row 3
        ['Dr. Special Clinic'], // Row 4
        ['Location: Clinic Branch A'], // Row 5
        [], // Row 6
        ['--- VISITS RECORD ---'], // Row 7
        row8, // Row 8
        // Patient 1 - Visit 1 (Row 9)
        ['', 'P001', 'Rahul Sharma', '2026-09-20', '500', '', '', '', '', '', '', '', '', '', 'https://drive.google.com/drive/folders/1DRIVE_RAHUL_001'],
        // Patient 1 - Visit 2 (Row 10 - duplicate patient, same folder)
        ['', 'P001', 'Rahul Sharma', '2026-09-25', '300', '', '', '', '', '', '', '', '', '', '1DRIVE_RAHUL_001'],
        // Patient 2 - Visit 1 (Row 11 - valid folder)
        ['', 'P002', 'Ananya Patel', '2026-09-26', '600', '', '', '', '', '', '', '', '', '', 'https://drive.google.com/drive/folders/2DRIVE_ANANYA_002'],
        // Patient 3 - Visit 1 (Row 12 - missing folder)
        ['', 'P003', 'Suresh Kumar', '2026-09-27', '400', '', '', '', '', '', '', '', '', '', ''],
      ];

      final indices = SheetsService.discoverHeaderIndices(rows);

      // Verify Header Discovery
      expect(indices.headerRowNumber, 8);
      expect(indices.headerRowIndex, 7);
      expect(indices.idColIndex, 1); // Column B
      expect(indices.nameColIndex, 2); // Column C
      expect(indices.folderColIndex, 14); // Column O

      // Verify Patient Resolution
      final patientsMap = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: indices,
      );

      // Verify Rows 1-7 were NOT parsed as patients
      expect(patientsMap.containsKey('Clinic Patient Database - Confidential'), isFalse);
      expect(patientsMap.containsKey('Dr. Special Clinic'), isFalse);
      expect(patientsMap.containsKey(''), isFalse);

      // Verify deduplication and resolution
      expect(patientsMap.length, 3);

      final p1 = patientsMap['P001']!;
      expect(p1.id, 'P001');
      expect(p1.name, 'Rahul Sharma');
      expect(p1.driveFolderId, '1DRIVE_RAHUL_001');
      expect(p1.isUploadable, isTrue);

      final p2 = patientsMap['P002']!;
      expect(p2.id, 'P002');
      expect(p2.name, 'Ananya Patel');
      expect(p2.driveFolderId, '2DRIVE_ANANYA_002');
      expect(p2.isUploadable, isTrue);

      final p3 = patientsMap['P003']!;
      expect(p3.id, 'P003');
      expect(p3.name, 'Suresh Kumar');
      expect(p3.driveFolderId, isNull);
      expect(p3.isUploadable, isFalse);
    });
  });
}

