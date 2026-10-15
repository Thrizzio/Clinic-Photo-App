import 'package:flutter/foundation.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import '../config.dart';
import '../models/patient.dart';
import 'drive.dart';

class AppointmentRecord {
  final String appointmentId;
  final String? patientName;
  final String? phoneNumber;

  const AppointmentRecord({
    required this.appointmentId,
    this.patientName,
    this.phoneNumber,
  });
}

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
  final int? phoneColIndex;
  final int headerRowIndex;
  final Map<String, int> columnMap;

  const HeaderIndices({
    required this.idColIndex,
    required this.nameColIndex,
    required this.folderColIndex,
    this.phoneColIndex,
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
  final String? effectiveSheetName;

  const SheetParseResult({
    required this.patients,
    required this.totalRows,
    this.headerIndices,
    this.effectiveSheetName,
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
  String? phoneNumber;
  final Set<String> folderIds = {};

  _PatientGroupData({required this.id});
}

class _AppointmentGroupData {
  final String externalId;
  String name = '';
  String? phone;
  final Set<String> folderIds = {};

  _AppointmentGroupData({required this.externalId});
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

  static const List<String> phoneHeaderAliases = [
    'phone',
    'phone number',
    'phone no',
    'phone no.',
    'phone_number',
    'mobile',
    'mobile number',
    'mobile no',
    'mobile no.',
    'mobile_number',
    'contact',
    'contact number',
    'contact no',
    'contact no.',
    'contact_number',
    'cell',
    'cell number',
    'cell no',
    'cell no.',
    'telephone',
    'whatsapp',
    'whatsapp number',
  ];

  static const List<String> appointmentHeaderAliases = [
    'appointment id',
    'appointment',
    'appt id',
    'appt',
    'appointment_id',
    'booking id',
  ];

  static bool isPhoneHeader(String normalized) {
    for (final alias in phoneHeaderAliases) {
      if (normalized == normalizeHeader(alias)) return true;
    }
    return false;
  }

  static bool isAppointmentHeader(String normalized) {
    for (final alias in appointmentHeaderAliases) {
      if (normalized == normalizeHeader(alias)) return true;
    }
    return false;
  }

  static bool isAppointmentsTab(String title) {
    final norm = title.trim().toLowerCase();
    return norm == 'appointments' ||
        norm == 'appointment schedule' ||
        norm == 'schedule' ||
        norm.contains('appointment');
  }

  static bool isPatientsTab(String title) {
    final norm = title.trim().toLowerCase();
    return norm == 'patients' ||
        norm == 'patient tracker' ||
        norm == 'patient directory' ||
        norm == 'directory';
  }

  static bool isVisitsTab(String title) {
    final norm = title.trim().toLowerCase();
    return norm == 'visits' || norm == 'visit log' || norm.contains('visit');
  }

  static int? _findPhoneColIndex(Map<String, int> columnMap) {
    for (final alias in phoneHeaderAliases) {
      final normalized = normalizeHeader(alias);
      if (columnMap.containsKey(normalized)) {
        return columnMap[normalized];
      }
    }
    return null;
  }

  /// Parses rows from an "Appointments" schedule tab.
  static Map<String, AppointmentRecord> parseAppointments(List<List<dynamic>> rows) {
    if (rows.isEmpty) return const {};

    int apptIdCol = -1;
    int nameCol = -1;
    int phoneCol = -1;
    int dataStartIndex = 0;

    for (int r = 0; r < rows.length; r++) {
      final row = rows[r];
      for (int c = 0; c < row.length; c++) {
        final cell = normalizeHeader(row[c]?.toString() ?? '');
        if (isAppointmentHeader(cell) && apptIdCol == -1) {
          apptIdCol = c;
        } else if ((cell == 'patient name' || cell == 'name') && nameCol == -1) {
          nameCol = c;
        } else if (isPhoneHeader(cell) && phoneCol == -1) {
          phoneCol = c;
        }
      }
      if (apptIdCol != -1 && (nameCol != -1 || phoneCol != -1)) {
        dataStartIndex = r + 1;
        break;
      }
    }

    if (apptIdCol == -1) return const {};

    final result = <String, AppointmentRecord>{};
    for (int r = dataStartIndex; r < rows.length; r++) {
      final row = rows[r];
      if (row.isEmpty || apptIdCol >= row.length) continue;

      final rawApptId = row[apptIdCol]?.toString().trim() ?? '';
      if (rawApptId.isEmpty) continue;

      String cleanApptId = rawApptId;
      if (RegExp(r'^\d+\.0$').hasMatch(cleanApptId)) {
        cleanApptId = cleanApptId.substring(0, cleanApptId.length - 2);
      }

      final rawName = (nameCol != -1 && nameCol < row.length)
          ? row[nameCol]?.toString().trim()
          : null;
      final rawPhone = (phoneCol != -1 && phoneCol < row.length)
          ? row[phoneCol]?.toString()
          : null;

      final cleanName = (rawName != null &&
              rawName.isNotEmpty &&
              rawName != 'None' &&
              rawName != 'Patient')
          ? rawName
          : null;
      final cleanPhone = Patient.cleanPhone(rawPhone);

      result[cleanApptId] = AppointmentRecord(
        appointmentId: cleanApptId,
        patientName: cleanName,
        phoneNumber: cleanPhone,
      );
    }

    return result;
  }

  /// Stable lightweight fingerprint for already parsed appointment records.
  /// It is used only as a post-processing checkpoint, not as a replacement for
  /// Drive's spreadsheet-level modified/version metadata.
  static String fingerprintPatients(Iterable<Patient> patients) {
    final values = patients
        .map((p) => '${p.normalizedPhone ?? ''}|${p.normalizedName}|${p.driveFolderId ?? ''}')
        .toList()
      ..sort();
    var hash = 2166136261;
    for (final value in values.join('\n').codeUnits) {
      hash ^= value;
      hash = (hash * 16777619) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// Resolves the current master patient view from appointment rows. Phone is
  /// the primary identity when it is a reliable normalized number; a unique
  /// normalized name is the cautious fallback for rows without phones.
  /// Repeated appointments therefore produce one incoming patient record and
  /// no Patient ID column is required.
  static Map<String, Patient> resolvePatientsFromAppointments(
    List<List<dynamic>> rows,
  ) {
    if (rows.isEmpty) return const {};

    var headerRow = -1;
    var appointmentIdCol = -1;
    var nameCol = -1;
    var phoneCol = -1;
    var folderCol = -1;
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      var localName = -1;
      var localPhone = -1;
      var localAppointment = -1;
      var localFolder = -1;
      for (var c = 0; c < row.length; c++) {
        final header = normalizeHeader(row[c]?.toString() ?? '');
        if (isAppointmentHeader(header) && localAppointment == -1) localAppointment = c;
        if ((header == 'patient name' || header == 'name') && localName == -1) localName = c;
        if (isPhoneHeader(header) && localPhone == -1) localPhone = c;
        if ((header == normalizeHeader(AppConfig.photosDriveHeader) ||
                header == normalizeHeader(AppConfig.legacyDriveFolderIdHeader)) &&
            localFolder == -1) {
          localFolder = c;
        }
      }
      if (localName != -1 || localPhone != -1) {
        headerRow = r;
        appointmentIdCol = localAppointment;
        nameCol = localName;
        phoneCol = localPhone;
        folderCol = localFolder;
        break;
      }
    }
    if (headerRow == -1) return const {};

    final groups = <String, _AppointmentGroupData>{};
    for (var r = headerRow + 1; r < rows.length; r++) {
      final row = rows[r];
      final rawName = nameCol >= 0 && nameCol < row.length ? row[nameCol]?.toString().trim() : '';
      final cleanName = Patient.isUsableName(rawName) ? rawName : null;
      final rawPhone = phoneCol >= 0 && phoneCol < row.length ? row[phoneCol]?.toString() : null;
      final cleanPhone = Patient.cleanPhone(rawPhone);
      final normalizedPhone = Patient.normalizePhone(cleanPhone);
      final normalizedName = cleanName == null ? '' : Patient.normalizeName(cleanName);
      if (normalizedPhone == null && normalizedName.isEmpty) continue;

      final rawAppointmentId = appointmentIdCol >= 0 && appointmentIdCol < row.length
          ? row[appointmentIdCol]?.toString().trim() ?? ''
          : '';
      final appointmentId = rawAppointmentId.isNotEmpty
          ? (RegExp(r'^\d+\.0$').hasMatch(rawAppointmentId)
              ? rawAppointmentId.substring(0, rawAppointmentId.length - 2)
              : rawAppointmentId)
          : 'appointment_row_$r';
      final key = normalizedPhone != null && normalizedPhone.isNotEmpty
          ? 'phone:$normalizedPhone'
          : 'name:$normalizedName';
      final group = groups.putIfAbsent(
        key,
        () => _AppointmentGroupData(externalId: appointmentId),
      );
      if (cleanName != null && group.name.isEmpty) group.name = cleanName;
      if (cleanPhone != null && group.phone == null) group.phone = cleanPhone;
      if (folderCol >= 0 && folderCol < row.length) {
        final folder = extractDriveFolderId(row[folderCol]?.toString() ?? '');
        if (folder != null) group.folderIds.add(folder);
      }
    }

    return {
      for (final entry in groups.entries)
        entry.key: Patient(
          id: entry.value.externalId,
          name: entry.value.name,
          displayName: entry.value.name,
          normalizedName: Patient.normalizeName(entry.value.name),
          phoneDisplay: entry.value.phone,
          normalizedPhone: Patient.normalizePhone(entry.value.phone),
          legacyPatientId: entry.value.externalId,
          source: PatientSource.clinicSheet,
          driveFolderId: entry.value.folderIds.length == 1 ? entry.value.folderIds.first : null,
          folderStatus: entry.value.folderIds.isEmpty
              ? FolderStatus.missing
              : (entry.value.folderIds.length == 1 ? FolderStatus.available : FolderStatus.conflict),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
    };
  }

  /// Parses a single header row into a [HeaderIndices] object.
  /// Throws [MissingColumnException] if Patient ID, Patient Name, or Photos (Drive) is missing.
  static HeaderIndices parseHeaderIndices(
    List<dynamic> rawHeaderRow, {
    int headerRowIndex = 0,
    bool requireFolderColumn = false,
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
    final phoneColIndex = _findPhoneColIndex(columnMap);

    if (idColIndex == -1) {
      throw MissingColumnException(AppConfig.patientIdHeader);
    }
    if (nameColIndex == -1) {
      throw MissingColumnException(AppConfig.patientNameHeader);
    }
    if (requireFolderColumn && folderColIndex == -1) {
      throw MissingColumnException(AppConfig.photosDriveHeader);
    }

    return HeaderIndices(
      idColIndex: idColIndex,
      nameColIndex: nameColIndex,
      folderColIndex: folderColIndex,
      phoneColIndex: phoneColIndex,
      headerRowIndex: headerRowIndex,
      columnMap: columnMap,
    );
  }

  /// Discovers the header row dynamically from a list of rows.
  ///
  /// Searches for the row that contains all required columns (Patient ID, Patient Name,
  /// and optionally Photos (Drive) / Drive Folder ID). If found, returns the [HeaderIndices] with the
  /// discovered row index and column positions.
  ///
  /// If no row contains all required headers, evaluates the best candidate row and throws
  /// [MissingColumnException] indicating the missing column.
  static HeaderIndices discoverHeaderIndices(
    List<List<dynamic>> rows, {
    bool requireFolderColumn = false,
  }) {
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

      // If required columns (and folder if required) are present, this is our header row
      final hasRequired = idIdx != -1 && nameIdx != -1 && (!requireFolderColumn || folderIdx != -1);
      if (hasRequired) {
        final phoneIdx = _findPhoneColIndex(columnMap);
        final indices = HeaderIndices(
          idColIndex: idIdx,
          nameColIndex: nameIdx,
          folderColIndex: folderIdx,
          phoneColIndex: phoneIdx,
          headerRowIndex: r,
          columnMap: columnMap,
        );

        debugPrint('Discovered header row: ${indices.headerRowNumber}');
        debugPrint('Patient ID column: $idIdx');
        debugPrint('Patient Name column: $nameIdx');
        debugPrint('Photos (Drive) column: $folderIdx');
        debugPrint('Phone column: $phoneIdx');
        debugPrint('ALL HEADERS: $columnMap');

        return indices;
      }
    }

    // No row contained all required headers.
    // Call parseHeaderIndices on the best candidate row to throw the
    // exact missing column exception (Patient ID, Patient Name, etc.).
    return parseHeaderIndices(
      rows[bestCandidateIndex],
      headerRowIndex: bestCandidateIndex,
      requireFolderColumn: requireFolderColumn,
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
      final rawFolder = (headerIndices.folderColIndex != -1 && headerIndices.folderColIndex < row.length)
          ? row[headerIndices.folderColIndex]?.toString().trim() ?? ''
          : '';
      final rawPhone = (headerIndices.phoneColIndex != null && headerIndices.phoneColIndex! < row.length)
          ? row[headerIndices.phoneColIndex!]?.toString()
          : null;

      if (id.isEmpty) continue;

      // Filter out header tokens if encountered in data rows (e.g. incremental chunks or duplicate headers)
      final normalizedId = normalizeHeader(id);
      if (normalizedId == 'patient id' ||
          normalizedId == 'id' ||
          normalizedId == 'patient' ||
          normalizedId == 'total' ||
          normalizedId == 'totals' ||
          normalizedId == 'count' ||
          normalizedId == 'summary') {
        continue;
      }

      // Normalize numeric ID if formatted as float by Google Sheets (e.g. 1000001.0 -> 1000001)
      String cleanId = id;
      if (RegExp(r'^\d+\.0$').hasMatch(cleanId)) {
        cleanId = cleanId.substring(0, cleanId.length - 2);
      }

      final entry = patientData.putIfAbsent(cleanId, () => _PatientGroupData(id: cleanId));
      final cleanName = name.trim();
      if (cleanName.isNotEmpty &&
          cleanName != 'Patient $cleanId' &&
          cleanName != 'Patient') {
        entry.name = cleanName;
      }

      final cleanPhone = Patient.cleanPhone(rawPhone);
      if (cleanPhone != null && cleanPhone.isNotEmpty) {
        entry.phoneNumber = cleanPhone;
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
      final resolvedName = entry.name.trim();
      final normPhone = Patient.normalizePhone(entry.phoneNumber);

      final folderId = entry.folderIds.length == 1 ? entry.folderIds.first : null;
      final folderStatus = entry.folderIds.isEmpty
          ? FolderStatus.missing
          : (entry.folderIds.length == 1 ? FolderStatus.available : FolderStatus.conflict);

      result[entry.id] = Patient(
        id: entry.id,
        name: resolvedName,
        displayName: resolvedName,
        normalizedName: Patient.normalizeName(resolvedName),
        phoneDisplay: entry.phoneNumber,
        normalizedPhone: normPhone,
        legacyPatientId: entry.id,
        source: PatientSource.clinicSheet,
        driveFolderId: folderId,
        folderStatus: folderStatus,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
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
    final tabs = await fetchSheetTabs(client: client, spreadsheetId: spreadsheetId);
    final effectiveSheetName = tabs.firstWhere(
      isAppointmentsTab,
      orElse: () => sheetName,
    );
    final valueRange = await sheetsApi.spreadsheets.values.get(
      spreadsheetId,
      effectiveSheetName,
    );
    final rawRows = valueRange.values;

    if (rawRows == null || rawRows.isEmpty) {
      return const SheetParseResult(
        patients: [],
        totalRows: 0,
        effectiveSheetName: null,
      );
    }

    final rows = rawRows.cast<List<dynamic>>();
    final isAppointmentMaster = isAppointmentsTab(effectiveSheetName);
    final HeaderIndices? headerIndices;
    final Map<String, Patient> patientsMap;
    if (isAppointmentMaster) {
      headerIndices = null;
      patientsMap = resolvePatientsFromAppointments(rows);
    } else {
      final discovered = discoverHeaderIndices(rows);
      headerIndices = discovered;
      patientsMap = resolvePatientsFromVisits(rows: rows, headerIndices: discovered);
    }

    // 1. Fetch Appointments schedule if present in workbook
    Map<String, AppointmentRecord> appointmentsMap =
        isAppointmentMaster ? parseAppointments(rows) : const {};
    final apptTabName = tabs.firstWhere(
      (t) =>
          isAppointmentsTab(t) &&
           t.trim().toLowerCase() != effectiveSheetName.trim().toLowerCase(),
      orElse: () => '',
    );
    if (apptTabName.isNotEmpty) {
      try {
        final apptRange = await sheetsApi.spreadsheets.values.get(
          spreadsheetId,
          '$apptTabName!A1:Z500',
        );
        final aRows = apptRange.values;
        if (aRows != null && aRows.isNotEmpty) {
          appointmentsMap = parseAppointments(aRows.cast<List<dynamic>>());
        }
      } catch (e) {
        debugPrint('Error fetching Appointments tab: $e');
      }
    }

    // If appointmentsMap is empty, search Drive for companion clinic master sheet (e.g. Advanced Skin Clinic)
    if (appointmentsMap.isEmpty) {
      appointmentsMap = await _fetchAppointmentsFromCompanionDriveSheet(
        client: client,
        sheetsApi: sheetsApi,
        targetSpreadsheetId: spreadsheetId,
      );
    }

    // 2. Fetch Patients directory tab if present in workbook
    final patientsTabName = tabs.firstWhere(
      (t) =>
          isPatientsTab(t) &&
           t.trim().toLowerCase() != effectiveSheetName.trim().toLowerCase(),
      orElse: () => '',
    );
    List<List<dynamic>>? directoryRowsForFolderLinks;
    if (patientsTabName.isNotEmpty) {
      try {
        final patientsRange = await sheetsApi.spreadsheets.values.get(
          spreadsheetId,
          '$patientsTabName!A1:Z500',
        );
        final pRows = patientsRange.values;
        if (pRows != null && pRows.isNotEmpty) {
          directoryRowsForFolderLinks = pRows.cast<List<dynamic>>();
          enrichPatientsFromDirectory(
            patientsMap,
            directoryRowsForFolderLinks,
            appointmentsMap: appointmentsMap,
          );
        }
      } catch (e) {
        debugPrint('Error enriching from Patients tab: $e');
      }
    }

    // The Appointments tab is the patient master, but the legacy Visits tab
    // can still carry the authoritative Drive folder link. Merge only a
    // verified folder match; never let a visit row replace appointment name or
    // phone data, and never guess when identity is ambiguous.
    if (isAppointmentMaster) {
      final visitsTabName = tabs.firstWhere(
        (t) =>
            isVisitsTab(t) &&
            t.trim().toLowerCase() != effectiveSheetName.trim().toLowerCase(),
        orElse: () => '',
      );
      if (visitsTabName.isNotEmpty) {
        try {
          final visitsRange = await sheetsApi.spreadsheets.values.get(
            spreadsheetId,
            '$visitsTabName!A1:ZZ',
          );
          final visitRows = visitsRange.values;
          if (visitRows != null && visitRows.isNotEmpty) {
            enrichPatientsFromVisitsFolders(
              patientsMap,
              visitRows.cast<List<dynamic>>(),
              directoryRows: directoryRowsForFolderLinks,
            );
          }
        } catch (e) {
          debugPrint('Error enriching appointment patients from Visits tab: $e');
        }
      }
    }

    return SheetParseResult(
      patients: patientsMap.values.where((p) => p.hasValidName).toList(),
      totalRows: rows.length,
      headerIndices: headerIndices,
      effectiveSheetName: effectiveSheetName,
    );
  }

  /// Searches Google Drive for a companion master clinic workbook (e.g. "Advanced Skin Clinic")
  /// containing the "Appointments" schedule, and parses appointments.
  Future<Map<String, AppointmentRecord>> _fetchAppointmentsFromCompanionDriveSheet({
    required AuthClient client,
    required sheets.SheetsApi sheetsApi,
    required String targetSpreadsheetId,
  }) async {
    try {
      final driveService = DriveService();
      final spreadsheets = await driveService.listSpreadsheets(client: client);
      final masterFile = spreadsheets.firstWhere(
        (f) {
          final n = f.name?.toLowerCase() ?? '';
          return f.id != targetSpreadsheetId &&
              (n.contains('skin clinic') || n.contains('advanced'));
        },
        orElse: () => drive.File(),
      );

      final masterId = masterFile.id;
      if (masterId == null || masterId.isEmpty) return const {};

      final masterTabs = await fetchSheetTabs(client: client, spreadsheetId: masterId);
      final masterApptTab = masterTabs.firstWhere(
        (t) => isAppointmentsTab(t),
        orElse: () => '',
      );

      if (masterApptTab.isEmpty) return const {};

      final apptRange = await sheetsApi.spreadsheets.values.get(
        masterId,
        '$masterApptTab!A1:Z500',
      );
      final aRows = apptRange.values;
      if (aRows == null || aRows.isEmpty) return const {};

      final appts = parseAppointments(aRows.cast<List<dynamic>>());

      // Attempt to self-heal target spreadsheet by copying the Appointments sheet tab
      try {
        final masterMeta = await sheetsApi.spreadsheets.get(
          masterId,
          $fields: 'sheets(properties(sheetId,title))',
        );
        final tabObj = masterMeta.sheets?.firstWhere(
          (s) => s.properties?.title?.toLowerCase() == masterApptTab.toLowerCase(),
          orElse: () => sheets.Sheet(),
        );
        final sheetId = tabObj?.properties?.sheetId;
        if (sheetId != null) {
          await sheetsApi.spreadsheets.sheets.copyTo(
            sheets.CopySheetToAnotherSpreadsheetRequest(
              destinationSpreadsheetId: targetSpreadsheetId,
            ),
            masterId,
            sheetId,
          );
          debugPrint('Self-healed: copied $masterApptTab into $targetSpreadsheetId');
        }
      } catch (copyErr) {
        debugPrint('Note: could not copy tab into target spreadsheet: $copyErr');
      }

      return appts;
    } catch (e) {
      debugPrint('Error searching Drive for companion Appointments tab: $e');
      return const {};
    }
  }

  /// Enriches patients resolved from visit logs with master patient details
  /// (canonical names, phone numbers) from a clinic "Patients" directory tab,
  /// resolving appointment-linked patients from [appointmentsMap].
  static void enrichPatientsFromDirectory(
    Map<String, Patient> patientsMap,
    List<List<dynamic>> directoryRows, {
    Map<String, AppointmentRecord>? appointmentsMap,
  }) {
    if (directoryRows.isEmpty) return;

    int idCol = -1;
    int apptIdCol = -1;
    int nameCol = -1;
    int phoneCol = -1;
    int dataStartIndex = 0;

    for (int r = 0; r < directoryRows.length; r++) {
      final row = directoryRows[r];
      for (int c = 0; c < row.length; c++) {
        final cell = normalizeHeader(row[c]?.toString() ?? '');
        if (isAppointmentHeader(cell) && apptIdCol == -1) {
          apptIdCol = c;
        } else if (cell == 'patient id' || (cell == 'id' && idCol == -1)) {
          idCol = c;
        } else if (cell == 'patient name' || (cell == 'name' && nameCol == -1)) {
          nameCol = c;
        } else if (isPhoneHeader(cell) && phoneCol == -1) {
          phoneCol = c;
        }
      }
      if (idCol != -1 && (nameCol != -1 || phoneCol != -1 || apptIdCol != -1)) {
        dataStartIndex = r + 1;
        break;
      }
    }

    if (idCol == -1) return;

    for (int r = dataStartIndex; r < directoryRows.length; r++) {
      final row = directoryRows[r];
      if (row.isEmpty || idCol >= row.length) continue;

      final rawId = row[idCol]?.toString().trim() ?? '';
      if (rawId.isEmpty) continue;

      String cleanId = rawId;
      if (RegExp(r'^\d+\.0$').hasMatch(cleanId)) {
        cleanId = cleanId.substring(0, cleanId.length - 2);
      }

      final rawApptId = (apptIdCol != -1 && apptIdCol < row.length)
          ? row[apptIdCol]?.toString().trim()
          : null;
      String? cleanApptId = rawApptId;
      if (cleanApptId != null && RegExp(r'^\d+\.0$').hasMatch(cleanApptId)) {
        cleanApptId = cleanApptId.substring(0, cleanApptId.length - 2);
      }

      final rawName = (nameCol != -1 && nameCol < row.length)
          ? row[nameCol]?.toString().trim()
          : null;
      final rawPhone = (phoneCol != -1 && phoneCol < row.length)
          ? row[phoneCol]?.toString()
          : null;

      String? cleanName = (rawName != null &&
              rawName.isNotEmpty &&
              rawName != 'Patient $cleanId' &&
              rawName != 'Patient' &&
              rawName != 'None' &&
              rawName != 'null' &&
              !rawName.startsWith('#'))
          ? rawName
          : null;

      String? cleanPhoneNumber = Patient.cleanPhone(rawPhone);

      // If name or phone is missing from Patients directory row, resolve from Appointments schedule
      if (cleanApptId != null && cleanApptId.isNotEmpty && appointmentsMap != null) {
        final appt = appointmentsMap[cleanApptId];
        if (appt != null) {
          if (cleanName == null || cleanName.isEmpty) {
            cleanName = appt.patientName;
          }
          if (cleanPhoneNumber == null || cleanPhoneNumber.isEmpty) {
            cleanPhoneNumber = appt.phoneNumber;
          }
        }
      }

      final normPhone = Patient.normalizePhone(cleanPhoneNumber);

      var existingKey = cleanId;
      var existing = patientsMap[existingKey];
      if (existing == null && cleanApptId != null && cleanApptId.isNotEmpty) {
        for (final entry in patientsMap.entries) {
          if (entry.value.legacyPatientId == cleanApptId) {
            existingKey = entry.key;
            existing = entry.value;
            break;
          }
        }
      }
      if (existing == null && normPhone != null && normPhone.isNotEmpty) {
        for (final entry in patientsMap.entries) {
          if (entry.value.normalizedPhone == normPhone) {
            existingKey = entry.key;
            existing = entry.value;
            break;
          }
        }
      }
      if (existing != null) {
        final updatedName = existing.hasValidName
            ? existing.name
            : (cleanName ?? existing.name);
        final updatedPhone = existing.phoneNumber ?? cleanPhoneNumber;
        final updatedNormPhone = existing.phoneNumberNormalized ?? normPhone;

        patientsMap[existingKey] = Patient(
          id: existing.id,
          legacyPatientId: existing.legacyPatientId ?? cleanId,
          name: updatedName,
          displayName: updatedName,
          normalizedName: Patient.normalizeName(updatedName),
          phoneNumber: updatedPhone,
          phoneDisplay: updatedPhone,
          phoneNumberNormalized: updatedNormPhone,
          normalizedPhone: updatedNormPhone,
          driveFolderId: existing.driveFolderId,
          folderStatus: existing.folderStatus,
          createdAt: existing.createdAt,
          updatedAt: existing.updatedAt,
          source: existing.source,
        );
      }
    }
  }

  /// Copies verified Drive folder identity from a legacy Visits tab onto the
  /// Appointments patient master. Phone is the primary match; a unique name is
  /// the fallback. A conflicting folder mapping remains a conflict instead of
  /// being silently selected.
  static void enrichPatientsFromVisitsFolders(
    Map<String, Patient> patientsMap,
    List<List<dynamic>> visitsRows,
    {
    List<List<dynamic>>? directoryRows,
    }
  ) {
    if (patientsMap.isEmpty || visitsRows.isEmpty) return;

    late final HeaderIndices headers;
    try {
      headers = discoverHeaderIndices(visitsRows);
    } catch (_) {
      return;
    }
    final visitPatients = resolvePatientsFromVisits(
      rows: visitsRows,
      headerIndices: headers,
    );
    final directoryAppointmentByPatientId = _directoryAppointmentLinks(directoryRows);

    Patient? findMatch(Patient visitPatient, String? appointmentId) {
      if (appointmentId != null && appointmentId.isNotEmpty) {
        final matches = patientsMap.values
            .where((p) => p.legacyPatientId == appointmentId)
            .toList();
        if (matches.length == 1) return matches.single;
      }
      if (visitPatient.normalizedPhone != null && visitPatient.normalizedPhone!.isNotEmpty) {
        final matches = patientsMap.values
            .where((p) => p.normalizedPhone == visitPatient.normalizedPhone)
            .toList();
        if (matches.length == 1) return matches.single;
        return null;
      }
      if (visitPatient.hasValidName) {
        final matches = patientsMap.values
            .where((p) => p.normalizedName == visitPatient.normalizedName)
            .toList();
        if (matches.length == 1) return matches.single;
      }
      return null;
    }

    final representativeByIdentity = <String, Patient>{};
    final appointmentIdByIdentity = <String, String>{};
    final foldersByIdentity = <String, Set<String>>{};
    final conflictsByIdentity = <String>{};
    for (final visitPatient in visitPatients.values) {
      final linkedAppointmentId = directoryAppointmentByPatientId[visitPatient.legacyPatientId];
      final identity = linkedAppointmentId != null
          ? 'appointment:$linkedAppointmentId'
          : (visitPatient.normalizedPhone != null &&
              visitPatient.normalizedPhone!.isNotEmpty
              ? 'phone:${visitPatient.normalizedPhone}'
              : (visitPatient.hasValidName ? 'name:${visitPatient.normalizedName}' : ''));
      if (identity.isEmpty) continue;
      representativeByIdentity.putIfAbsent(identity, () => visitPatient);
      if (linkedAppointmentId != null && linkedAppointmentId.isNotEmpty) {
        appointmentIdByIdentity[identity] = linkedAppointmentId;
      }
      if (visitPatient.folderStatus == FolderStatus.conflict) {
        conflictsByIdentity.add(identity);
      }
      final folderId = visitPatient.driveFolderId;
      if (folderId != null && folderId.isNotEmpty) {
        foldersByIdentity.putIfAbsent(identity, () => <String>{}).add(folderId);
      }
    }

    for (final entry in representativeByIdentity.entries) {
      final visitPatient = entry.value;
      final folders = foldersByIdentity[entry.key] ?? const <String>{};
      final conflict = conflictsByIdentity.contains(entry.key) || folders.length > 1;
      if (!conflict && folders.isEmpty) continue;

      final matched = findMatch(visitPatient, appointmentIdByIdentity[entry.key]);
      if (matched == null) continue;

      final folderId = folders.length == 1 ? folders.single : null;
      final updated = Patient(
        id: matched.id,
        name: matched.name,
        displayName: matched.displayName,
        normalizedName: matched.normalizedName,
        phoneDisplay: matched.phoneDisplay,
        normalizedPhone: matched.normalizedPhone,
        legacyPatientId: matched.legacyPatientId,
        source: matched.source,
        driveFolderId: conflict ? null : folderId,
        folderStatus: conflict ? FolderStatus.conflict : FolderStatus.available,
        createdAt: matched.createdAt,
        updatedAt: DateTime.now(),
        syncStatus: matched.syncStatus,
      );
      final key = patientsMap.entries
          .firstWhere((entry) => entry.value.id == matched.id)
          .key;
      patientsMap[key] = updated;
    }
  }

  static Map<String, String> _directoryAppointmentLinks(
    List<List<dynamic>>? directoryRows,
  ) {
    if (directoryRows == null || directoryRows.isEmpty) return const {};

    var patientIdCol = -1;
    var appointmentIdCol = -1;
    var dataStartIndex = 0;
    for (var r = 0; r < directoryRows.length; r++) {
      final row = directoryRows[r];
      for (var c = 0; c < row.length; c++) {
        final header = normalizeHeader(row[c]?.toString() ?? '');
        if (header == 'patient id' || (header == 'id' && patientIdCol == -1)) {
          patientIdCol = c;
        } else if (isAppointmentHeader(header) && appointmentIdCol == -1) {
          appointmentIdCol = c;
        }
      }
      if (patientIdCol != -1 && appointmentIdCol != -1) {
        dataStartIndex = r + 1;
        break;
      }
    }
    if (patientIdCol == -1 || appointmentIdCol == -1) return const {};

    String cleanId(dynamic value) {
      var id = value?.toString().trim() ?? '';
      if (RegExp(r'^\d+\.0$').hasMatch(id)) id = id.substring(0, id.length - 2);
      return id;
    }

    final result = <String, String>{};
    for (var r = dataStartIndex; r < directoryRows.length; r++) {
      final row = directoryRows[r];
      if (patientIdCol >= row.length || appointmentIdCol >= row.length) continue;
      final patientId = cleanId(row[patientIdCol]);
      final appointmentId = cleanId(row[appointmentIdCol]);
      if (patientId.isNotEmpty && appointmentId.isNotEmpty) {
        result[patientId] = appointmentId;
      }
    }
    return result;
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

      try {
        final tabs = await fetchSheetTabs(client: client, spreadsheetId: spreadsheetId);
        Map<String, AppointmentRecord> appointmentsMap = const {};
        final apptTabName = tabs.firstWhere(
          (t) =>
              isAppointmentsTab(t) &&
              t.trim().toLowerCase() != sheetName.trim().toLowerCase(),
          orElse: () => '',
        );
        if (apptTabName.isNotEmpty) {
          final apptRange = await sheetsApi.spreadsheets.values.get(
            spreadsheetId,
            '$apptTabName!A1:Z500',
          );
          final aRows = apptRange.values;
          if (aRows != null && aRows.isNotEmpty) {
            appointmentsMap = parseAppointments(aRows.cast<List<dynamic>>());
          }
        }
        if (appointmentsMap.isEmpty) {
          appointmentsMap = await _fetchAppointmentsFromCompanionDriveSheet(
            client: client,
            sheetsApi: sheetsApi,
            targetSpreadsheetId: spreadsheetId,
          );
        }

        final patientsTabName = tabs.firstWhere(
          (t) =>
              isPatientsTab(t) &&
              t.trim().toLowerCase() != sheetName.trim().toLowerCase(),
          orElse: () => '',
        );
        if (patientsTabName.isNotEmpty) {
          final patientsRange = await sheetsApi.spreadsheets.values.get(
            spreadsheetId,
            '$patientsTabName!A1:Z500',
          );
          final pRows = patientsRange.values;
          if (pRows != null && pRows.isNotEmpty) {
            enrichPatientsFromDirectory(
              resolvedMap,
              pRows.cast<List<dynamic>>(),
              appointmentsMap: appointmentsMap,
            );
          }
        }
      } catch (e) {
        debugPrint('Error enriching incremental patients: $e');
      }

      return IncrementalSyncResult(
        updatedPatients: resolvedMap.values.where((p) => p.hasValidName).toList(),
        newRowsCount: newRows.length,
        newLastSyncedRow: lastSyncedRow + newRows.length,
      );
    } catch (_) {
      return null;
    }
  }

  /// Formats incremental sync range string according to Section 23.5:
  /// `Visits!A{lastSyncedRow}:Z{lastSyncedRow + 500}`
  static String buildIncrementalRange(String sheetName, int lastSyncedRow, [int chunkSize = 500]) {
    return '$sheetName!A$lastSyncedRow:Z${lastSyncedRow + chunkSize}';
  }

  /// Converts a zero-based column index to A1 notation column letter(s) (e.g. 0 -> A, 14 -> O, 26 -> AA).
  static String columnIndexToA1Notation(int colIndex) {
    int c = colIndex;
    String result = '';
    while (c >= 0) {
      result = String.fromCharCode(65 + (c % 26)) + result;
      c = (c ~/ 26) - 1;
    }
    return result;
  }

  /// Writes the [folderUrl] back to all blank Visits rows for the specified [patientId].
  ///
  /// Scans rows for matches and issues a single batchUpdate to write the folder URL to those cells.
  Future<int> writePatientFolderUrl({
    required AuthClient client,
    required String spreadsheetId,
    required String sheetName,
    required String patientId,
    required String folderUrl,
    HeaderIndices? headerIndices,
  }) async {
    final sheetsApi = sheets.SheetsApi(client);

    final valueRange = await sheetsApi.spreadsheets.values.get(
      spreadsheetId,
      sheetName,
    );

    final rawRows = valueRange.values;
    if (rawRows == null || rawRows.isEmpty) return 0;

    final rows = rawRows.cast<List<dynamic>>();
    final headers = headerIndices ?? discoverHeaderIndices(rows);

    final folderColLetter = columnIndexToA1Notation(headers.folderColIndex);
    final List<sheets.ValueRange> dataToUpdate = [];

    final cleanTargetId = RegExp(r'^\d+\.0$').hasMatch(patientId.trim())
        ? patientId.trim().substring(0, patientId.trim().length - 2)
        : patientId.trim();

    for (int r = headers.headerRowIndex + 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.isEmpty) continue;

      final rawId = headers.idColIndex < row.length
          ? row[headers.idColIndex]?.toString().trim() ?? ''
          : '';

      final cleanRowId = RegExp(r'^\d+\.0$').hasMatch(rawId)
          ? rawId.substring(0, rawId.length - 2)
          : rawId;

      if (cleanRowId != cleanTargetId) continue;

      final currentFolder = headers.folderColIndex < row.length
          ? row[headers.folderColIndex]?.toString().trim() ?? ''
          : '';

      if (currentFolder.isEmpty) {
        final rowNumber = r + 1; // 1-based row number
        final cellRange = '$sheetName!$folderColLetter$rowNumber';
        dataToUpdate.add(sheets.ValueRange(
          range: cellRange,
          values: [
            [folderUrl],
          ],
        ));
      }
    }

    if (dataToUpdate.isEmpty) return 0;

    final batchRequest = sheets.BatchUpdateValuesRequest(
      valueInputOption: 'USER_ENTERED',
      data: dataToUpdate,
    );

    await sheetsApi.spreadsheets.values.batchUpdate(
      batchRequest,
      spreadsheetId,
    );

    debugPrint(
      'Wrote Drive folder URL to ${dataToUpdate.length} blank Visits rows for Patient $patientId',
    );
    return dataToUpdate.length;
  }
}
