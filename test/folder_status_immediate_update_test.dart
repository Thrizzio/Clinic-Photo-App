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
import 'package:clinic_photos/services/patient_folder_service.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/supabase_patient_service.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:clinic_photos/widgets/patient_tile.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;

class FakeAuthClient extends http.BaseClient implements AuthClient {
  @override
  AccessCredentials get credentials => AccessCredentials(
        AccessToken('Bearer', 'fake_token', DateTime.now().toUtc().add(const Duration(hours: 1))),
        'fake_refresh_token',
        ['https://www.googleapis.com/auth/drive'],
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}

class MockDriveService extends DriveService {
  final Map<String, List<drive.File>> parentFolders = {};
  int createFolderCalls = 0;
  String? createdFolderIdToReturn;

  @override
  Future<List<drive.File>> findFoldersByName({
    required AuthClient client,
    required String parentFolderId,
    required String folderName,
  }) async {
    final list = parentFolders[parentFolderId] ?? [];
    return list.where((f) => f.name == folderName).toList();
  }

  @override
  Future<String> createFolder({
    required AuthClient client,
    required String parentFolderId,
    required String folderName,
  }) async {
    createFolderCalls++;
    final folderId = createdFolderIdToReturn ?? 'new_folder_${createFolderCalls}_123';
    final newFile = drive.File()
      ..id = folderId
      ..name = folderName;
    parentFolders.putIfAbsent(parentFolderId, () => []).add(newFile);
    return folderId;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryAppDatabase db;
  late ConfigService configService;
  late UploadQueueService queueService;
  late PatientFolderService folderService;
  late InMemorySupabasePatientService mockSupabase;
  late MockDriveService mockDriveService;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'parentDriveFolderId': 'parent_folder_test_123',
    });
    configService = await ConfigService.init();
    db = InMemoryAppDatabase();
    tempDir = Directory.systemTemp.createTempSync('folder_status_test_');
    mockSupabase = InMemorySupabasePatientService();
    mockDriveService = MockDriveService();

    folderService = PatientFolderService(
      driveService: mockDriveService,
      sheetsService: SheetsService(),
      database: db,
      configService: configService,
      authService: GoogleAuthService(),
      supabaseService: mockSupabase,
    );

