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

  /// Supabase project credentials.
  /// Configurable via compile-time `--dart-define` or app settings.
  static const String defaultSupabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://ovqlmuulpfvdhollnfne.supabase.co',
  );
  static const String defaultSupabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im92cWxtdXVscGZ2ZGhvbGxuZm5lIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEwMTk5MTAsImV4cCI6MjEwNjU5NTkxMH0.12UB-H8YnewC_kGGuxB9cns6Gz_DlGnGYsGX-JSAH-Q',
  );

  /// Default clinic doctor credentials for Supabase authenticated session.
  /// Configurable via compile-time `--dart-define` or in-app account manager.
  static const String defaultDoctorEmail = String.fromEnvironment(
    'DOCTOR_EMAIL',
    defaultValue: 'doctor2@clinic.com',
  );
  static const String defaultDoctorPassword = String.fromEnvironment(
    'DOCTOR_PASSWORD',
    defaultValue: 'ClinicSecurePassword2026!',
  );

  /// Returns the HTTPS REST URL for Supabase.
  /// If a postgresql:// connection string was provided, automatically extracts
  /// the project ref and converts it to `https://<project-ref>.supabase.co`.
  static String get supabaseUrl {
    final raw = defaultSupabaseUrl.trim();
    if (raw.startsWith('postgresql://') || raw.startsWith('postgres://')) {
      final match = RegExp(r'db\.([a-z0-9]+)\.supabase\.co').firstMatch(raw);
      if (match != null) {
        return 'https://${match.group(1)}.supabase.co';
      }
    }
    return raw;
  }
}
