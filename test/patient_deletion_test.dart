import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/supabase_patient_service.dart';
import 'package:clinic_photos/services/patient_sync_service.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:clinic_photos/screens/patients_screen.dart';

class FakeSheetsService extends SheetsService {}

class TrackingDriveService extends DriveService {
  int deleteCallsCount = 0;
  final List<String> deletedFileIds = [];

  @override
  Future<void> deleteFile({
    required dynamic client,
    required String fileId,
  }) async {
    deleteCallsCount++;
    deletedFileIds.add(fileId);
  }
}

class FailingSupabasePatientService extends InMemorySupabasePatientService {
  bool shouldFailDelete = false;

  @override
  Future<void> deletePatient(String patientId) async {
    if (shouldFailDelete) {
      throw Exception('Network error: Supabase unreachable');
    }
    await super.deletePatient(patientId);
  }
}

void main() {
  late InMemoryAppDatabase database;
  late FailingSupabasePatientService supabaseService;
  late FakeSheetsService sheetsService;
  late TrackingDriveService driveService;
  late PatientSyncService syncService;

  setUp(() {
    database = InMemoryAppDatabase();
    supabaseService = FailingSupabasePatientService();
    sheetsService = FakeSheetsService();
    driveService = TrackingDriveService();
    syncService = PatientSyncService(
      database: database,
      supabaseService: supabaseService,
      sheetsService: sheetsService,
    );
  });

  group('Patient Deletion Tests', () {
    // -------------------------------------------------------------
    // Test A: Local deletion removes patient from SQLite
    // -------------------------------------------------------------
    test('A. Local deletion removes patient and associated records from SQLite', () async {
      const patientId = '11111111-1111-4111-8111-111111111111';
      final patient = Patient(
        id: patientId,
        name: 'John Doe',
        displayName: 'John Doe',
        phoneNumber: '9876543210',
        driveFolderId: 'folder_drive_123',
        source: PatientSource.doctorCreated,
        syncStatus: 'synced',
      );

      await database.upsertPatients([patient]);
      await database.linkPatientSource(
        patientId: patientId,
        source: 'clinic_sheet',
        externalId: 'P100',
      );

      expect(await database.getPatient(patientId), isNotNull);
      final sourcesBefore = await database.getSourcesForPatient(patientId);
      expect(sourcesBefore.length, 1);

      // Perform deletion
      final result = await syncService.deletePatient(patientId);
      expect(result.localSuccess, isTrue);

      // Local assertions:
      expect(await database.getPatient(patientId), isNull);
      final allPatients = await database.getPatients();
      expect(allPatients.any((p) => p.id == patientId), isFalse);

      final sourcesAfter = await database.getSourcesForPatient(patientId);
      expect(sourcesAfter, isEmpty);
    });

    // -------------------------------------------------------------
    // Test B: Cloud deletion removes patient & patient_sources from Supabase
    // -------------------------------------------------------------
    test('B. Cloud deletion removes patient and source mappings from Supabase', () async {
      const patientId = '22222222-2222-4222-8222-222222222222';
      final patient = Patient(
        id: patientId,
        name: 'Alice Smith',
        displayName: 'Alice Smith',
        phoneNumber: '9123456789',
        driveFolderId: 'folder_drive_456',
        source: PatientSource.clinicSheet,
        syncStatus: 'synced',
      );

      await database.upsertPatients([patient]);
      await supabaseService.upsertPatient(patient);
      await supabaseService.linkPatientSource(
        patientId: patientId,
        source: 'clinic_sheet',
        externalId: 'P101',
      );

      // Verify present in Supabase before deletion
      expect(await supabaseService.getPatientById(patientId), isNotNull);
      expect(await supabaseService.getPatientIdBySource(
        source: 'clinic_sheet',
        externalId: 'P101',
      ), isNotNull);

      // Delete
      final result = await syncService.deletePatient(patientId);
      expect(result.isFullyDeleted, isTrue);
      expect(result.cloudSuccess, isTrue);

      // Verify removed from Supabase
      expect(await supabaseService.getPatientById(patientId), isNull);
      expect(await supabaseService.getPatientIdBySource(
        source: 'clinic_sheet',
        externalId: 'P101',
      ), isNull);
    });

    // -------------------------------------------------------------
    // Test C: Drive safety - deletion NEVER invokes Drive deletion
    // -------------------------------------------------------------
    test('C. Drive safety: patient deletion NEVER invokes Google Drive deletion APIs', () async {
      const patientId = '33333333-3333-4333-8333-333333333333';
      const driveFolderId = 'folder_drive_keep_safe';
      final patient = Patient(
        id: patientId,
        name: 'Bob Jones',
        displayName: 'Bob Jones',
        driveFolderId: driveFolderId,
        folderStatus: FolderStatus.available,
        source: PatientSource.doctorCreated,
        syncStatus: 'synced',
      );

      await database.upsertPatients([patient]);
      await supabaseService.upsertPatient(patient);

      // Delete patient
      final result = await syncService.deletePatient(patientId);
      expect(result.isFullyDeleted, isTrue);

      // Drive assertions:
      expect(driveService.deleteCallsCount, 0);
      expect(driveService.deletedFileIds, isEmpty);
    });

    // -------------------------------------------------------------
    // Test D: Offline deletion queues pending deletion and retries later
    // -------------------------------------------------------------
    test('D. Offline deletion removes locally, queues pending_deletions, retries on sync', () async {
      const patientId = '44444444-4444-4444-8444-444444444444';
      final patient = Patient(
        id: patientId,
        name: 'Offline Patient',
        displayName: 'Offline Patient',
        source: PatientSource.doctorCreated,
        syncStatus: 'synced',
      );

      await database.upsertPatients([patient]);
      await supabaseService.upsertPatient(patient);

      // Simulate offline / Supabase failure
      supabaseService.shouldFailDelete = true;

      final result = await syncService.deletePatient(patientId);

      // Local deletion succeeded, cloud failed
      expect(result.localSuccess, isTrue);
      expect(result.cloudSuccess, isFalse);
      expect(result.isFullyDeleted, isFalse);

      // Patient is immediately gone locally
      expect(await database.getPatient(patientId), isNull);

      // Pending deletion is queued in SQLite
      final pendingDeletions = await database.getPendingDeletions();
      expect(pendingDeletions.length, 1);
      expect(pendingDeletions.first, patientId);

      // Patient still exists in Supabase since offline
      expect(await supabaseService.getPatientById(patientId), isNotNull);

      // Connectivity restored!
      supabaseService.shouldFailDelete = false;

      // Sync runs (e.g. background sync or manual refresh)
      await syncService.syncLocalWithSupabase();

      // Pending deletion should be processed and cleared
      final pendingAfter = await database.getPendingDeletions();
      expect(pendingAfter, isEmpty);

      // Supabase record is now deleted
      expect(await supabaseService.getPatientById(patientId), isNull);
    });

    // -------------------------------------------------------------
    // Test E: Cross-device deletion propagation
    // -------------------------------------------------------------
    test('E. Cross-device deletion: Device B removes stale local patient on sync without re-creation', () async {
      const patientId = '55555555-5555-4555-8555-555555555555';
      final patient = Patient(
        id: patientId,
        name: 'Shared Patient',
        displayName: 'Shared Patient',
        source: PatientSource.doctorCreated,
        syncStatus: 'synced', // marked synced because it previously came from/synced with cloud
      );

      const otherPatientId = '88888888-8888-4888-8888-888888888888';
      final otherPatient = Patient(
        id: otherPatientId,
        name: 'Active Patient',
        displayName: 'Active Patient',
        source: PatientSource.doctorCreated,
        syncStatus: 'synced',
      );

      // Device B has Patient X and Active Patient in local SQLite
      await database.upsertPatients([patient, otherPatient]);

      // Meanwhile, Device A deleted Patient X from Supabase:
      // So Supabase has Active Patient, but no longer has Patient X
      await supabaseService.upsertPatient(otherPatient);
      expect(await supabaseService.getPatientById(patientId), isNull);

      // Device B runs syncLocalWithSupabase()
      await syncService.syncLocalWithSupabase();

      // Assertions on Device B:
      // 1. Stale patient removed from Device B SQLite
      expect(await database.getPatient(patientId), isNull);
      final allPatientsDeviceB = await database.getPatients();
      expect(allPatientsDeviceB.any((p) => p.id == patientId), isFalse);
      expect(allPatientsDeviceB.any((p) => p.id == otherPatientId), isTrue);

      // 2. Patient was NOT re-created or pushed back to Supabase
      expect(await supabaseService.getPatientById(patientId), isNull);
      expect(await supabaseService.getPatientById(otherPatientId), isNotNull);
    });

    // -------------------------------------------------------------
    // Test F: Google Sheets resurrection prevention via tombstones
    // -------------------------------------------------------------
    test('F. Google Sheets reconciliation does NOT resurrect a deleted patient', () async {
      const patientId = '66666666-6666-4666-8666-666666666666';
      const externalSheetId = '1000099';
      final patient = Patient(
        id: patientId,
        legacyPatientId: externalSheetId,
        name: 'Sheet Patient',
        displayName: 'Sheet Patient',
        phoneNumber: '9988776655',
        source: PatientSource.clinicSheet,
        syncStatus: 'synced',
      );

      await database.upsertPatients([patient]);
      await database.linkPatientSource(
        patientId: patientId,
        source: 'google_sheets',
        externalId: externalSheetId,
      );
      await supabaseService.upsertPatient(patient);

      // Doctor deliberately deletes the patient
      final deleteResult = await syncService.deletePatient(patientId);
      expect(deleteResult.localSuccess, isTrue);

      // Verify tombstone is recorded
      expect(await database.isPatientDeleted(patientId), isTrue);
      expect(await database.isSourceDeleted(
        source: 'google_sheets',
        externalId: externalSheetId,
      ), isTrue);

      // Incoming Google Sheets sync dataset STILL contains this patient row!
      final sheetData = [
        Patient(
          id: externalSheetId,
          legacyPatientId: externalSheetId,
          name: 'Sheet Patient',
          displayName: 'Sheet Patient',
          phoneNumber: '9988776655',
          source: PatientSource.clinicSheet,
        ),
      ];

      // Reconcile Sheets
      final reconcileResult = await syncService.reconcileSheetPatients(sheetData);

      // Assertions:
      // Reconcile ignored the tombstoned patient
      expect(reconcileResult.createdNewCount, 0);
      expect(reconcileResult.linkedExistingCount, 0);
      expect(reconcileResult.reconciledPatients, isEmpty);

      // Patient was NOT resurrected locally
      expect(await database.getPatient(patientId), isNull);
      final allPatients = await database.getPatients();
      expect(allPatients.any((p) => p.id == patientId), isFalse);
      expect(allPatients.any((p) => p.legacyPatientId == externalSheetId), isFalse);

      // Patient was NOT resurrected in Supabase
      expect(await supabaseService.getPatientById(patientId), isNull);
    });

    // -------------------------------------------------------------
    // Test G: UI deletion flow & confirmation dialog
    // -------------------------------------------------------------
    testWidgets('G. UI deletion flow displays confirmation dialog and removes patient immediately', (tester) async {
      tester.view.physicalSize = const Size(800 * 2.0, 1200 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      final configService = await ConfigService.init();

      const patientId = '77777777-7777-4777-8777-777777777777';
      final patient = Patient(
        id: patientId,
        name: 'Delete Target',
        displayName: 'Delete Target',
        source: PatientSource.doctorCreated,
        syncStatus: 'synced',
      );
      await database.upsertPatients([patient]);
      await supabaseService.upsertPatient(patient);

      final tempDir = Directory.systemTemp.createTempSync('delete_ui_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final queueService = UploadQueueService(
        database: database,
        driveService: driveService,
        authService: GoogleAuthService(),
        customDocsDirectory: tempDir.path,
      );
      addTearDown(queueService.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: PatientsScreen(
            authService: GoogleAuthService(),
            configService: configService,
            sheetsService: sheetsService,
            database: database,
            queueService: queueService,
            supabaseService: supabaseService,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify patient is shown in list
      expect(find.text('Delete Target'), findsOneWidget);

      // Tap on the patient tile to open bottom sheet
      await tester.tap(find.text('Delete Target'));
      await tester.pumpAndSettle();

      // Find "Delete Patient" in bottom sheet
      final deleteTile = find.widgetWithText(ListTile, 'Delete Patient');
      expect(deleteTile, findsOneWidget);

      // Tap "Delete Patient"
      await tester.tap(deleteTile);
      await tester.pumpAndSettle();

      // Verify confirmation dialog text
      expect(find.text('Delete Patient?'), findsOneWidget);
      expect(
        find.text(
          'Delete this patient? The patient record will be removed from this app and other clinic devices. Their Google Drive photos will NOT be deleted.',
        ),
        findsOneWidget,
      );

      // 1. Test Cancel button: patient is NOT deleted
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Delete Target'), findsOneWidget);
      expect(await database.getPatient(patientId), isNotNull);
      expect(await supabaseService.getPatientById(patientId), isNotNull);

      // 2. Tap again and test Delete button
      await tester.tap(find.text('Delete Target'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ListTile, 'Delete Patient'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      // Verify patient disappears immediately from the UI
      expect(find.text('Delete Target'), findsNothing);

      // Verify deleted from SQLite and Supabase
      expect(await database.getPatient(patientId), isNull);
      expect(await supabaseService.getPatientById(patientId), isNull);
    });
  });
}
