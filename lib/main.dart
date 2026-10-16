import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'screens/patients_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/config_service.dart';
import 'services/background_upload_worker.dart';
import 'services/database.dart';
import 'services/drive.dart';
import 'services/google_auth.dart';
import 'services/sheets.dart';
import 'services/upload_queue.dart';
import 'services/patient_folder_service.dart';
import 'services/supabase_patient_service.dart';
import 'services/sync_diagnostics.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final startupTrace = SyncDiagnostics.start('startup', trigger: 'main');

  final configService = await startupTrace.stage(
    'config_init',
    ConfigService.init,
  );
  final database = await startupTrace.stage('database_init', AppDatabase.init);
  final authService = GoogleAuthService();
  final sheetsService = SheetsService();
  final driveService = DriveService();
  final backgroundUploadWorker = BackgroundUploadWorker();
  try {
    await startupTrace.stage(
      'workmanager_init',
      backgroundUploadWorker.initialize,
    );
  } catch (e) {
    // The in-process queue remains usable if WorkManager is unavailable on a
    // particular device or during a development/test launch.
    debugPrint('Could not initialize background upload worker: $e');
  }

  SupabasePatientService? supabaseService;
  try {
    final url = AppConfig.supabaseUrl;
    final key = AppConfig.defaultSupabaseAnonKey;
    if (url.startsWith('https://') &&
        !url.contains('xyzcompany') &&
        !key.contains('placeholder')) {
      await startupTrace.stage(
        'supabase_init',
        () => Supabase.initialize(
          url: url,
          // ignore: deprecated_member_use
          anonKey: key,
          authOptions: const FlutterAuthClientOptions(
            authFlowType: AuthFlowType.implicit,
          ),
        ),
      );
      final client = Supabase.instance.client;
      supabaseService = SupabasePatientService.live(client);
    }
  } catch (e) {
    debugPrint('Could not initialize live Supabase client: $e');
  }

  final folderService = PatientFolderService(
    driveService: driveService,
    sheetsService: sheetsService,
    authService: authService,
    configService: configService,
    database: database,
    supabaseService: supabaseService,
  );

  final queueService = UploadQueueService(
    database: database,
    authService: authService,
    driveService: driveService,
    patientFolderService: folderService,
    scheduleBackgroundWork: backgroundUploadWorker.scheduleNow,
  );

  final config = configService.loadConfig();

  await startupTrace.stage(
    'run_app',
    () async {
      runApp(ClinicPhotosApp(
        configService: configService,
        database: database,
        authService: authService,
        sheetsService: sheetsService,
        driveService: driveService,
        queueService: queueService,
        supabaseService: supabaseService,
        hasCompletedSetup: config.hasCompletedSetup,
      ));
    },
  );

  // Do not hold the first frame hostage to Google Credential Manager or a
  // network retry. SQLite-backed patients must render even when Google auth
  // is unavailable; the durable queue will retry silently when authorized.
  if (config.hasCompletedSetup) {
    unawaited(
      SyncDiagnostics.run(
        SyncDiagnostics.start('upload_queue_wake', trigger: 'startup'),
        () async {
          try {
            await queueService.wake();
            SyncDiagnostics.current?.finish(outcome: 'success');
          } catch (error) {
            SyncDiagnostics.current?.finish(
              outcome: 'error',
              fields: <String, Object?>{'errorType': error.runtimeType.toString()},
            );
            rethrow;
          }
        },
      ),
    );
  }
  startupTrace.finish(outcome: 'complete');
}

class ClinicPhotosApp extends StatelessWidget {
  final ConfigService configService;
  final AppDatabase database;
  final GoogleAuthService authService;
  final SheetsService sheetsService;
  final DriveService driveService;
  final UploadQueueService queueService;
  final SupabasePatientService? supabaseService;
  final bool hasCompletedSetup;

  const ClinicPhotosApp({
    super.key,
    required this.configService,
    required this.database,
    required this.authService,
    required this.sheetsService,
    required this.driveService,
    required this.queueService,
    this.supabaseService,
    required this.hasCompletedSetup,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: configService.themeModeNotifier,
      builder: (context, currentThemeMode, _) {
        return MaterialApp(
          title: AppConfig.appName,
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF006688), // Professional clinical teal/blue
              brightness: Brightness.light,
            ),
            appBarTheme: const AppBarTheme(
              centerTitle: false,
              elevation: 0,
              scrolledUnderElevation: 1,
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF006688),
              brightness: Brightness.dark,
            ),
            appBarTheme: const AppBarTheme(
              centerTitle: false,
              elevation: 0,
              scrolledUnderElevation: 1,
            ),
          ),
          themeMode: currentThemeMode,
          home: hasCompletedSetup
              ? PatientsScreen(
                  authService: authService,
                  configService: configService,
                  sheetsService: sheetsService,
                  database: database,
                  queueService: queueService,
                  driveService: driveService,
                  supabaseService: supabaseService,
                )
              : WelcomeScreen(
                  authService: authService,
                  configService: configService,
                  sheetsService: sheetsService,
                  database: database,
                  queueService: queueService,
                  driveService: driveService,
                  supabaseService: supabaseService,
                ),
        );
      },
    );
  }
}
