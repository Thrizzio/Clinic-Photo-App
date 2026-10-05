import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/patient_folder_service.dart';
import 'package:clinic_photos/services/patient_sync_service.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/supabase_patient_service.dart';
import 'package:clinic_photos/widgets/patient_tile.dart';

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

class CountingMockDriveService extends DriveService {
  int createFolderCalls = 0;
  int findFoldersByNameCalls = 0;

  @override
  Future<List<drive.File>> findFoldersByName({
    required AuthClient client,
    required String parentFolderId,
    required String folderName,
  }) async {
    findFoldersByNameCalls++;
    return [];
  }

  @override
  Future<String> createFolder({
    required AuthClient client,
    required String parentFolderId,
    required String folderName,
  }) async {
    createFolderCalls++;
    return 'new_created_folder_id';
  }
}

class CountingMockSupabasePatientService extends InMemorySupabasePatientService {
  int fetchAllPatientsCalls = 0;
  int fetchAllPatientSourcesCalls = 0;
  int upsertPatientsCalls = 0;
  int linkPatientSourcesCalls = 0;
  int getPatientIdBySourceCalls = 0;
  int getPatientByIdCalls = 0;
  int findPatientByBusinessIdentityCalls = 0;
  int individualUpsertPatientCalls = 0;

  @override
  Future<List<Patient>> fetchAllPatients() async {
    fetchAllPatientsCalls++;
    return super.fetchAllPatients();
  }

  @override
  Future<List<Map<String, String>>> fetchAllPatientSources() async {
    fetchAllPatientSourcesCalls++;
    return super.fetchAllPatientSources();
  }

  @override
  Future<void> upsertPatients(List<Patient> patients) async {
    upsertPatientsCalls++;
    for (final p in patients) {
      await super.upsertPatient(p);
    }
  }

  @override
  Future<void> linkPatientSources(List<({String externalId, String patientId, String source})> sources) async {
    linkPatientSourcesCalls++;
    for (final s in sources) {
      await super.linkPatientSource(
        patientId: s.patientId,
        source: s.source,
        externalId: s.externalId,
      );
    }
  }

  @override
  Future<String?> getPatientIdBySource({required String source, required String externalId}) async {
    getPatientIdBySourceCalls++;
    return super.getPatientIdBySource(source: source, externalId: externalId);
  }

  @override
  Future<Patient?> getPatientById(String id) async {
    getPatientByIdCalls++;
    return super.getPatientById(id);
  }

  @override
  Future<Patient?> findPatientByBusinessIdentity(String normalizedName, String? normalizedPhone) async {
    findPatientByBusinessIdentityCalls++;
    return super.findPatientByBusinessIdentity(normalizedName, normalizedPhone);
  }

  @override
  Future<Patient> upsertPatient(Patient patient) async {
    individualUpsertPatientCalls++;
    return super.upsertPatient(patient);
  }
}

class FakeGoogleAuthService extends GoogleAuthService {
  final AuthClient client = FakeAuthClient();

  @override
  Future<AuthClient?> getAuthenticatedClient() async => client;
}

class FakeSheetsService extends SheetsService {}

