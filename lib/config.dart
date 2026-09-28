/// Developer-owned immutable application constants.
/// Clinic-specific settings (Spreadsheet ID, Sheet Tab Name) are entered
/// by the doctor in-app and stored in SharedPreferences.
abstract final class AppConfig {
  static const String appName = 'Clinic Photos';

  /// Google OAuth 2.0 Web Client ID / Server Client ID from Google Cloud Console.
  /// Required by Google Identity Services (Credential Manager) on modern Android.
  static const String serverClientId =
      '911718488219-1u6n82fet84vt0gv6o1vjuo69oa2hgcp.apps.googleusercontent.com';

  /// Google OAuth 2.0 Scopes.
  /// - spreadsheets.readonly: To retrieve patient database rows & tabs
  /// - drive: Broad scope intentional for internal one-doctor clinic to upload
  ///   into pre-existing clinic patient folders.
  static const List<String> googleScopes = <String>[
    'https://www.googleapis.com/auth/spreadsheets.readonly',
    'https://www.googleapis.com/auth/drive',
  ];

  /// Standard column header names in the clinic Google Sheet.
  /// Column order in the spreadsheet does not matter.
  static const String patientIdHeader = 'Patient ID';
  static const String patientNameHeader = 'Patient Name';
  static const String driveFolderIdHeader = 'Drive Folder ID';

  /// Private app-specific folder for queued clinical photos.
  static const String photoQueueDirName = 'photo_queue';
}