    queueService = UploadQueueService(
      database: db,
      driveService: mockDriveService,
      authService: GoogleAuthService(),
      patientFolderService: folderService,
      customDocsDirectory: tempDir.path,
    );
  });

  tearDown(() {
    queueService.dispose();
    tempDir.deleteSync(recursive: true);
  });

  group('A. Search UI: Filter Chips Cleanly Removed', () {
    testWidgets('No ALL/Name/Phone pill boxes (ChoiceChips) are rendered on PatientsScreen', (tester) async {
      const patient = Patient(
        id: 'patient-1',
        name: 'Aarav Patel',
        displayName: 'Aarav Patel',
        phoneNumber: '9876543210',
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

      // Verify no ChoiceChip widgets exist anywhere
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'All'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Name'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Phone'), findsNothing);

      // Search bar hint is clean
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.decoration?.hintText, 'Search patients by name or phone...');
    });

    testWidgets('Search works by both name and phone without requiring filter pills', (tester) async {
      const p1 = Patient(
        id: 'p1',
        name: 'Rohan Joshi',
        displayName: 'Rohan Joshi',
        phoneNumber: '9111122222',
      );
      const p2 = Patient(
        id: 'p2',
        name: 'Pooja Verma',
        displayName: 'Pooja Verma',
        phoneNumber: '9333344444',
      );
      await db.upsertPatients([p1, p2]);

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

      // Search by name
      await tester.enterText(find.byType(TextField), 'Rohan');
      await tester.pumpAndSettle();
      expect(find.text('Rohan Joshi'), findsOneWidget);
      expect(find.text('Pooja Verma'), findsNothing);

      // Search by phone
      await tester.enterText(find.byType(TextField), '93333');
      await tester.pumpAndSettle();
      expect(find.text('Pooja Verma'), findsOneWidget);
      expect(find.text('Rohan Joshi'), findsNothing);
    });
  });

  group('B. Folder UI State', () {
    testWidgets('Patient.drive_folder_id == null shows auto-create indicator and no Folder ready text', (tester) async {
      const patientWithoutFolder = Patient(
        id: 'p-no-folder',
        name: 'No Folder Patient',
        displayName: 'No Folder Patient',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );

      // 1. In PatientTile
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
      await tester.pumpAndSettle();
      expect(find.text('Folder auto-creates on photo capture'), findsOneWidget);
      expect(find.text('Folder ready'), findsNothing);

      // 2. In CameraScreen
      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            patient: patientWithoutFolder,
            queueService: queueService,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Folder auto-creates on photo capture'), findsOneWidget);
      expect(find.text('Folder ready'), findsNothing);
    });

    testWidgets('Patient.drive_folder_id is valid hides auto-create indicator and shows no Folder ready text', (tester) async {
      const patientWithFolder = Patient(
        id: 'p-with-folder',
        name: 'Ready Folder Patient',
        displayName: 'Ready Folder Patient',
        driveFolderId: 'drive_folder_abc_123',
        folderStatus: FolderStatus.available,
      );

      // 1. In PatientTile
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
      await tester.pumpAndSettle();
      expect(find.text('Folder auto-creates on photo capture'), findsNothing);
      expect(find.text('Folder ready'), findsNothing);

      // 2. In CameraScreen
      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            patient: patientWithFolder,
            queueService: queueService,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Folder auto-creates on photo capture'), findsNothing);
      expect(find.text('Folder ready'), findsNothing);
    });
  });

  group('C. Folder Creation UI Update (Immediate Local Rebuild)', () {
    testWidgets('CameraScreen automatically removes auto-create indicator immediately upon local folder creation', (tester) async {
      const initialPatient = Patient(
        id: 'p-camera-test',
        name: 'Camera Test Patient',
        displayName: 'Camera Test Patient',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );
      await db.upsertPatients([initialPatient]);

      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            patient: initialPatient,
            queueService: queueService,
          ),
        ),
      );
      await tester.pump();

      // Initially indicator is visible
      expect(find.text('Folder auto-creates on photo capture'), findsOneWidget);

      // Simulate successful Drive folder creation: SQLite is updated and queueService notified
      final updatedPatient = initialPatient.copyWith(
        driveFolderId: 'newly_created_folder_777',
        folderStatus: FolderStatus.available,
      );
      await db.updatePatient(updatedPatient);
      folderService.onFolderCreated?.call(updatedPatient);

      // Pump single frame
      await tester.pump();

      // Indicator disappears immediately without manual refresh or sync
      expect(find.text('Folder auto-creates on photo capture'), findsNothing);
      expect(find.text('Folder ready'), findsNothing);
    });

    testWidgets('PatientsScreen automatically updates tile indicator immediately upon local folder creation', (tester) async {
      const initialPatient = Patient(
        id: 'p-tile-test',
        name: 'Tile Test Patient',
        displayName: 'Tile Test Patient',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );
      await db.upsertPatients([initialPatient]);

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

      // Initially tile shows auto-creates indicator
      expect(find.text('Folder auto-creates on photo capture'), findsOneWidget);

      // Simulate successful Drive folder creation
      final updatedPatient = initialPatient.copyWith(
        driveFolderId: 'newly_created_folder_888',
        folderStatus: FolderStatus.available,
      );
      await db.updatePatient(updatedPatient);
      folderService.onFolderCreated?.call(updatedPatient);

      // Pump to process local notification and async database reload
      await tester.pumpAndSettle();

      // Indicator disappears immediately from tile without manual refresh or sync
      expect(find.text('Folder auto-creates on photo capture'), findsNothing);
    });
  });

  group('D. Folder Creation Failure', () {
    testWidgets('Indicator remains visible if folder creation fails or drive_folder_id is not set', (tester) async {
      const patient = Patient(
        id: 'p-fail-test',
        name: 'Failure Test Patient',
        displayName: 'Failure Test Patient',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );
      await db.upsertPatients([patient]);

      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            patient: patient,
            queueService: queueService,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Folder auto-creates on photo capture'), findsOneWidget);

      // Notify queueService without setting driveFolderId (e.g. upload error / offline)
      folderService.onFolderCreated?.call(patient);
      await tester.pump();

      // Indicator remains visible because drive_folder_id is still missing
      expect(find.text('Folder auto-creates on photo capture'), findsOneWidget);
    });
  });

  group('E. Cloud Persistence Remains Background / Asynchronous', () {
    test('getOrCreatePatientFolder updates SQLite and notifies onFolderCreated immediately, with Supabase push in background', () async {
      const patientId = '88888888-9999-4444-5555-666666666666';
      const patient = Patient(
        id: patientId,
        name: 'Async Cloud Patient',
        displayName: 'Async Cloud Patient',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );
      await db.upsertPatients([patient]);

      Patient? notifiedPatient;
      folderService.onFolderCreated = (p) {
        notifiedPatient = p;
      };

      final result = await folderService.getOrCreatePatientFolder(
        patient,
        clientOverride: FakeAuthClient(),
      );

      // Returns immediately with valid driveFolderId and available status
      expect(result.driveFolderId, isNotEmpty);
      expect(result.patient.folderStatus, FolderStatus.available);

      // Local SQLite is updated immediately
      final local = await db.getPatient(patientId);
      expect(local?.driveFolderId, result.driveFolderId);
      expect(local?.folderStatus, FolderStatus.available);

      // Listener was notified immediately
      expect(notifiedPatient?.driveFolderId, result.driveFolderId);

      // Wait a microtask tick for the unawaited background push to Supabase
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final cloudPatient = await mockSupabase.getPatientById(patientId);
      expect(cloudPatient?.driveFolderId, result.driveFolderId);
    });
  });
}