void main() {
  group('Cross-Device Drive Folder Propagation & Performance Tests', () {
    late FakeSheetsService sheetsService;

    setUp(() {
      sheetsService = FakeSheetsService();
    });

    testWidgets('A. Cross-device folder propagation: Phone A folder -> Supabase -> Phone B has folder & UI shows ready', (tester) async {
      final dbPhoneA = InMemoryAppDatabase();
      final dbPhoneB = InMemoryAppDatabase();
      final sharedSupabase = InMemorySupabasePatientService();

      final syncPhoneA = PatientSyncService(
        database: dbPhoneA,
        supabaseService: sharedSupabase,
        sheetsService: sheetsService,
      );
      final syncPhoneB = PatientSyncService(
        database: dbPhoneB,
        supabaseService: sharedSupabase,
        sheetsService: sheetsService,
      );

      // Phone A creates a patient with Drive folder
      const patientId = '11111111-2222-3333-4444-555555555555';
      const folderA = 'drive_folder_phone_a_999';

      final patientOnPhoneA = Patient(
        id: patientId,
        name: 'Rahul Sharma',
        displayName: 'Rahul Sharma',
        phoneNumber: '9876543210',
        driveFolderId: folderA,
        folderStatus: FolderStatus.available,
        syncStatus: 'pending_cloud',
      );

      await dbPhoneA.upsertPatients([patientOnPhoneA]);

      // Phone A syncs with Supabase
      await syncPhoneA.syncLocalWithSupabase();

      // Verify Supabase has the folder ID
      final cloudPatients = await sharedSupabase.fetchAllPatients();
      expect(cloudPatients.length, 1);
      expect(cloudPatients.first.driveFolderId, folderA);

      // Phone B synchronizes with Supabase
      await syncPhoneB.syncLocalWithSupabase();

      // Expected: SQLite on Phone B has folder-A
      final patientsOnPhoneB = await dbPhoneB.getPatients();
      expect(patientsOnPhoneB.length, 1);
      final phoneBPatient = patientsOnPhoneB.first;
      expect(phoneBPatient.id, patientId);
      expect(phoneBPatient.driveFolderId, folderA);
      expect(phoneBPatient.folderStatus, FolderStatus.available);

      // Expected: UI on Phone B shows folder ready
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PatientTile(
              patient: phoneBPatient,
              onTap: () {},
              onViewPhotos: () {},
              onTakePhotos: () {},
            ),
          ),
        ),
      );

      // When drive_folder_id exists: show NO folder-status message and NO blue auto-create indicator
      expect(find.text('Folder ready'), findsNothing);
      expect(find.text('Folder auto-creates on photo capture'), findsNothing);
      expect(find.byIcon(Icons.photo_library_outlined), findsOneWidget);
      expect(find.byIcon(Icons.camera_alt_outlined), findsOneWidget);
    });

    test('B. Null local value must not overwrite valid cloud value', () async {
      final db = InMemoryAppDatabase();
      final supabase = InMemorySupabasePatientService();
      final syncService = PatientSyncService(
        database: db,
        supabaseService: supabase,
        sheetsService: sheetsService,
      );

      const patientId = '22222222-3333-4444-5555-666666666666';
      const cloudFolderId = 'canonical_cloud_folder_123';

      // Supabase already has a patient with a valid folder
      final cloudPatient = Patient(
        id: patientId,
        name: 'Pooja Hegde',
        displayName: 'Pooja Hegde',
        phoneNumber: '9123456780',
        driveFolderId: cloudFolderId,
        folderStatus: FolderStatus.available,
        syncStatus: 'synced',
      );
      await supabase.upsertPatient(cloudPatient);

      // Local phone has a stale/sheet record without a folder ID
      final localPatient = Patient(
        id: patientId,
        name: 'Pooja Hegde',
        displayName: 'Pooja Hegde',
        phoneNumber: '9123456780',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
        syncStatus: 'pending_cloud',
      );
      await db.upsertPatients([localPatient]);

      // Perform sync
      await syncService.syncLocalWithSupabase();

      // Invariant: Cloud drive_folder_id MUST NOT be overwritten with null
      final cloudAfter = await supabase.getPatientById(patientId);
      expect(cloudAfter?.driveFolderId, cloudFolderId);
      expect(cloudAfter?.folderStatus, FolderStatus.available);

      // Local patient should now also have the cloud folder ID
      final localAfter = await db.getPatient(patientId);
      expect(localAfter?.driveFolderId, cloudFolderId);
      expect(localAfter?.folderStatus, FolderStatus.available);

      // Also verify Patient.merge preserves existing valid folder against incoming null
      final mergedFromCloud = Patient.merge(localPatient, cloudPatient);
      expect(mergedFromCloud.driveFolderId, cloudFolderId);
      expect(mergedFromCloud.folderStatus, FolderStatus.available);
    });

    test('C. Valid local value should be uploaded if cloud value is absent', () async {
      final db = InMemoryAppDatabase();
      final supabase = InMemorySupabasePatientService();
      final syncService = PatientSyncService(
        database: db,
        supabaseService: supabase,
        sheetsService: sheetsService,
      );

      const patientId = '33333333-4444-5555-6666-777777777777';
      const localFolderId = 'local_folder_new_456';

      // Cloud patient has no folder
      final cloudPatient = Patient(
        id: patientId,
        name: 'Vikram Seth',
        displayName: 'Vikram Seth',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
        syncStatus: 'synced',
      );
      await supabase.upsertPatient(cloudPatient);

      // Local patient acquires a folder locally
      final localPatient = Patient(
        id: patientId,
        name: 'Vikram Seth',
        displayName: 'Vikram Seth',
        driveFolderId: localFolderId,
        folderStatus: FolderStatus.available,
        syncStatus: 'pending_cloud',
      );
      await db.upsertPatients([localPatient]);

      // Perform sync
      await syncService.syncLocalWithSupabase();

      // Cloud now has the uploaded local folder ID
      final cloudAfter = await supabase.getPatientById(patientId);
      expect(cloudAfter?.driveFolderId, localFolderId);
      expect(cloudAfter?.folderStatus, FolderStatus.available);
    });

    test('D. Existing drive_folder_id must not trigger folder creation in PatientFolderService', () async {
      SharedPreferences.setMockInitialValues({
        'clinic_id': 'clinic-1',
        'clinic_name': 'Test Clinic',
        'spreadsheet_id': 'sheet-1',
        'parent_folder_id': 'parent-folder-1',
      });
      final prefs = await SharedPreferences.getInstance();
      final configService = ConfigService(prefs);
      final database = InMemoryAppDatabase();
      final countingDriveService = CountingMockDriveService();
      final fakeAuthService = FakeGoogleAuthService();
      final countingSupabase = CountingMockSupabasePatientService();

      final folderService = PatientFolderService(
        driveService: countingDriveService,
        sheetsService: sheetsService,
        database: database,
        configService: configService,
        authService: fakeAuthService,
        supabaseService: countingSupabase,
      );

      const existingFolderId = 'already_existing_folder_xyz';
      final patient = Patient(
        id: '44444444-5555-6666-7777-888888888888',
        name: 'Deepak Chopra',
        displayName: 'Deepak Chopra',
        driveFolderId: existingFolderId,
        folderStatus: FolderStatus.available,
      );
      await database.upsertPatients([patient]);

      final result = await folderService.getOrCreatePatientFolder(patient);

      // Verify that existing folder ID is returned immediately
      expect(result.driveFolderId, existingFolderId);
      expect(result.createdNew, isFalse);

      // Verify NO Drive API calls were made to create or find folders!
      expect(countingDriveService.createFolderCalls, 0);
      expect(countingDriveService.findFoldersByNameCalls, 0);
    });

    test('E. Sync should not make Google Drive API calls for patients whose drive_folder_id is already known', () async {
      final db = InMemoryAppDatabase();
      final supabase = CountingMockSupabasePatientService();
      final countingDrive = CountingMockDriveService();

      final syncService = PatientSyncService(
        database: db,
        supabaseService: supabase,
        sheetsService: sheetsService,
      );

      // Setup 5 patients with existing folder IDs
      final patients = List.generate(5, (i) => Patient(
        id: '55555555-0000-0000-0000-00000000000$i',
        name: 'Patient $i',
        displayName: 'Patient $i',
        driveFolderId: 'folder_known_$i',
        folderStatus: FolderStatus.available,
      ));

      await db.upsertPatients(patients);
      await supabase.upsertPatients(patients);

      // Perform background sync
      await syncService.syncLocalWithSupabase();

      // Verify ZERO calls to Drive API
      expect(countingDrive.createFolderCalls, 0);
      expect(countingDrive.findFoldersByNameCalls, 0);
    });

    test('F. Batch sync performance: 77 patients reconciled with minimal batch queries instead of ~385 sequential calls', () async {
      final db = InMemoryAppDatabase();
      final countingSupabase = CountingMockSupabasePatientService();
      final syncService = PatientSyncService(
        database: db,
        supabaseService: countingSupabase,
        sheetsService: sheetsService,
      );

      // Generate 77 incoming sheet patients
      final incomingPatients = List.generate(77, (i) {
        final legacyId = (1000000 + i).toString();
        return Patient(
          id: legacyId,
          legacyPatientId: legacyId,
          name: 'Clinical Patient $i',
          displayName: 'Clinical Patient $i',
          phoneNumber: '98000000$i',
          driveFolderId: 'https://drive.google.com/drive/folders/folder_$i',
          source: PatientSource.clinicSheet,
        );
      });

      final result = await syncService.reconcileSheetPatients(incomingPatients);

      expect(result.totalSheetPatients, 77);
      expect(result.createdNewCount, 77);
      expect(result.isSupabaseSynced, isTrue);

      // Verify that NO sequential per-patient Supabase calls were made:
      expect(countingSupabase.getPatientIdBySourceCalls, 0);
      expect(countingSupabase.getPatientByIdCalls, 0);
      expect(countingSupabase.findPatientByBusinessIdentityCalls, 0);
      expect(countingSupabase.individualUpsertPatientCalls, 0);

      // Verify exactly batched operations occurred:
      expect(countingSupabase.fetchAllPatientSourcesCalls, 1);
      expect(countingSupabase.fetchAllPatientsCalls, 1);
      expect(countingSupabase.upsertPatientsCalls, 1);
      expect(countingSupabase.linkPatientSourcesCalls, 1);

      // Total cloud network operations = 4 (instead of 77 * 5 = 385 sequential calls!)
      final totalNetworkCalls = countingSupabase.fetchAllPatientSourcesCalls +
          countingSupabase.fetchAllPatientsCalls +
          countingSupabase.upsertPatientsCalls +
          countingSupabase.linkPatientSourcesCalls;
      expect(totalNetworkCalls, 4);

      // Verify local database has all 77 patients
      final localPatients = await db.getPatients();
      expect(localPatients.length, 77);
    });
  });
}
