class ClinicConfig {
  final String spreadsheetId;
  final String spreadsheetUrl;
  final String sheetTabName;
  final bool hasCompletedSetup;
  final String? lastPatientSync;
  final int lastSyncedRow;
  final String? lastFullSync;

  const ClinicConfig({
    required this.spreadsheetId,
    required this.spreadsheetUrl,
    required this.sheetTabName,
    this.hasCompletedSetup = false,
    this.lastPatientSync,
    this.lastSyncedRow = 1,
    this.lastFullSync,
  });

  ClinicConfig copyWith({
    String? spreadsheetId,
    String? spreadsheetUrl,
    String? sheetTabName,
    bool? hasCompletedSetup,
    String? lastPatientSync,
    int? lastSyncedRow,
    String? lastFullSync,
  }) {
    return ClinicConfig(
      spreadsheetId: spreadsheetId ?? this.spreadsheetId,
      spreadsheetUrl: spreadsheetUrl ?? this.spreadsheetUrl,
      sheetTabName: sheetTabName ?? this.sheetTabName,
      hasCompletedSetup: hasCompletedSetup ?? this.hasCompletedSetup,
      lastPatientSync: lastPatientSync ?? this.lastPatientSync,
      lastSyncedRow: lastSyncedRow ?? this.lastSyncedRow,
      lastFullSync: lastFullSync ?? this.lastFullSync,
    );
  }

  @override
  String toString() =>
      'ClinicConfig(sheetId: $spreadsheetId, tab: $sheetTabName, setup: $hasCompletedSetup, lastSyncedRow: $lastSyncedRow)';
}
