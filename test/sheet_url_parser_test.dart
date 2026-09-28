import 'package:clinic_photos/services/sheets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SheetsService.extractSpreadsheetId', () {
    test('extracts ID from standard Google Sheets URL with /edit', () {
      const url =
          'https://docs.google.com/spreadsheets/d/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms/edit';
      final id = SheetsService.extractSpreadsheetId(url);
      expect(id, '1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms');
    });

    test('extracts ID from Google Sheets URL with /edit#gid=0', () {
      const url =
          'https://docs.google.com/spreadsheets/d/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms/edit#gid=12345';
      final id = SheetsService.extractSpreadsheetId(url);
      expect(id, '1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms');
    });

    test('extracts ID from Google Sheets URL without trailing /edit', () {
      const url =
          'https://docs.google.com/spreadsheets/d/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms';
      final id = SheetsService.extractSpreadsheetId(url);
      expect(id, '1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms');
    });

    test('accepts raw valid spreadsheet ID', () {
      const rawId = '1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms';
      final id = SheetsService.extractSpreadsheetId(rawId);
      expect(id, rawId);
    });

    test('handles leading/trailing whitespace', () {
      const url =
          '   https://docs.google.com/spreadsheets/d/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms/edit   ';
      final id = SheetsService.extractSpreadsheetId(url);
      expect(id, '1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms');
    });

    test('rejects non-Google URLs', () {
      expect(SheetsService.extractSpreadsheetId('https://example.com/sheet'), isNull);
      expect(SheetsService.extractSpreadsheetId('https://drive.google.com/drive/folders/123'), isNull);
    });

    test('rejects empty or malformed strings', () {
      expect(SheetsService.extractSpreadsheetId(''), isNull);
      expect(SheetsService.extractSpreadsheetId('   '), isNull);
      expect(SheetsService.extractSpreadsheetId('short_id'), isNull);
    });
  });
}
