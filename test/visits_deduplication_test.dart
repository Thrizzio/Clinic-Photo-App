import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Visits Deduplication & Drive Folder Resolution', () {
    const headerIndices = HeaderIndices(
      idColIndex: 0,
      nameColIndex: 1,
      folderColIndex: 2,
    );

    test('deduplicates multiple visits for same patient with identical folder', () {
      final rows = [
        ['Patient ID', 'Patient Name', 'Photos (Drive)'],
        ['P001', 'Rahul Sharma', 'https://drive.google.com/drive/folders/1ABC1234567890123'],
        ['P001', 'Rahul Sharma', 'https://drive.google.com/drive/folders/1ABC1234567890123'],
        ['P001', 'Rahul Sharma', '1ABC1234567890123'],
      ];

      final patients = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );

      expect(patients.length, 1);
      final p = patients['P001']!;
      expect(p.id, 'P001');
      expect(p.name, 'Rahul Sharma');
      expect(p.driveFolderId, '1ABC1234567890123');
      expect(p.folderStatus, FolderStatus.available);
      expect(p.isUploadable, isTrue);
    });

    test('resolves patient with some blank visits and one valid folder', () {
      final rows = [
        ['Patient ID', 'Patient Name', 'Photos (Drive)'],
        ['P002', 'Ananya Patel', ''], // visit 1: reception forgot link
        ['P002', 'Ananya Patel', 'https://drive.google.com/drive/folders/2XYZ1234567890123'], // visit 2: link added
        ['P002', 'Ananya Patel', ''], // visit 3: blank
      ];

      final patients = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );

      expect(patients.length, 1);
      final p = patients['P002']!;
      expect(p.id, 'P002');
      expect(p.driveFolderId, '2XYZ1234567890123');
      expect(p.folderStatus, FolderStatus.available);
      expect(p.isUploadable, isTrue);
    });

    test('flags conflict when multiple distinct non-empty folders exist for same patient', () {
      final rows = [
        ['Patient ID', 'Patient Name', 'Photos (Drive)'],
        ['P003', 'Vikram Singh', 'https://drive.google.com/drive/folders/3AAA1234567890123'],
        ['P003', 'Vikram Singh', 'https://drive.google.com/drive/folders/3BBB1234567890123'], // distinct folder!
      ];

      final patients = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );

      expect(patients.length, 1);
      final p = patients['P003']!;
      expect(p.id, 'P003');
      expect(p.folderStatus, FolderStatus.conflict);
      expect(p.driveFolderId, isNull);
      expect(p.isUploadable, isFalse);
    });

    test('marks patient as missing when all visit rows have blank folders', () {
      final rows = [
        ['Patient ID', 'Patient Name', 'Photos (Drive)'],
        ['P004', 'Deepak Verma', ''],
        ['P004', 'Deepak Verma', '   '],
      ];

      final patients = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );

      expect(patients.length, 1);
      final p = patients['P004']!;
      expect(p.id, 'P004');
      expect(p.folderStatus, FolderStatus.missing);
      expect(p.driveFolderId, isNull);
      expect(p.isUploadable, isFalse);
    });

    test('handles multiple distinct patients correctly', () {
      final rows = [
        ['Patient ID', 'Patient Name', 'Photos (Drive)'],
        ['P001', 'Rahul Sharma', 'https://drive.google.com/drive/folders/1ABC1234567890123'],
        ['P002', 'Ananya Patel', ''],
        ['P003', 'Vikram Singh', 'https://drive.google.com/drive/folders/3AAA1234567890123'],
        ['P003', 'Vikram Singh', 'https://drive.google.com/drive/folders/3BBB1234567890123'],
      ];

      final patients = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );

      expect(patients.length, 3);
      expect(patients['P001']!.folderStatus, FolderStatus.available);
      expect(patients['P002']!.folderStatus, FolderStatus.missing);
      expect(patients['P003']!.folderStatus, FolderStatus.conflict);
    });
  });

  group('Patient.merge', () {
    test('existing available patient remains available when new row has blank folder', () {
      const existing = Patient(
        id: 'P001',
        name: 'Rahul',
        driveFolderId: 'FOLDER_123456789',
        folderStatus: FolderStatus.available,
      );
      const incoming = Patient(
        id: 'P001',
        name: 'Rahul',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );

      final merged = Patient.merge(existing, incoming);
      expect(merged.folderStatus, FolderStatus.available);
      expect(merged.driveFolderId, 'FOLDER_123456789');
    });

    test('existing missing patient becomes available when new row contains valid folder', () {
      const existing = Patient(
        id: 'P002',
        name: 'Ananya',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );
      const incoming = Patient(
        id: 'P002',
        name: 'Ananya',
        driveFolderId: 'FOLDER_234567890',
        folderStatus: FolderStatus.available,
      );

      final merged = Patient.merge(existing, incoming);
      expect(merged.folderStatus, FolderStatus.available);
      expect(merged.driveFolderId, 'FOLDER_234567890');
    });

    test('becomes conflict when incoming row has a different valid folder', () {
      const existing = Patient(
        id: 'P003',
        name: 'Vikram',
        driveFolderId: 'FOLDER_AAA',
        folderStatus: FolderStatus.available,
      );
      const incoming = Patient(
        id: 'P003',
        name: 'Vikram',
        driveFolderId: 'FOLDER_BBB',
        folderStatus: FolderStatus.available,
      );

      final merged = Patient.merge(existing, incoming);
      expect(merged.folderStatus, FolderStatus.conflict);
      expect(merged.driveFolderId, isNull);
    });
  });
}
