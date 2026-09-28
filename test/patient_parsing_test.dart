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

    test('Drive Folder ID validation rule: skips patient if folder ID is empty or null', () {
      final rowMapEmptyFolder = {
        AppConfig.patientIdHeader: 'P003',
        AppConfig.patientNameHeader: 'Arjun Mehta',
        AppConfig.driveFolderIdHeader: '',
      };

      expect(
        Patient.fromRow(
          rowMap: rowMapEmptyFolder,
          idCol: AppConfig.patientIdHeader,
          nameCol: AppConfig.patientNameHeader,
          folderCol: AppConfig.driveFolderIdHeader,
        ),
        isNull,
      );

      final rowMapNullFolder = {
        AppConfig.patientIdHeader: 'P003',
        AppConfig.patientNameHeader: 'Arjun Mehta',
        AppConfig.driveFolderIdHeader: null,
      };

      expect(
        Patient.fromRow(
          rowMap: rowMapNullFolder,
          idCol: AppConfig.patientIdHeader,
          nameCol: AppConfig.patientNameHeader,
          folderCol: AppConfig.driveFolderIdHeader,
        ),
        isNull,
      );
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
  });
}
