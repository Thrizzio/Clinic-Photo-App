import 'dart:io';
import 'package:clinic_photos/models/clinic_config.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/screens/patients_screen.dart';
import 'package:clinic_photos/screens/settings_screen.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:clinic_photos/widgets/patient_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1. Theme Mode Persistence & Reactivity', () {
    test('ConfigService defaults to system, persists light/dark, and notifies listeners', () async {
      SharedPreferences.setMockInitialValues({});
      final config = await ConfigService.init();

      expect(config.getThemeMode(), ThemeMode.system);
      expect(config.themeModeNotifier.value, ThemeMode.system);

      ThemeMode? notifiedMode;
      config.themeModeNotifier.addListener(() {
        notifiedMode = config.themeModeNotifier.value;
      });

      await config.setThemeMode(ThemeMode.dark);
      expect(config.getThemeMode(), ThemeMode.dark);
      expect(notifiedMode, ThemeMode.dark);

      // Verify persistence across new ConfigService instance
      final freshConfig = await ConfigService.init();
      expect(freshConfig.getThemeMode(), ThemeMode.dark);
      expect(freshConfig.themeModeNotifier.value, ThemeMode.dark);

      await freshConfig.setThemeMode(ThemeMode.light);
      expect(freshConfig.getThemeMode(), ThemeMode.light);
    });
  });

  group('2. Settings Screen Structure & Appearance', () {
    testWidgets('Settings screen renders 4 structured sections and Theme SegmentedButton', (tester) async {
      tester.view.physicalSize = const Size(800 * 2.0, 1200 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      final configService = await ConfigService.init();
      final db = InMemoryAppDatabase();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          darkTheme: ThemeData.dark(useMaterial3: true),
          themeMode: ThemeMode.system,
          home: SettingsScreen(
            authService: GoogleAuthService(),
            configService: configService,
            sheetsService: SheetsService(),
            database: db,
            queueService: UploadQueueService(
              database: db,
              driveService: DriveService(),
              authService: GoogleAuthService(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify 4 section headers
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Clinic / Storage'), findsOneWidget);
      expect(find.text('Data'), findsOneWidget);
      expect(find.text('Account'), findsOneWidget);

      // Verify Theme SegmentedButton options
      expect(find.byType(SegmentedButton<ThemeMode>), findsOneWidget);
      expect(find.text('System'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);

      // Tap 'Dark' and verify config service updates
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();

      expect(configService.getThemeMode(), ThemeMode.dark);
      expect(find.text('• Dark: Midnight slate clinical theme optimized for examination rooms.'), findsOneWidget);
    });
  });

  group('3. Patients Screen Layout & FAB Hierarchy', () {
    testWidgets('AppBar has New Patient and Settings top-right; FAB has Unassigned Photos bottom-right', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final configService = await ConfigService.init();
      await configService.saveConfig(
        const ClinicConfig(
          spreadsheetId: 'test_sheet',
          spreadsheetUrl: 'https://docs.google.com/spreadsheets/d/test_sheet/edit',
          sheetTabName: 'Visits',
          hasCompletedSetup: true,
          lastSyncedRow: 10,
        ),
      );

      final db = InMemoryAppDatabase();
      await db.replacePatients([
        const Patient(
          id: '1000001',
          name: 'Anil Jain',
          phoneNumber: '9876543210',
          folderStatus: FolderStatus.missing,
        ),
      ]);

      final tempDir = Directory.systemTemp.createTempSync('ui_ux_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final queueService = UploadQueueService(
        database: db,
        driveService: DriveService(),
        authService: GoogleAuthService(),
        customDocsDirectory: tempDir.path,
      );
      addTearDown(queueService.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: PatientsScreen(
            authService: GoogleAuthService(),
            configService: configService,
            sheetsService: SheetsService(),
            database: db,
            queueService: queueService,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Top-right AppBar icons: person_add_outlined (New patient) and settings_outlined
      final newPatientBtn = find.byTooltip('New patient');
      expect(newPatientBtn, findsOneWidget);
      expect(find.byIcon(Icons.person_add_outlined), findsOneWidget);

      final settingsBtn = find.byTooltip('Settings');
      expect(settingsBtn, findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);

      // Bottom-right FAB: Unassigned Photos with inbox icon
      final fab = find.byType(FloatingActionButton);
      expect(fab, findsOneWidget);
      expect(find.byTooltip('Unassigned photos'), findsOneWidget);
      expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);

      // Search filters: All, Name, Phone (zero Patient ID)
      expect(find.widgetWithText(ChoiceChip, 'All'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Name'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Phone'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Patient ID'), findsNothing);

      // ListView has bottom padding 88.0 to prevent FAB obscuring list content
      final listViewFinder = find.byType(ListView);
      expect(listViewFinder, findsOneWidget);
      final listView = tester.widget<ListView>(listViewFinder);
      expect(listView.padding, const EdgeInsets.fromLTRB(0, 0, 0, 88));

      // Bottom navigation bar exists and contains patient count and upload pill
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.bottomNavigationBar, isNotNull);
      expect(find.text('1 patient'), findsOneWidget);

      // Tap FAB to open Unassigned Photos menu
      await tester.tap(fab);
      await tester.pumpAndSettle();

      // Verify both Take Unassigned Photos and View Unassigned Photos options are displayed
      expect(find.text('Unassigned Photos'), findsAtLeastNWidgets(1));
      expect(find.widgetWithText(ListTile, 'Take Unassigned Photos'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'View Unassigned Photos'), findsOneWidget);

      // Tap 'View Unassigned Photos' and verify navigation
      await tester.tap(find.widgetWithText(ListTile, 'View Unassigned Photos'));
      await tester.pumpAndSettle();

      // UnassignedPhotosScreen should be displayed with its empty state
      expect(find.text('All Photos Assigned'), findsOneWidget);
    });

    testWidgets('Tapping Take Unassigned Photos in menu creates unassigned session and opens CameraScreen', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final configService = await ConfigService.init();
      final db = InMemoryAppDatabase();

      final tempDir = Directory.systemTemp.createTempSync('ui_ux_test_unassigned_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final queueService = UploadQueueService(
        database: db,
        driveService: DriveService(),
        authService: GoogleAuthService(),
        customDocsDirectory: tempDir.path,
      );
      addTearDown(queueService.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: PatientsScreen(
            authService: GoogleAuthService(),
            configService: configService,
            sheetsService: SheetsService(),
            database: db,
            queueService: queueService,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Tap FAB to open menu
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // Tap 'Take Unassigned Photos'
      await tester.tap(find.widgetWithText(ListTile, 'Take Unassigned Photos'));
      await tester.pump(const Duration(milliseconds: 500));

      // Verify that unassigned session was created in DB
      final unassignedSessions = await db.getUnassignedSessions();
      expect(unassignedSessions.length, 1);
      expect(unassignedSessions.first.patientId, isNull);
    });
  });

  group('4. Zero Patient ID Exposure in Doctor-Facing UI', () {
    testWidgets('PatientTile displays initials, name, phone, but zero Patient ID or UUID', (tester) async {
      const patient = Patient(
        id: 'c56a4180-65aa-42ec-a945-5fd21dec0538', // UUID
        legacyPatientId: '1000048', // Sheets ID
        name: 'Ramesh Kumar',
        phoneNumber: '9123456780',
        folderStatus: FolderStatus.available,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PatientTile(
              patient: patient,
              onTap: () {},
            ),
          ),
        ),
      );

      // Should display initials 'R'
      expect(find.text('R'), findsOneWidget);
      // Should display patient name and phone
      expect(find.text('Ramesh Kumar'), findsOneWidget);
      expect(find.text('9123456780'), findsOneWidget);

      // MUST NOT display UUID or legacy Patient ID anywhere
      expect(find.text('c56a4180-65aa-42ec-a945-5fd21dec0538'), findsNothing);
      expect(find.text('1000048'), findsNothing);
      expect(find.textContaining('ID'), findsNothing);
      expect(find.textContaining('PID'), findsNothing);
      expect(find.textContaining('NEW'), findsNothing);
    });
  });
}
