class ClinicConfig {
  final String spreadsheetId;
  final String spreadsheetUrl;
  final String sheetTabName;
  final String parentDriveFolderId;
  final bool hasCompletedSetup;
  final String? lastPatientSync;
  final int lastSyncedRow;
  final String? lastFullSync;
  final String? lastSheetModifiedTime;
  final String? lastSheetVersion;
  final String? lastPatientFingerprint;

  const ClinicConfig({
    required this.spreadsheetId,
    required this.spreadsheetUrl,
    required this.sheetTabName,
    this.parentDriveFolderId = '',
    this.hasCompletedSetup = false,
    this.lastPatientSync,
    this.lastSyncedRow = 1,
    this.lastFullSync,
    this.lastSheetModifiedTime,
    this.lastSheetVersion,
    this.lastPatientFingerprint,
  });

  ClinicConfig copyWith({
    String? spreadsheetId,
    String? spreadsheetUrl,
    String? sheetTabName,
    String? parentDriveFolderId,
    bool? hasCompletedSetup,
    String? lastPatientSync,
    int? lastSyncedRow,
    String? lastFullSync,
    String? lastSheetModifiedTime,
    String? lastSheetVersion,
    String? lastPatientFingerprint,
  }) {
    return ClinicConfig(
      spreadsheetId: spreadsheetId ?? this.spreadsheetId,
      spreadsheetUrl: spreadsheetUrl ?? this.spreadsheetUrl,
      sheetTabName: sheetTabName ?? this.sheetTabName,
      parentDriveFolderId: parentDriveFolderId ?? this.parentDriveFolderId,
      hasCompletedSetup: hasCompletedSetup ?? this.hasCompletedSetup,
      lastPatientSync: lastPatientSync ?? this.lastPatientSync,
      lastSyncedRow: lastSyncedRow ?? this.lastSyncedRow,
      lastFullSync: lastFullSync ?? this.lastFullSync,
      lastSheetModifiedTime: lastSheetModifiedTime ?? this.lastSheetModifiedTime,
      lastSheetVersion: lastSheetVersion ?? this.lastSheetVersion,
      lastPatientFingerprint: lastPatientFingerprint ?? this.lastPatientFingerprint,
    );
  }

  @override
  String toString() =>
      'ClinicConfig(sheetId: $spreadsheetId, tab: $sheetTabName, parentFolder: $parentDriveFolderId, setup: $hasCompletedSetup, lastSyncedRow: $lastSyncedRow)';
}
