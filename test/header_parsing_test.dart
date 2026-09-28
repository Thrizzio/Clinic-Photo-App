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

    test('throws MissingColumnException when Drive Folder ID is missing', () {
      final headers = ['Patient ID', 'Patient Name', 'Notes'];

      expect(
        () => SheetsService.parseHeaderIndices(headers),
        throwsA(
          isA<MissingColumnException>().having(
            (e) => e.missingColumn,
            'missingColumn',
            AppConfig.driveFolderIdHeader,
          ),
        ),
      );
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
}
