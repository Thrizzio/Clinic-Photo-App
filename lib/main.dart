import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'screens/patients_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/config_service.dart';
import 'services/database.dart';
import 'services/drive.dart';
import 'services/google_auth.dart';
import 'services/sheets.dart';
import 'services/upload_queue.dart';
import 'services/patient_folder_service.dart';
import 'services/supabase_patient_service.dart';
import 'services/supabase_auth_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final configService = await ConfigService.init();
  final database = await AppDatabase.init();
  final authService = GoogleAuthService();
  final sheetsService = SheetsService();
  final driveService = DriveService();

  SupabasePatientService? supabaseService;
  SupabaseAuthService? supabaseAuthService;
  try {
    final url = AppConfig.supabaseUrl;
    final key = AppConfig.defaultSupabaseAnonKey;
    if (url.startsWith('https://') &&
        !url.contains('xyzcompany') &&
        !key.contains('placeholder')) {
      await Supabase.initialize(
        url: url,
        // ignore: deprecated_member_use
        anonKey: key,
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.implicit,
        ),
      );
      final client = Supabase.instance.client;
      supabaseAuthService = SupabaseAuthService(
        client: client,
        configService: configService,
      );
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
  );

  final queueService = UploadQueueService(
    database: database,
    authService: authService,
    driveService: driveService,
    patientFolderService: folderService,
  );

  final config = configService.loadConfig();

  // If already set up, attempt silent sign-in and resume pending uploads
  if (config.hasCompletedSetup) {
    final account = await authService.signInSilently();
    if (account != null && supabaseAuthService != null && !supabaseAuthService.isAuthenticated) {
      final auth = account.authentication;
      final idToken = auth.idToken;
      if (idToken != null && idToken.isNotEmpty) {
        try {
          await supabaseAuthService.signInWithGoogle(idToken: idToken);
        } catch (e) {
          debugPrint('Silent Supabase auth notice: $e');
        }
      }
    }
    // Wake up queue processor in background to resume any pending uploads
    queueService.processQueue();
  }

  runApp(ClinicPhotosApp(
    configService: configService,
    database: database,
    authService: authService,
    sheetsService: sheetsService,
    driveService: driveService,
    queueService: queueService,
    supabaseService: supabaseService,
    supabaseAuthService: supabaseAuthService,
    hasCompletedSetup: config.hasCompletedSetup,
  ));
}

class ClinicPhotosApp extends StatelessWidget {
  final ConfigService configService;
  final AppDatabase database;
  final GoogleAuthService authService;
  final SheetsService sheetsService;
  final DriveService driveService;
  final UploadQueueService queueService;
  final SupabasePatientService? supabaseService;
  final SupabaseAuthService? supabaseAuthService;
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
    this.supabaseAuthService,
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
