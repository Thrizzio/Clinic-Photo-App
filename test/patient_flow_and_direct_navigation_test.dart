import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/screens/patient_photos_screen.dart';
import 'package:clinic_photos/screens/patients_screen.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:clinic_photos/widgets/new_patient_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('A. Create Patient Flow', () {
    late InMemoryAppDatabase db;
    late ConfigService configService;
    late UploadQueueService queueService;
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      configService = await ConfigService.init();
      db = InMemoryAppDatabase();
      tempDir = Directory.systemTemp.createTempSync('create_patient_flow_test_');
      queueService = UploadQueueService(
        database: db,
        driveService: DriveService(),
        authService: GoogleAuthService(),
        customDocsDirectory: tempDir.path,
      );

      const existingPatient = Patient(
        id: 'patient-rahul',
        name: 'Rahul Sharma',
        displayName: 'Rahul Sharma',
        phoneNumber: '9422301214',
        driveFolderId: 'folder-rahul',
        folderStatus: FolderStatus.available,
      );
      await db.upsertPatients([existingPatient]);
    });

    tearDown(() {
      queueService.dispose();
      tempDir.deleteSync(recursive: true);
    });

    testWidgets('1. Empty search: Create New Patient is not shown', (tester) async {
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

      // Normal patient list is shown
      expect(find.text('Rahul Sharma'), findsOneWidget);

      // Create New Patient is NOT shown
      expect(find.text('Create New Patient'), findsNothing);
      expect(find.byIcon(Icons.person_add_outlined), findsNothing);
      expect(find.byTooltip('New patient'), findsNothing);
    });

    testWidgets('2. Search for a name with no matching patient: Create New Patient is shown', (tester) async {
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

      // Search for an unlisted name
      await tester.enterText(find.byType(TextField), 'John');
      await tester.pumpAndSettle();

      expect(find.text('Rahul Sharma'), findsNothing);
      expect(find.text('No patients match "John"'), findsOneWidget);
      expect(find.text('Create New Patient'), findsOneWidget);
    });

    testWidgets('3. Tap Create New Patient after searching: form opens with Name pre-filled as "John"', (tester) async {
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

      await tester.enterText(find.byType(TextField), 'John');
      await tester.pumpAndSettle();

      // Tap Create New Patient
      await tester.tap(find.text('Create New Patient'));
      await tester.pumpAndSettle();

      // NewPatientDialog is visible
      expect(find.byType(NewPatientDialog), findsOneWidget);

      // Name field is pre-filled with "John"
      final nameField = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Patient Name *'),
      );
      expect(nameField.controller?.text, 'John');

      // Phone field is empty
      final phoneField = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Phone Number *'),
      );
      expect(phoneField.controller?.text, '');
    });

    testWidgets('4. Search for a phone number with no matching patient: form opens with Phone pre-filled as "9876543210"', (tester) async {
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

      await tester.enterText(find.byType(TextField), '9876543210');
      await tester.pumpAndSettle();

      expect(find.text('Create New Patient'), findsOneWidget);

      // Tap Create New Patient
      await tester.tap(find.text('Create New Patient'));
      await tester.pumpAndSettle();

      expect(find.byType(NewPatientDialog), findsOneWidget);

      // Phone field is pre-filled with "9876543210"
      final phoneField = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Phone Number *'),
      );
      expect(phoneField.controller?.text, '9876543210');

      // Name field is empty
      final nameField = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Patient Name *'),
      );
      expect(nameField.controller?.text, '');
    });

    testWidgets('5. Search matching an existing patient: do not show a misleading create-new-patient action', (tester) async {
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

      // Search for "Rahul" (which matches existing patient)
      await tester.enterText(find.byType(TextField), 'Rahul');
      await tester.pumpAndSettle();

      // Existing patient is found
      expect(find.text('Rahul Sharma'), findsOneWidget);

      // Misleading create action is NOT shown
      expect(find.text('Create New Patient'), findsNothing);
    });
  });

  group('B. Patient Navigation Directly to Patient View', () {
    late InMemoryAppDatabase db;
    late ConfigService configService;
    late UploadQueueService queueService;
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      configService = await ConfigService.init();
      db = InMemoryAppDatabase();
      tempDir = Directory.systemTemp.createTempSync('direct_nav_test_');
      queueService = UploadQueueService(
        database: db,
        driveService: DriveService(),
        authService: GoogleAuthService(),
        customDocsDirectory: tempDir.path,
      );

      const patient = Patient(
        id: 'patient-rahul',
        name: 'Rahul Sharma',
        displayName: 'Rahul Sharma',
        phoneNumber: '9422301214',
        driveFolderId: 'folder-rahul',
        folderStatus: FolderStatus.available,
      );
      await db.upsertPatients([patient]);
    });

    tearDown(() {
      queueService.dispose();
      tempDir.deleteSync(recursive: true);
    });

    testWidgets('6. Tap a patient entry directly opens Patient View without intermediate popup', (tester) async {
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

      // Tap the patient row directly
      await tester.tap(find.text('Rahul Sharma'));
      await tester.pumpAndSettle();

      // 6. Directly opens Patient View (PatientPhotosScreen)
      expect(find.byType(PatientPhotosScreen), findsOneWidget);

      // 7. No bottom sheet / dialog / intermediate popup was shown
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('8. Patient View still contains all existing patient actions', (tester) async {
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

      // Tap patient entry to navigate directly to Patient View
      await tester.tap(find.text('Rahul Sharma'));
      await tester.pumpAndSettle();

      expect(find.byType(PatientPhotosScreen), findsOneWidget);

      // 8.1 Take Photos action exists (both FloatingActionButton and AppBar icon)
      expect(find.widgetWithText(FloatingActionButton, 'Take Photos'), findsOneWidget);
      expect(find.byTooltip('Take Photos'), findsOneWidget);

      // 8.2 Refresh action exists
      expect(find.byTooltip('Refresh'), findsOneWidget);

      // 8.3 More options menu with Delete Patient exists
      expect(find.byTooltip('More options'), findsOneWidget);
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();

      expect(find.text('Delete Patient'), findsOneWidget);
    });
  });
}
