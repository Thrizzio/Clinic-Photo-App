/// Developer-owned immutable application constants.
/// Clinic-specific settings (Spreadsheet ID, Sheet Tab Name) are entered
/// by the doctor in-app and stored in SharedPreferences.
abstract final class AppConfig {
  static const String appName = 'Clinic Photos';

  /// Google OAuth 2.0 Web Client ID / Server Client ID from Google Cloud Console.
  /// Required by Google Identity Services (Credential Manager) on modern Android.
  static const String serverClientId =
      '911718488219-n05lbgpq9oh9tueutq2km3fvithtpnjh.apps.googleusercontent.com';

  /// Google OAuth 2.0 Scopes.
  /// - spreadsheets: To read visits and write back generated Drive folder links
  /// - drive: Broad scope to create patient folders and upload clinical photos.
  static const List<String> googleScopes = <String>[
    'https://www.googleapis.com/auth/spreadsheets',
    'https://www.googleapis.com/auth/spreadsheets.readonly',
    'https://www.googleapis.com/auth/drive',
  ];

  /// Standard column header names in the clinic Google Sheet (Visits table).
  /// Column order in the spreadsheet does not matter.
  static const String patientIdHeader = 'Patient ID';
  static const String patientNameHeader = 'Patient Name';
  static const String photosDriveHeader = 'Photos (Drive)';
  static const String legacyDriveFolderIdHeader = 'Drive Folder ID';
  static const String driveFolderIdHeader = legacyDriveFolderIdHeader;

  /// Private app-specific folders for queued and unassigned clinical photos.
  static const String photoQueueDirName = 'photo_queue';
  static const String unassignedDirName = 'unassigned';
}
