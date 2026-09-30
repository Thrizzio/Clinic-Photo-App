import 'package:flutter/material.dart';
import 'config.dart';
import 'screens/patients_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/config_service.dart';
import 'services/database.dart';
import 'services/drive.dart';
import 'services/google_auth.dart';
import 'services/sheets.dart';
import 'services/upload_queue.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final configService = await ConfigService.init();
  final database = await AppDatabase.init();
  final authService = GoogleAuthService();
  final sheetsService = SheetsService();
  final driveService = DriveService();

  final queueService = UploadQueueService(
    database: database,
    authService: authService,
    driveService: driveService,
  );

  final config = configService.loadConfig();

  // If already set up, attempt silent sign-in and resume pending uploads
  if (config.hasCompletedSetup) {
    await authService.signInSilently();
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
  final bool hasCompletedSetup;

  const ClinicPhotosApp({
    super.key,
    required this.configService,
    required this.database,
    required this.authService,
    required this.sheetsService,
    required this.driveService,
    required this.queueService,
    required this.hasCompletedSetup,
  });

  @override
  Widget build(BuildContext context) {
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
      themeMode: ThemeMode.system,
      home: hasCompletedSetup
          ? PatientsScreen(
              authService: authService,
              configService: configService,
              sheetsService: sheetsService,
              database: database,
              queueService: queueService,
              driveService: driveService,
            )
          : WelcomeScreen(
              authService: authService,
              configService: configService,
              sheetsService: sheetsService,
              database: database,
              queueService: queueService,
              driveService: driveService,
            ),
    );
  }
}
