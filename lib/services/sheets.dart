import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/googleapis_auth.dart';
import '../config.dart';
import '../models/patient.dart';

class MissingColumnException implements Exception {
  final String missingColumn;
  MissingColumnException(this.missingColumn);

  @override
  String toString() => 'This sheet is missing a required column: $missingColumn';
}

class SheetParseResult {
  final List<Patient> patients;
  final int skippedRows;
  final int totalRows;

  const SheetParseResult({
    required this.patients,
    required this.skippedRows,
    required this.totalRows,
  });
}

class SheetsService {
  /// Regular expression to match and extract Google Spreadsheet ID from URL.
  static final RegExp _sheetUrlRegex =
      RegExp(r'/spreadsheets/d/([a-zA-Z0-9-_]+)');

  /// Extracts the spreadsheet ID from a Google Sheets URL or returns the raw ID
  /// if already formatted as a standalone Google resource identifier.
  ///
  /// Returns null if the string is invalid or not a Google Sheets URL.
  static String? extractSpreadsheetId(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    final match = _sheetUrlRegex.firstMatch(trimmed);
    if (match != null && match.groupCount >= 1) {
      return match.group(1);
    }

    // Direct ID input: typically 20+ alphanumeric, hyphen, underscore characters without slashes or colons
    if (RegExp(r'^[a-zA-Z0-9-_]{20,}$').hasMatch(trimmed)) {
      return trimmed;
    }

    return null;
  }

  /// Retrieves available sheet tab titles from spreadsheet metadata.
  Future<List<String>> fetchSheetTabs({
    required AuthClient client,
    required String spreadsheetId,
  }) async {
    final sheetsApi = sheets.SheetsApi(client);
    final spreadsheet = await sheetsApi.spreadsheets.get(
      spreadsheetId,
      $fields: 'sheets.properties.title',
    );

    final tabs = <String>[];
    if (spreadsheet.sheets != null) {
      for (final sheet in spreadsheet.sheets!) {
        final title = sheet.properties?.title;
        if (title != null && title.isNotEmpty) {
          tabs.add(title);
        }
      }
    }
    return tabs;
  }

  /// Fetches rows from the given tab, dynamically validates required headers,
  /// and returns parsed valid patients along with skipped invalid row counts.
  ///
  /// Throws [MissingColumnException] if any required column is absent.
  Future<SheetParseResult> validateAndFetchPatients({
    required AuthClient client,
    required String spreadsheetId,
    required String sheetName,
  }) async {
    final sheetsApi = sheets.SheetsApi(client);
    final valueRange = await sheetsApi.spreadsheets.values.get(
      spreadsheetId,
      sheetName,
    );

    final rawRows = valueRange.values;
    if (rawRows == null || rawRows.isEmpty) {
      return const SheetParseResult(
        patients: [],
        skippedRows: 0,
        totalRows: 0,
      );
    }

    // First row is the header row
    final headerRow = rawRows.first.map((e) => e?.toString().trim() ?? '').toList();

    int idColIndex = -1;
    int nameColIndex = -1;
    int folderColIndex = -1;

    for (int i = 0; i < headerRow.length; i++) {
      final header = headerRow[i];
      if (header.toLowerCase() == AppConfig.patientIdHeader.toLowerCase()) {
        idColIndex = i;
      } else if (header.toLowerCase() == AppConfig.patientNameHeader.toLowerCase()) {
        nameColIndex = i;
      } else if (header.toLowerCase() == AppConfig.driveFolderIdHeader.toLowerCase()) {
        folderColIndex = i;
      }
    }

    // Verify all 3 required columns exist
    if (idColIndex == -1) {
      throw MissingColumnException(AppConfig.patientIdHeader);
    }
    if (nameColIndex == -1) {
      throw MissingColumnException(AppConfig.patientNameHeader);
    }
    if (folderColIndex == -1) {
      throw MissingColumnException(AppConfig.driveFolderIdHeader);
    }

    final validPatients = <Patient>[];
    final seenIds = <String>{};
    int skippedCount = 0;
    int totalDataRows = 0;

    for (int i = 1; i < rawRows.length; i++) {
      final row = rawRows[i];
      if (row.isEmpty) continue;

      totalDataRows++;

      final rowMap = <String, dynamic>{
        AppConfig.patientIdHeader: idColIndex < row.length ? row[idColIndex] : null,
        AppConfig.patientNameHeader: nameColIndex < row.length ? row[nameColIndex] : null,
        AppConfig.driveFolderIdHeader: folderColIndex < row.length ? row[folderColIndex] : null,
      };

      final patient = Patient.fromRow(
        rowMap: rowMap,
        idCol: AppConfig.patientIdHeader,
        nameCol: AppConfig.patientNameHeader,
        folderCol: AppConfig.driveFolderIdHeader,
      );

      if (patient != null) {
        if (!seenIds.contains(patient.id)) {
          seenIds.add(patient.id);
          validPatients.add(patient);
        } else {
          // Duplicate patient ID
          skippedCount++;
        }
      } else {
        // Row is missing required fields (e.g. missing Drive Folder ID)
        skippedCount++;
      }
    }

    return SheetParseResult(
      patients: validPatients,
      skippedRows: skippedCount,
      totalRows: totalDataRows,
    );
  }
}
