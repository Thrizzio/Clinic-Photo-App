import 'package:clinic_photos/config.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Patient.fromRow validation', () {
    test('parses valid row correctly', () {
      final rowMap = {
        AppConfig.patientIdHeader: 'P001',
        AppConfig.patientNameHeader: 'Rahul Sharma',
        AppConfig.driveFolderIdHeader: '1abc-drive-folder-id',
      };

      final patient = Patient.fromRow(
        rowMap: rowMap,
        idCol: AppConfig.patientIdHeader,
        nameCol: AppConfig.patientNameHeader,
        folderCol: AppConfig.driveFolderIdHeader,
      );

      expect(patient, isNotNull);
      expect(patient!.id, 'P001');
      expect(patient.name, 'Rahul Sharma');
      expect(patient.driveFolderId, '1abc-drive-folder-id');
    });

    test('trims surrounding whitespace from all fields', () {
      final rowMap = {
        AppConfig.patientIdHeader: '  P002  ',
        AppConfig.patientNameHeader: '  Ananya Patel  ',
        AppConfig.driveFolderIdHeader: '  folder_xyz  ',
      };

      final patient = Patient.fromRow(
        rowMap: rowMap,
        idCol: AppConfig.patientIdHeader,
        nameCol: AppConfig.patientNameHeader,
        folderCol: AppConfig.driveFolderIdHeader,
      );

      expect(patient, isNotNull);
      expect(patient!.id, 'P002');
      expect(patient.name, 'Ananya Patel');
      expect(patient.driveFolderId, 'folder_xyz');
    });

    test('Drive Folder ID validation rule: sets folderStatus to missing and blocks upload if folder ID is empty or null', () {
      final rowMapEmptyFolder = {
        AppConfig.patientIdHeader: 'P003',
        AppConfig.patientNameHeader: 'Arjun Mehta',
        AppConfig.photosDriveHeader: '',
      };

      final patientEmpty = Patient.fromRow(
        rowMap: rowMapEmptyFolder,
        idCol: AppConfig.patientIdHeader,
        nameCol: AppConfig.patientNameHeader,
        folderCol: AppConfig.photosDriveHeader,
      );

      expect(patientEmpty, isNotNull);
      expect(patientEmpty!.folderStatus, FolderStatus.missing);
      expect(patientEmpty.driveFolderId, isNull);
      expect(patientEmpty.isUploadable, isFalse);

      final rowMapNullFolder = {
        AppConfig.patientIdHeader: 'P003',
        AppConfig.patientNameHeader: 'Arjun Mehta',
        AppConfig.photosDriveHeader: null,
      };

      final patientNull = Patient.fromRow(
        rowMap: rowMapNullFolder,
        idCol: AppConfig.patientIdHeader,
        nameCol: AppConfig.patientNameHeader,
        folderCol: AppConfig.photosDriveHeader,
      );

      expect(patientNull, isNotNull);
      expect(patientNull!.folderStatus, FolderStatus.missing);
      expect(patientNull.driveFolderId, isNull);
      expect(patientNull.isUploadable, isFalse);
    });

    test('skips patient if ID or Name is empty', () {
      final rowMapNoId = {
        AppConfig.patientIdHeader: '',
        AppConfig.patientNameHeader: 'Valid Name',
        AppConfig.driveFolderIdHeader: 'folder123',
      };

      expect(
        Patient.fromRow(
          rowMap: rowMapNoId,
          idCol: AppConfig.patientIdHeader,
          nameCol: AppConfig.patientNameHeader,
          folderCol: AppConfig.driveFolderIdHeader,
        ),
        isNull,
      );

      final rowMapNoName = {
        AppConfig.patientIdHeader: 'P004',
        AppConfig.patientNameHeader: '   ',
        AppConfig.driveFolderIdHeader: 'folder123',
      };

      expect(
        Patient.fromRow(
          rowMap: rowMapNoName,
          idCol: AppConfig.patientIdHeader,
          nameCol: AppConfig.patientNameHeader,
          folderCol: AppConfig.driveFolderIdHeader,
        ),
        isNull,
      );
    });

    test('parses clinic real-world patient row (1000001 -> Anil Jain) with displayName and hasValidName', () {
      final rowMap = {
        AppConfig.patientIdHeader: '1000001',
        AppConfig.patientNameHeader: 'Anil Jain',
        AppConfig.photosDriveHeader: '',
      };

      final patient = Patient.fromRow(
        rowMap: rowMap,
        idCol: AppConfig.patientIdHeader,
        nameCol: AppConfig.patientNameHeader,
        folderCol: AppConfig.photosDriveHeader,
      );

      expect(patient, isNotNull);
      expect(patient!.id, '1000001');
      expect(patient.name, 'Anil Jain');
      expect(patient.displayName, 'Anil Jain');
      expect(patient.hasValidName, isTrue);
    });

    test('Patient.displayName falls back to Name unavailable if name is empty or synthetic placeholder', () {
      const emptyPatient = Patient(id: '1000002', name: '');
      expect(emptyPatient.displayName, 'Name unavailable');
      expect(emptyPatient.hasValidName, isFalse);

      const placeholderPatient = Patient(id: '1000003', name: 'Patient 1000003');
      expect(placeholderPatient.displayName, 'Name unavailable');
      expect(placeholderPatient.hasValidName, isFalse);

      const validPatient = Patient(id: '1000003', name: 'Pragati Waghaji');
      expect(validPatient.displayName, 'Pragati Waghaji');
      expect(validPatient.hasValidName, isTrue);
    });
  });
}
