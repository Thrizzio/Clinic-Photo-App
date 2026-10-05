import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/screens/camera_screen.dart';
import 'package:clinic_photos/screens/patients_screen.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:clinic_photos/widgets/patient_tile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1. Folder UI Corrections', () {
    testWidgets('PatientTile: drive_folder_id exists -> NO "Folder ready", NO auto-create indicator', (tester) async {
      const patientWithFolder = Patient(
        id: 'patient-1',
        name: 'Rahul Sharma',
        displayName: 'Rahul Sharma',
        phoneNumber: '9876543210',
        driveFolderId: 'existing_drive_folder_123',
        folderStatus: FolderStatus.available,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PatientTile(
              patient: patientWithFolder,
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.text('Folder ready'), findsNothing);
      expect(find.text('Folder auto-creates on photo capture'), findsNothing);
    });

    testWidgets('PatientTile: drive_folder_id missing -> shows blue auto-create indicator, NO "Folder ready"', (tester) async {
      const patientWithoutFolder = Patient(
        id: 'patient-2',
        name: 'Anil Jain',
        displayName: 'Anil Jain',
        phoneNumber: '9876543211',
        driveFolderId: null,
        folderStatus: FolderStatus.available,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PatientTile(
              patient: patientWithoutFolder,
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.text('Folder ready'), findsNothing);
      expect(find.text('Folder auto-creates on photo capture'), findsOneWidget);
    });

    testWidgets('CameraScreen: drive_folder_id exists -> NO "Folder ready", NO auto-create indicator', (tester) async {
      final db = InMemoryAppDatabase();
      final tempDir = Directory.systemTemp.createTempSync('cam_test_folder_exists_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final queueService = UploadQueueService(
        database: db,
        driveService: DriveService(),
        authService: GoogleAuthService(),
        customDocsDirectory: tempDir.path,
      );
      addTearDown(queueService.dispose);

      const patientWithFolder = Patient(
        id: 'patient-1',
        name: 'Rahul Sharma',
        displayName: 'Rahul Sharma',
        phoneNumber: '9876543210',
        driveFolderId: 'existing_folder_999',
        folderStatus: FolderStatus.available,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            patient: patientWithFolder,
            queueService: queueService,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Folder ready'), findsNothing);
      expect(find.text('Folder auto-creates on photo capture'), findsNothing);
    });

    testWidgets('CameraScreen: drive_folder_id missing -> shows blue auto-create indicator, NO "Folder ready"', (tester) async {
      final db = InMemoryAppDatabase();
      final tempDir = Directory.systemTemp.createTempSync('cam_test_folder_missing_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final queueService = UploadQueueService(
        database: db,
        driveService: DriveService(),
        authService: GoogleAuthService(),
        customDocsDirectory: tempDir.path,
      );
      addTearDown(queueService.dispose);

      const patientWithoutFolder = Patient(
        id: 'patient-2',
        name: 'Anil Jain',
        displayName: 'Anil Jain',
        phoneNumber: '9876543211',
        driveFolderId: null,
        folderStatus: FolderStatus.available,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            patient: patientWithoutFolder,
            queueService: queueService,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Folder ready'), findsNothing);
      expect(find.text('Folder auto-creates on photo capture'), findsOneWidget);
    });
  });

  group('2. Camera Done Single Session Navigation', () {
    testWidgets('Pressing Done pops CameraScreen and returns directly to PatientsScreen with no second camera', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final configService = await ConfigService.init();
      final db = InMemoryAppDatabase();

      final tempDir = Directory.systemTemp.createTempSync('cam_done_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final queueService = UploadQueueService(
        database: db,
        driveService: DriveService(),
        authService: GoogleAuthService(),
        customDocsDirectory: tempDir.path,
      );
      addTearDown(queueService.dispose);

      const patient = Patient(
        id: 'p-1',
        name: 'John Doe',
        displayName: 'John Doe',
        phoneNumber: '9998887776',
        driveFolderId: 'folder-p1',
        folderStatus: FolderStatus.available,
      );
      await db.upsertPatients([patient]);

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

      // Tap Take Photos on the patient
      await tester.tap(find.byIcon(Icons.camera_alt_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // CameraScreen is visible
      expect(find.byType(CameraScreen), findsOneWidget);

      // Tap Done once
      await tester.tap(find.widgetWithText(TextButton, 'Done'));
      await tester.pumpAndSettle();

      // Returned directly to PatientsScreen
      expect(find.byType(CameraScreen), findsNothing);
      expect(find.byType(PatientsScreen), findsOneWidget);
      expect(find.text('John Doe'), findsOneWidget);
    });

    testWidgets('Rapid taps on camera button do not open a second CameraScreen', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final configService = await ConfigService.init();
      final db = InMemoryAppDatabase();

      final tempDir = Directory.systemTemp.createTempSync('cam_double_tap_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final queueService = UploadQueueService(
        database: db,
        driveService: DriveService(),
        authService: GoogleAuthService(),
        customDocsDirectory: tempDir.path,
      );
      addTearDown(queueService.dispose);

      const patient = Patient(
        id: 'p-1',
        name: 'John Doe',
        displayName: 'John Doe',
        phoneNumber: '9998887776',
        driveFolderId: 'folder-p1',
        folderStatus: FolderStatus.available,
      );
      await db.upsertPatients([patient]);

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

      // Simulate rapid double tap on the camera icon
      final cameraIcon = find.byIcon(Icons.camera_alt_outlined);
      await tester.tap(cameraIcon);
      await tester.tap(cameraIcon, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Exactly ONE CameraScreen should be in the tree
      expect(find.byType(CameraScreen), findsOneWidget);

      // Press Done once -> must return directly to PatientsScreen
      await tester.tap(find.widgetWithText(TextButton, 'Done'));
      await tester.pumpAndSettle();

      expect(find.byType(CameraScreen), findsNothing);
      expect(find.byType(PatientsScreen), findsOneWidget);
    });
  });

  group('3. Search Persistence across Camera Sessions', () {
    testWidgets('Search query "John" remains active and filtered after taking photos and pressing Done', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final configService = await ConfigService.init();
      final db = InMemoryAppDatabase();

      final tempDir = Directory.systemTemp.createTempSync('search_persist_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final queueService = UploadQueueService(
        database: db,
        driveService: DriveService(),
        authService: GoogleAuthService(),
        customDocsDirectory: tempDir.path,
      );
      addTearDown(queueService.dispose);

      const patientJohn = Patient(
        id: 'p-john',
        name: 'John Doe',
        displayName: 'John Doe',
        phoneNumber: '9876543210',
        driveFolderId: 'folder-john',
        folderStatus: FolderStatus.available,
      );
      const patientAlice = Patient(
        id: 'p-alice',
        name: 'Alice Smith',
        displayName: 'Alice Smith',
        phoneNumber: '9876543211',
        driveFolderId: 'folder-alice',
        folderStatus: FolderStatus.available,
      );

      await db.upsertPatients([patientJohn, patientAlice]);

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

      // Both patients visible initially
      expect(find.text('John Doe'), findsOneWidget);
      expect(find.text('Alice Smith'), findsOneWidget);

      // Search for "John"
      await tester.enterText(find.byType(TextField), 'John');
      await tester.pumpAndSettle();

      // Only John Doe is visible
      expect(find.text('John Doe'), findsOneWidget);
      expect(find.text('Alice Smith'), findsNothing);

      // Open camera for John Doe
      await tester.tap(find.byIcon(Icons.camera_alt_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(CameraScreen), findsOneWidget);

      // Tap Done
      await tester.tap(find.widgetWithText(TextButton, 'Done'));
      await tester.pumpAndSettle();

      // Returned to PatientsScreen:
      expect(find.byType(CameraScreen), findsNothing);
      expect(find.byType(PatientsScreen), findsOneWidget);

      // 1. Search field must still contain "John"
      final searchField = tester.widget<TextField>(find.byType(TextField));
      expect(searchField.controller?.text, 'John');

      // 2. John Doe remains filtered and visible
      expect(find.text('John Doe'), findsOneWidget);

      // 3. Alice Smith remains hidden
      expect(find.text('Alice Smith'), findsNothing);
    });

    testWidgets('Search query remains active even when patient initially missing folder acquires folder in camera session', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final configService = await ConfigService.init();
      final db = InMemoryAppDatabase();

      final tempDir = Directory.systemTemp.createTempSync('search_missing_folder_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final queueService = UploadQueueService(
        database: db,
        driveService: DriveService(),
        authService: GoogleAuthService(),
        customDocsDirectory: tempDir.path,
      );
      addTearDown(queueService.dispose);

      const patientJohnNoFolder = Patient(
        id: 'p-john-missing',
        name: 'John Doe',
        displayName: 'John Doe',
        phoneNumber: '9876543210',
        driveFolderId: null,
        folderStatus: FolderStatus.available,
      );
      const patientBob = Patient(
        id: 'p-bob',
        name: 'Bob Marley',
        displayName: 'Bob Marley',
        phoneNumber: '9876543212',
        driveFolderId: 'folder-bob',
        folderStatus: FolderStatus.available,
      );

      await db.upsertPatients([patientJohnNoFolder, patientBob]);

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

      // Search for "John"
      await tester.enterText(find.byType(TextField), 'John');
      await tester.pumpAndSettle();

      expect(find.text('John Doe'), findsOneWidget);
      expect(find.text('Bob Marley'), findsNothing);

      // Open camera
      await tester.tap(find.byIcon(Icons.camera_alt_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(CameraScreen), findsOneWidget);

      // Tap Done
      await tester.tap(find.widgetWithText(TextButton, 'Done'));
      await tester.pumpAndSettle();

      // Search query & results must be preserved
      final searchField = tester.widget<TextField>(find.byType(TextField));
      expect(searchField.controller?.text, 'John');
      expect(find.text('John Doe'), findsOneWidget);
      expect(find.text('Bob Marley'), findsNothing);
    });
  });
}
