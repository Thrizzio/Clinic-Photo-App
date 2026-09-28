import 'package:flutter/foundation.dart';
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

class HeaderIndices {
  final int idColIndex;
  final int nameColIndex;
  final int folderColIndex;
  final int headerRowIndex;
  final Map<String, int> columnMap;

  const HeaderIndices({
    required this.idColIndex,
    required this.nameColIndex,
    required this.folderColIndex,
    this.headerRowIndex = 0,
    this.columnMap = const {},
  });

  /// 1-based row number in Google Sheets
  int get headerRowNumber => headerRowIndex + 1;
}

class SheetParseResult {
  final List<Patient> patients;
  final int totalRows;
  final HeaderIndices? headerIndices;

  const SheetParseResult({
    required this.patients,
    required this.totalRows,
    this.headerIndices,
  });
}

class IncrementalSyncResult {
  final List<Patient> updatedPatients;
  final int newRowsCount;
  final int newLastSyncedRow;

  const IncrementalSyncResult({
    required this.updatedPatients,
    required this.newRowsCount,
    required this.newLastSyncedRow,
  });
}

class _PatientGroupData {
  final String id;
  String name = '';
  final Set<String> folderIds = {};

  _PatientGroupData({required this.id});
}

class SheetsService {
  /// Regular expression to match Google Drive folder ID inside folder URLs.
  static final RegExp _driveFolderUrlRegex =
      RegExp(r'(?:/folders/|[?&]id=)([a-zA-Z0-9-_]{10,})');

  /// Regular expression to match Google Spreadsheet ID from URL.
  static final RegExp _sheetUrlRegex =
      RegExp(r'/spreadsheets/d/([a-zA-Z0-9-_]+)');

