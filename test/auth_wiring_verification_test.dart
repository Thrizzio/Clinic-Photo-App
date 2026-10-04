import 'package:clinic_photos/main.dart';
import 'package:clinic_photos/models/clinic_config.dart';
import 'package:clinic_photos/screens/patients_screen.dart';
import 'package:clinic_photos/screens/settings_screen.dart';
import 'package:clinic_photos/screens/welcome_screen.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/supabase_patient_service.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Single-Clinic Direct Database Architecture Tests', () {
    late ConfigService configService;
    late InMemoryAppDatabase database;
    late GoogleAuthService authService;
    late SheetsService sheetsService;
    late DriveService driveService;
    late UploadQueueService queueService;
    late SupabasePatientService supabaseService;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      configService = await ConfigService.init();
      database = InMemoryAppDatabase();
      authService = GoogleAuthService();
      sheetsService = SheetsService();
      driveService = DriveService();
      queueService = UploadQueueService(
        database: database,
        driveService: driveService,
        authService: authService,
      );
      supabaseService = SupabasePatientService.inMemory();
    });

    testWidgets('1. ClinicPhotosApp mounts PatientsScreen with supabaseService when setup completed', (tester) async {
      await configService.saveConfig(
        const ClinicConfig(
          spreadsheetId: 'test_sheet',
          spreadsheetUrl: 'https://docs.google.com/spreadsheets/d/test_sheet/edit',
          sheetTabName: 'Visits',
          hasCompletedSetup: true,
          lastSyncedRow: 10,
        ),
      );

      await tester.pumpWidget(
        ClinicPhotosApp(
          configService: configService,
          database: database,
          authService: authService,
          sheetsService: sheetsService,
          driveService: driveService,
          queueService: queueService,
          supabaseService: supabaseService,
          hasCompletedSetup: true,
        ),
      );

      await tester.pump();

      final patientsScreenFinder = find.byType(PatientsScreen);
      expect(patientsScreenFinder, findsOneWidget);

      final patientsScreen = tester.widget<PatientsScreen>(patientsScreenFinder);
      expect(patientsScreen.supabaseService, isNotNull);
    });

    testWidgets('2. ClinicPhotosApp mounts WelcomeScreen when setup not completed', (tester) async {
      await tester.pumpWidget(
        ClinicPhotosApp(
          configService: configService,
          database: database,
          authService: authService,
          sheetsService: sheetsService,
          driveService: driveService,
          queueService: queueService,
          supabaseService: supabaseService,
          hasCompletedSetup: false,
        ),
      );

      await tester.pump();

      final welcomeScreenFinder = find.byType(WelcomeScreen);
      expect(welcomeScreenFinder, findsOneWidget);
    });

    testWidgets('3. SettingsScreen shows direct multi-device sync active status with NO login forms', (tester) async {
      tester.view.physicalSize = const Size(800 * 2.0, 1200 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            authService: authService,
            configService: configService,
            sheetsService: sheetsService,
            database: database,
            queueService: queueService,
            supabaseService: supabaseService,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Scroll down to the Supabase section
      final supabaseHeader = find.text('Clinic Cloud Database (Supabase)');
      await tester.scrollUntilVisible(
        supabaseHeader,
        300.0,
        scrollable: find.byType(Scrollable),
      );
      await tester.pumpAndSettle();

      expect(supabaseHeader, findsOneWidget);
      expect(find.text('Connected · Multi-Device Sync Active'), findsOneWidget);
      expect(find.text('Synchronizing patient profiles with clinic cloud database'), findsOneWidget);

      // Verify no login/register buttons or password forms
      expect(find.text('Sign In / Register'), findsNothing);
      expect(find.text('Doctor Email'), findsNothing);
      expect(find.text('Password'), findsNothing);
      expect(find.text('Create Account'), findsNothing);
      expect(find.text('Sign Out of Clinic Cloud'), findsNothing);
    });
  });
}
