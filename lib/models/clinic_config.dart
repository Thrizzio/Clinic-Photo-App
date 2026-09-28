class ClinicConfig {
  final String spreadsheetId;
  final String spreadsheetUrl;
  final String sheetTabName;
  final bool hasCompletedSetup;
  final String? lastPatientSync;

  const ClinicConfig({
    required this.spreadsheetId,
    required this.spreadsheetUrl,
    required this.sheetTabName,
    this.hasCompletedSetup = false,
    this.lastPatientSync,
  });

  ClinicConfig copyWith({
    String? spreadsheetId,
    String? spreadsheetUrl,
    String? sheetTabName,
    bool? hasCompletedSetup,
    String? lastPatientSync,
  }) {
    return ClinicConfig(
      spreadsheetId: spreadsheetId ?? this.spreadsheetId,
      spreadsheetUrl: spreadsheetUrl ?? this.spreadsheetUrl,
      sheetTabName: sheetTabName ?? this.sheetTabName,
      hasCompletedSetup: hasCompletedSetup ?? this.hasCompletedSetup,
      lastPatientSync: lastPatientSync ?? this.lastPatientSync,
    );
  }

  @override
  String toString() =>
      'ClinicConfig(sheetId: $spreadsheetId, tab: $sheetTabName, setup: $hasCompletedSetup)';
}