  /// Extracts the Google Drive Folder ID from a full Drive folder URL, or returns
  /// the normalized ID if already formatted as a standalone folder ID.
  ///
  /// Rejects malformed strings, file URLs, and non-Google URLs cleanly.
  static String? extractDriveFolderId(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri == null || !uri.host.contains('drive.google.com')) {
        return null;
      }
      final match = _driveFolderUrlRegex.firstMatch(trimmed);
      if (match != null && match.groupCount >= 1) {
        return match.group(1);
      }
      return null;
    }

    // Standalone folder ID: Google Drive folder IDs are typically 15+ alphanumeric chars
    if (RegExp(r'^[a-zA-Z0-9-_]{15,}$').hasMatch(trimmed)) {
      return trimmed;
    }

    return null;
  }

  /// Normalizes a header cell value: trims leading/trailing whitespace,
  /// collapses internal multi-whitespace into a single space, and lowercases.
  static String normalizeHeader(String header) {
    return header.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Parses a single header row into a [HeaderIndices] object.
  /// Throws [MissingColumnException] if Patient ID, Patient Name, or Photos (Drive) is missing.
  static HeaderIndices parseHeaderIndices(
    List<dynamic> rawHeaderRow, {
    int headerRowIndex = 0,
  }) {
    final columnMap = <String, int>{};
    for (int i = 0; i < rawHeaderRow.length; i++) {
      final cell = rawHeaderRow[i]?.toString() ?? '';
      final normalized = normalizeHeader(cell);
      if (normalized.isNotEmpty && !columnMap.containsKey(normalized)) {
        columnMap[normalized] = i;
      }
    }

    final idColIndex = columnMap[normalizeHeader(AppConfig.patientIdHeader)] ?? -1;
    final nameColIndex = columnMap[normalizeHeader(AppConfig.patientNameHeader)] ?? -1;
    final folderColIndex = columnMap[normalizeHeader(AppConfig.photosDriveHeader)] ??
        columnMap[normalizeHeader(AppConfig.legacyDriveFolderIdHeader)] ??
        -1;

    if (idColIndex == -1) {
      throw MissingColumnException(AppConfig.patientIdHeader);
    }
    if (nameColIndex == -1) {
      throw MissingColumnException(AppConfig.patientNameHeader);
    }
    if (folderColIndex == -1) {
      throw MissingColumnException(AppConfig.photosDriveHeader);
    }

    return HeaderIndices(
      idColIndex: idColIndex,
      nameColIndex: nameColIndex,
      folderColIndex: folderColIndex,
      headerRowIndex: headerRowIndex,
      columnMap: columnMap,
    );
  }

  /// Discovers the header row dynamically from a list of rows.
  ///
  /// Searches for the row that contains all required columns (Patient ID, Patient Name,
  /// Photos (Drive) / Drive Folder ID). If found, returns the [HeaderIndices] with the
  /// discovered row index and column positions.
  ///
  /// If no row contains all required headers, evaluates the best candidate row and throws
  /// [MissingColumnException] indicating the missing column.
  static HeaderIndices discoverHeaderIndices(List<List<dynamic>> rows) {
    if (rows.isEmpty) {
      throw MissingColumnException(AppConfig.patientIdHeader);
    }

    int bestMatchCount = -1;
    int bestCandidateIndex = 0;

    for (int r = 0; r < rows.length; r++) {
      final row = rows[r];
      if (row.isEmpty) continue;

      final columnMap = <String, int>{};
      for (int i = 0; i < row.length; i++) {
        final cell = row[i]?.toString() ?? '';
        final normalized = normalizeHeader(cell);
        if (normalized.isNotEmpty && !columnMap.containsKey(normalized)) {
          columnMap[normalized] = i;
        }
      }

      final idIdx = columnMap[normalizeHeader(AppConfig.patientIdHeader)] ?? -1;
      final nameIdx = columnMap[normalizeHeader(AppConfig.patientNameHeader)] ?? -1;
      final folderIdx = columnMap[normalizeHeader(AppConfig.photosDriveHeader)] ??
          columnMap[normalizeHeader(AppConfig.legacyDriveFolderIdHeader)] ??
          -1;

      int matchCount = 0;
      if (idIdx != -1) matchCount++;
      if (nameIdx != -1) matchCount++;
      if (folderIdx != -1) matchCount++;

      if (matchCount > bestMatchCount) {
        bestMatchCount = matchCount;
        bestCandidateIndex = r;
      }

      // If all required headers are found in this row, we have discovered the header row!
      if (matchCount == 3) {
        final indices = HeaderIndices(
          idColIndex: idIdx,
          nameColIndex: nameIdx,
          folderColIndex: folderIdx,
          headerRowIndex: r,
          columnMap: columnMap,
        );

        debugPrint('Discovered header row: ${indices.headerRowNumber}');
        debugPrint('Patient ID column: $idIdx');
        debugPrint('Patient Name column: $nameIdx');
        debugPrint('Photos (Drive) column: $folderIdx');

        return indices;
      }
    }

    // No row contained all 3 required headers.
    // Call parseHeaderIndices on the best candidate row to throw the
    // exact missing column exception (Patient ID, Patient Name, or Photos (Drive)).
    return parseHeaderIndices(
      rows[bestCandidateIndex],
      headerRowIndex: bestCandidateIndex,
    );
  }

  /// Deduplicates visit rows by Patient ID and resolves Drive folder status.
  ///
  /// Ignores all rows before [headerIndices.headerRowIndex + 1] unless an explicit
  /// [startRowIndex] is provided (e.g. for incremental sync chunks).
  ///
  /// Rules:
  /// - Groups multiple visits for the same Patient ID into one Patient record.
  /// - Same folder repeatedly across visits -> available.
  /// - Some rows blank + one valid folder -> available.
  /// - Multiple distinct non-empty folders -> conflict (silently choosing one is forbidden).
  /// - No folder across all rows -> missing.
  static Map<String, Patient> resolvePatientsFromVisits({
    required List<List<dynamic>> rows,
    required HeaderIndices headerIndices,
    int? startRowIndex,
  }) {
    final effectiveStartIndex = startRowIndex ?? (headerIndices.headerRowIndex + 1);
    final patientData = <String, _PatientGroupData>{};

    for (int i = effectiveStartIndex; i < rows.length; i++) {
      final row = rows[i];
      if (row.isEmpty) continue;

      final id = headerIndices.idColIndex < row.length
          ? row[headerIndices.idColIndex]?.toString().trim() ?? ''
          : '';
      final name = headerIndices.nameColIndex < row.length
          ? row[headerIndices.nameColIndex]?.toString().trim() ?? ''
          : '';
      final rawFolder = headerIndices.folderColIndex < row.length
          ? row[headerIndices.folderColIndex]?.toString().trim() ?? ''
          : '';

      if (id.isEmpty) continue;

      final entry = patientData.putIfAbsent(id, () => _PatientGroupData(id: id));
      if (name.isNotEmpty) {
        entry.name = name;
      }

      if (rawFolder.isNotEmpty) {
        final extractedId = extractDriveFolderId(rawFolder);
        if (extractedId != null && extractedId.isNotEmpty) {
          entry.folderIds.add(extractedId);
        }
      }
    }

    final result = <String, Patient>{};
    for (final entry in patientData.values) {
      final resolvedName = entry.name.isNotEmpty ? entry.name : 'Patient ${entry.id}';

      if (entry.folderIds.isEmpty) {
        result[entry.id] = Patient(
          id: entry.id,
          name: resolvedName,
          driveFolderId: null,
          folderStatus: FolderStatus.missing,
        );
      } else if (entry.folderIds.length == 1) {
        result[entry.id] = Patient(
          id: entry.id,
          name: resolvedName,
          driveFolderId: entry.folderIds.first,
          folderStatus: FolderStatus.available,
        );
      } else {
        result[entry.id] = Patient(
          id: entry.id,
          name: resolvedName,
          driveFolderId: null,
          folderStatus: FolderStatus.conflict,
        );
      }
    }

    return result;
  }

  /// Extracts the spreadsheet ID from a Google Sheets URL or returns the raw ID
  /// if already formatted as a standalone Google resource identifier.
  static String? extractSpreadsheetId(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    final match = _sheetUrlRegex.firstMatch(trimmed);
    if (match != null && match.groupCount >= 1) {
      return match.group(1);
    }

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

  /// Full reconciliation: fetches all rows from the sheet, validates headers dynamically,
  /// deduplicates visit rows, and resolves patient folder statuses.
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
        totalRows: 0,
      );
    }

    final rows = rawRows.cast<List<dynamic>>();
    final headerIndices = discoverHeaderIndices(rows);
    final patientsMap = resolvePatientsFromVisits(
      rows: rows,
      headerIndices: headerIndices,
    );

    return SheetParseResult(
      patients: patientsMap.values.toList(),
      totalRows: rows.length,
      headerIndices: headerIndices,
    );
  }

  /// Incremental sync: fetches only rows appended after [lastSyncedRow].
  Future<List<List<dynamic>>> fetchNewRows({
    required AuthClient client,
    required String spreadsheetId,
    required String sheetName,
    required int lastSyncedRow,
  }) async {
    final sheetsApi = sheets.SheetsApi(client);
    final range = '$sheetName!A${lastSyncedRow + 1}:ZZ';

    try {
      final valueRange = await sheetsApi.spreadsheets.values.get(
        spreadsheetId,
        range,
      );
      return valueRange.values?.cast<List<dynamic>>() ?? [];
    } catch (_) {
      return [];
    }
  }

  /// Incremental sync: fetches only rows appended after [lastSyncedRow]
  /// and resolves patients according to the sheet's dynamically discovered header indices.
  Future<IncrementalSyncResult?> fetchIncrementalPatients({
    required AuthClient client,
    required String spreadsheetId,
    required String sheetName,
    required int lastSyncedRow,
  }) async {
    final sheetsApi = sheets.SheetsApi(client);

    try {
      final batchResponse = await sheetsApi.spreadsheets.values.batchGet(
        spreadsheetId,
        ranges: [
          '$sheetName!A1:ZZ100',
          '$sheetName!A${lastSyncedRow + 1}:ZZ',
        ],
      );

      final ranges = batchResponse.valueRanges;
      if (ranges == null || ranges.isEmpty) return null;

      final headerValues = ranges[0].values;
      if (headerValues == null || headerValues.isEmpty) return null;
      final headerIndices = discoverHeaderIndices(headerValues.cast<List<dynamic>>());

      // If lastSyncedRow is before the discovered header row, full reconciliation is required
      if (lastSyncedRow < headerIndices.headerRowNumber) {
        return null;
      }

      final newRowsValues = ranges.length > 1 ? ranges[1].values : null;
      if (newRowsValues == null || newRowsValues.isEmpty) {
        return IncrementalSyncResult(
          updatedPatients: const [],
          newRowsCount: 0,
          newLastSyncedRow: lastSyncedRow,
        );
      }

      final newRows = newRowsValues.cast<List<dynamic>>();
      final resolvedMap = resolvePatientsFromVisits(
        rows: newRows,
        headerIndices: headerIndices,
        startRowIndex: 0,
      );

      return IncrementalSyncResult(
        updatedPatients: resolvedMap.values.toList(),
        newRowsCount: newRows.length,
        newLastSyncedRow: lastSyncedRow + newRows.length,
      );
    } catch (_) {
      return null;
    }
  }
}
