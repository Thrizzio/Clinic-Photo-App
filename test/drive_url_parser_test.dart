import 'package:clinic_photos/services/sheets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SheetsService.extractDriveFolderId', () {
    test('extracts ID from standard Google Drive folder URLs', () {
      expect(
        SheetsService.extractDriveFolderId('https://drive.google.com/drive/folders/1ABCxyz9876543210_-'),
        '1ABCxyz9876543210_-',
      );

      expect(
        SheetsService.extractDriveFolderId('http://drive.google.com/drive/folders/1ABCxyz9876543210_-'),
        '1ABCxyz9876543210_-',
      );
    });

    test('extracts ID from multi-account Google Drive folder URLs (/u/0/)', () {
      expect(
        SheetsService.extractDriveFolderId('https://drive.google.com/drive/u/0/folders/1ABCxyz9876543210_-'),
        '1ABCxyz9876543210_-',
      );
      expect(
        SheetsService.extractDriveFolderId('https://drive.google.com/drive/u/1/folders/1ABCxyz9876543210_-'),
        '1ABCxyz9876543210_-',
      );
    });

    test('extracts ID from query parameter URLs (?id=...)', () {
      expect(
        SheetsService.extractDriveFolderId('https://drive.google.com/open?id=1ABCxyz9876543210_-'),
        '1ABCxyz9876543210_-',
      );
    });

    test('handles trailing slashes, fragments, and sharing query parameters', () {
      expect(
        SheetsService.extractDriveFolderId('https://drive.google.com/drive/folders/1ABCxyz9876543210_-/'),
        '1ABCxyz9876543210_-',
      );
      expect(
        SheetsService.extractDriveFolderId('https://drive.google.com/drive/folders/1ABCxyz9876543210_-?usp=sharing'),
        '1ABCxyz9876543210_-',
      );
      expect(
        SheetsService.extractDriveFolderId('https://drive.google.com/drive/folders/1ABCxyz9876543210_-?usp=drive_link#grid'),
        '1ABCxyz9876543210_-',
      );
    });

    test('tolerates surrounding whitespace', () {
      expect(
        SheetsService.extractDriveFolderId('   https://drive.google.com/drive/folders/1ABCxyz9876543210_-   \n'),
        '1ABCxyz9876543210_-',
      );
    });

    test('passes through raw valid Google Drive folder IDs', () {
      expect(
        SheetsService.extractDriveFolderId('1ABCxyz9876543210_-'),
        '1ABCxyz9876543210_-',
      );
    });

    test('rejects non-Google URLs, file URLs, and malformed strings', () {
      expect(SheetsService.extractDriveFolderId(''), isNull);
      expect(SheetsService.extractDriveFolderId('   '), isNull);
      expect(SheetsService.extractDriveFolderId('https://example.com/folders/123456789012345'), isNull);
      expect(SheetsService.extractDriveFolderId('https://dropbox.com/s/123456789012345'), isNull);
      expect(SheetsService.extractDriveFolderId('not a drive folder url'), isNull);
      expect(SheetsService.extractDriveFolderId('short'), isNull);
      expect(SheetsService.extractDriveFolderId('file:///path/to/folder'), isNull);
    });
  });
}
