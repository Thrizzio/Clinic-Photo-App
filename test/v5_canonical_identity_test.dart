import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/supabase_patient_service.dart';
import 'package:clinic_photos/services/patient_sync_service.dart';

class FakeSheetsService extends SheetsService {}

void main() {
  late InMemoryAppDatabase database;
  late InMemorySupabasePatientService supabaseService;
  late FakeSheetsService sheetsService;
  late PatientSyncService syncService;

  setUp(() {
    database = InMemoryAppDatabase();
    supabaseService = InMemorySupabasePatientService();
    sheetsService = FakeSheetsService();
    syncService = PatientSyncService(
      database: database,
      supabaseService: supabaseService,
      sheetsService: sheetsService,
    );
  });

  group('V5 Canonical Identity & Cross-Source Deduplication Tests', () {
    test('Day 1 doctor creation + Day 5 Sheets reconciliation links without duplicates', () async {
      // Day 1: Doctor creates a patient in-app with valid UUID
      const doctorPatientId = '11111111-1111-4111-8111-111111111111';
      final doctorPatient = Patient(
        id: doctorPatientId,
        name: 'Anil Jain',
        displayName: 'Anil Jain',
        phoneNumber: '+91 94223 01214',
        source: PatientSource.doctorCreated,
        driveFolderId: 'folder_anil_drive_123',
        folderStatus: FolderStatus.available,
        syncStatus: 'pending_cloud',
      );

      await database.upsertPatients([doctorPatient]);
      // Doctor-created patient is synced to Supabase
      await supabaseService.upsertPatient(doctorPatient);

      final initialPatients = await database.getPatients();
      expect(initialPatients.length, 1);
      expect(initialPatients.first.id, doctorPatientId);
      expect(initialPatients.first.source, PatientSource.doctorCreated);
      expect(initialPatients.first.legacyPatientId, isNull);

      // Day 5: Google Sheets sync occurs with a matching patient
      final incomingSheetPatient = Patient(
        id: '1000048', // Sheet external ID
        legacyPatientId: '1000048',
        name: 'Anil Jain',
        displayName: 'Anil Jain',
        phoneNumber: '9422301214',
        source: PatientSource.clinicSheet,
      );

      final result = await syncService.reconcileSheetPatients([incomingSheetPatient]);

      // Assertions:
      // 1. One patient was linked to existing
      expect(result.totalSheetPatients, 1);
      expect(result.linkedExistingCount, 1);
      expect(result.createdNewCount, 0);

      // 2. Exactly one patient exists in database (zero duplicates)
      final allPatients = await database.getPatients();
      expect(allPatients.length, 1);

      final reconciled = allPatients.first;
      // 3. Canonical UUID is strictly preserved
      expect(reconciled.id, doctorPatientId);
      // 4. Source transitioned to merged
      expect(reconciled.source, PatientSource.merged);
      // 5. Legacy Patient ID attached
      expect(reconciled.legacyPatientId, '1000048');
      // 6. Existing Drive folder preserved
      expect(reconciled.driveFolderId, 'folder_anil_drive_123');
      expect(reconciled.isUploadable, isTrue);

      // 7. Source mapping is established in both SQLite and Supabase
      final mappedIdLocal = await database.getPatientIdBySource(
        source: 'google_sheets',
        externalId: '1000048',
      );
      expect(mappedIdLocal, doctorPatientId);

      final mappedIdSupabase = await supabaseService.getPatientIdBySource(
        source: 'google_sheets',
        externalId: '1000048',
      );
      expect(mappedIdSupabase, doctorPatientId);
    });

    test('Absence of a patient from Google Sheets NEVER deletes or archives canonical patient', () async {
      // Setup 3 patients:
      // - 2 doctor-created patients
      // - 1 sheet-imported patient
      const docId1 = '22222222-2222-4222-8222-222222222222';
      const docId2 = '33333333-3333-4333-8333-333333333333';
      const sheetId1 = '44444444-4444-4444-8444-444444444444';

      final docPatient1 = Patient(
        id: docId1,
        name: 'Ramesh Pawar',
        phoneNumber: '9822011111',
        source: PatientSource.doctorCreated,
      );
      final docPatient2 = Patient(
        id: docId2,
        name: 'Suresh Patil',
        phoneNumber: '9822022222',
        source: PatientSource.doctorCreated,
      );
      final sheetPatient1 = Patient(
        id: sheetId1,
        legacyPatientId: '1000001',
        name: 'Anita Sharma',
        phoneNumber: '9822033333',
        source: PatientSource.clinicSheet,
      );

      for (final p in [docPatient1, docPatient2, sheetPatient1]) {
        await database.upsertPatients([p]);
        await supabaseService.upsertPatient(p);
      }
      await database.linkPatientSource(
        patientId: sheetId1,
        source: 'google_sheets',
        externalId: '1000001',
      );
      await supabaseService.linkPatientSource(
        patientId: sheetId1,
        source: 'google_sheets',
        externalId: '1000001',
      );

      expect((await database.getPatients()).length, 3);

      // New Sheet sync with ONLY Anita Sharma (Ramesh and Suresh are not in the sheet)
      final incomingSheet = [
        Patient(
          id: '1000001',
          legacyPatientId: '1000001',
          name: 'Anita Sharma',
          phoneNumber: '9822033333',
          source: PatientSource.clinicSheet,
        ),
      ];

      final result = await syncService.reconcileSheetPatients(incomingSheet);

      expect(result.linkedExistingCount, 1);
      expect(result.createdNewCount, 0);

      // Invariant: Both doctor-created patients MUST still exist!
      final remaining = await database.getPatients();
      expect(remaining.length, 3);
      expect(remaining.any((p) => p.id == docId1), isTrue);
      expect(remaining.any((p) => p.id == docId2), isTrue);
      expect(remaining.any((p) => p.id == sheetId1), isTrue);

      // Supabase still has all 3
      final supabasePatients = await supabaseService.fetchAllPatients();
      expect(supabasePatients.length, 3);
    });

    test('Business identity matching handles whitespace, casing, and varied phone formats', () async {
      const canonicalId = '55555555-5555-4555-8555-555555555555';
      final existing = Patient(
        id: canonicalId,
        displayName: 'Rahul Verma',
        phoneNumber: '+91 98765 43210',
        source: PatientSource.doctorCreated,
      );
      await database.upsertPatients([existing]);
      await supabaseService.upsertPatient(existing);

      // Incoming sheet patient with different formatting: all uppercase, multiple spaces, national format phone
      final incoming = Patient(
        id: '2000099',
        legacyPatientId: '2000099',
        name: '  RAHUL   VERMA  ',
        phoneNumber: '09876543210',
      );

      final result = await syncService.reconcileSheetPatients([incoming]);

      expect(result.linkedExistingCount, 1);
      expect(result.createdNewCount, 0);

      final patients = await database.getPatients();
      expect(patients.length, 1);
      expect(patients.first.id, canonicalId);
      expect(patients.first.source, PatientSource.merged);
      expect(patients.first.legacyPatientId, '2000099');
    });

    test('Sheet Patient ID (e.g. 1000001) is NEVER inserted into patients.id and maps to patient_sources.external_id', () async {
      final sheetRow = Patient(
        id: '1000001',
        legacyPatientId: '1000001',
        name: 'Sunita Patil',
        phoneNumber: '9876543210',
        driveFolderId: 'folder_sunita_123',
        source: PatientSource.clinicSheet,
      );

      final result = await syncService.reconcileSheetPatients([sheetRow]);

      expect(result.createdNewCount, 1);
      expect(result.linkedExistingCount, 0);

      // Verify SQLite record
      final localPatients = await database.getPatients();
      expect(localPatients.length, 1);
      final local = localPatients.first;
      expect(local.id, isNot('1000001'));
      expect(Patient.isValidUuid(local.id), isTrue);
      expect(local.legacyPatientId, '1000001');
      expect(local.name, 'Sunita Patil');

      // Verify Supabase record
      final cloudPatients = await supabaseService.fetchAllPatients();
      expect(cloudPatients.length, 1);
      final cloud = cloudPatients.first;
      expect(cloud.id, local.id);
      expect(Patient.isValidUuid(cloud.id), isTrue);
      expect(cloud.displayName, 'Sunita Patil');

      // Verify source mapping
      final localSourceId = await database.getPatientIdBySource(
        source: 'google_sheets',
        externalId: '1000001',
      );
      expect(localSourceId, local.id);

      final cloudSourceId = await supabaseService.getPatientIdBySource(
        source: 'google_sheets',
        externalId: '1000001',
      );
      expect(cloudSourceId, local.id);

      // Verify non-UUID lookup returns null safely without error
      expect(await supabaseService.getPatientById('1000001'), isNull);
    });

    test('Ignore Sheet rows with no usable patient name - does not create Name unavailable patients', () async {
      final rows = [
        Patient(id: '1000010', legacyPatientId: '1000010', name: ''),
        Patient(id: '1000011', legacyPatientId: '1000011', name: 'Name unavailable'),
        Patient(id: '1000012', legacyPatientId: '1000012', name: 'Patient 1000012'),
        Patient(id: '1000013', legacyPatientId: '1000013', name: 'None'),
        Patient(id: '1000014', legacyPatientId: '1000014', name: 'null'),
        Patient(id: '1000015', legacyPatientId: '1000015', name: 'Dr. Neha Kulkarni', phoneNumber: '9822556677'),
      ];

      final result = await syncService.reconcileSheetPatients(rows);

      // Only the genuine clinical patient should be created
      expect(result.createdNewCount, 1);
      expect(result.reconciledPatients.length, 1);
      expect(result.reconciledPatients.first.name, 'Dr. Neha Kulkarni');

      final allLocal = await database.getPatients();
      expect(allLocal.length, 1);
      expect(allLocal.first.displayName, 'Dr. Neha Kulkarni');

      final allCloud = await supabaseService.fetchAllPatients();
      expect(allCloud.length, 1);
      expect(allCloud.first.displayName, 'Dr. Neha Kulkarni');
    });

    test('Multi-phone synchronization: Phone A creates patient -> Supabase -> Phone B receives same UUID', () async {
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

      // Phone A imports a Sheet patient
      final sheetPatient = Patient(
        id: '1000077',
        legacyPatientId: '1000077',
        name: 'Vikas Sharma',
        phoneNumber: '9422112233',
        source: PatientSource.clinicSheet,
      );

      await syncPhoneA.reconcileSheetPatients([sheetPatient]);

      final patientA = (await dbPhoneA.getPatients()).first;
      expect(Patient.isValidUuid(patientA.id), isTrue);

      // Phone B synchronizes with Supabase
      await syncPhoneB.syncLocalWithSupabase();

      final patientsB = await dbPhoneB.getPatients();
      expect(patientsB.length, 1);
      final patientB = patientsB.first;
      expect(patientB.id, patientA.id);
      expect(patientB.displayName, 'Vikas Sharma');

      // Now Phone B also imports the same sheet row
      await syncPhoneB.reconcileSheetPatients([sheetPatient]);

      // Phone B must NOT create a duplicate!
      final patientsBAfter = await dbPhoneB.getPatients();
      expect(patientsBAfter.length, 1);
      expect(patientsBAfter.first.id, patientA.id);
    });

    test('Initial cloud bootstrap: empty Supabase is populated from existing local SQLite patients', () async {
      const p1Id = '66666666-6666-4666-8666-666666666666';
      const p2Id = '77777777-7777-4777-8777-777777777777';

      final p1 = Patient(
        id: p1Id,
        name: 'Pooja Hegde',
        phoneNumber: '9111122222',
        legacyPatientId: '1000001',
        source: PatientSource.clinicSheet,
        syncStatus: 'synced',
      );
      final p2 = Patient(
        id: p2Id,
        name: 'Mahesh Babu',
        phoneNumber: '9222233333',
        legacyPatientId: '1000002',
        source: PatientSource.clinicSheet,
        syncStatus: 'synced',
      );

      await database.upsertPatients([p1, p2]);
      await database.linkPatientSource(patientId: p1Id, source: 'google_sheets', externalId: '1000001');
      await database.linkPatientSource(patientId: p2Id, source: 'google_sheets', externalId: '1000002');

      // Verify Supabase is currently empty
      expect((await supabaseService.fetchAllPatients()).length, 0);

      // Perform sync
      await syncService.syncLocalWithSupabase();

      // Supabase is now bootstrapped with both patients!
      final cloudPatients = await supabaseService.fetchAllPatients();
      expect(cloudPatients.length, 2);
      expect(cloudPatients.any((p) => p.id == p1Id), isTrue);
      expect(cloudPatients.any((p) => p.id == p2Id), isTrue);

      // Source mappings were established in Supabase
      expect(
        await supabaseService.getPatientIdBySource(source: 'google_sheets', externalId: '1000001'),
        p1Id,
      );
      expect(
        await supabaseService.getPatientIdBySource(source: 'google_sheets', externalId: '1000002'),
        p2Id,
      );
    });

    test('SQLite migration converts legacy numeric IDs to UUIDs and remaps foreign keys in uploads and sessions', () async {
      final fakeDb = FakeLegacyMigrationDatabase(
        patients: [
          {
            'id': '1000001',
            'display_name': 'Kavita Roy',
            'normalized_name': 'kavita roy',
            'phone_display': '9890012345',
            'normalized_phone': '9890012345',
            'legacy_patient_id': '1000001',
            'source': 'clinic_sheet',
            'folder_status': 'available',
            'created_at': DateTime.now().toIso8601String(),
          }
        ],
        uploads: [
          {
            'id': 'upload-1',
            'session_id': 'sess-1',
            'patient_id': '1000001',
            'local_path': '/path/photo.jpg',
            'file_name': 'photo.jpg',
            'status': 'waiting',
            'retry_count': 0,
            'created_at': DateTime.now().toIso8601String(),
            'captured_at': DateTime.now().toIso8601String(),
            'sequence_number': 1,
          }
        ],
        sessions: [
          {
            'id': 'sess-1',
            'patient_id': '1000001',
            'created_at': DateTime.now().toIso8601String(),
            'status': 'assigned',
          }
        ],
      );

      await SqliteAppDatabase.migrateLegacyNonUuidPatientsForTesting(fakeDb);

      expect(fakeDb.updatedPatients.length, 1);
      final pUpdate = fakeDb.updatedPatients.first;
      final newUuid = pUpdate['id'] as String;
      expect(Patient.isValidUuid(newUuid), isTrue);
      expect(pUpdate['legacy_patient_id'], '1000001');
      expect(pUpdate['sync_status'], 'pending_cloud');

      expect(fakeDb.updatedUploads.length, 1);
      expect(fakeDb.updatedUploads.first['patient_id'], newUuid);

      expect(fakeDb.updatedSessions.length, 1);
      expect(fakeDb.updatedSessions.first['patient_id'], newUuid);

      expect(fakeDb.patientSources.length, 1);
      expect(fakeDb.patientSources.first['patient_id'], newUuid);
      expect(fakeDb.patientSources.first['external_id'], '1000001');
    });

    test('Bidirectional multi-device sync: Phone B creates -> Supabase -> Phone A sync -> appears on Phone A', () async {
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

      // Phone B creates a patient in-app
      const patientBId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      final doctorPatientB = Patient(
        id: patientBId,
        name: 'Rohan Joshi',
        displayName: 'Rohan Joshi',
        phoneNumber: '9888877777',
        source: PatientSource.doctorCreated,
        syncStatus: 'pending_cloud',
      );

      await dbPhoneB.upsertPatients([doctorPatientB]);
      // Phone B pushes to Supabase
      await syncPhoneB.syncLocalWithSupabase();

      // Verify patient is in Supabase
      final cloudPatients = await sharedSupabase.fetchAllPatients();
      expect(cloudPatients.length, 1);
      expect(cloudPatients.first.id, patientBId);

      // Phone A syncs with Supabase
      await syncPhoneA.syncLocalWithSupabase();

      // Verify patient appears on Phone A
      final patientsA = await dbPhoneA.getPatients();
      expect(patientsA.length, 1);
      expect(patientsA.first.id, patientBId);
      expect(patientsA.first.displayName, 'Rohan Joshi');
    });

    test('Safe placeholder reconciliation removes only stale empty Sheet imports and preserves records with photos/folders/doctor source', () async {
      final db = InMemoryAppDatabase();

      // 1. Stale empty Sheet import (should be deleted)
      const staleId = '11111111-2222-4333-8444-555555555555';
      final stalePatient = Patient(
        id: staleId,
        name: 'Name unavailable',
        displayName: 'Name unavailable',
        source: PatientSource.clinicSheet,
      );

      // 2. Placeholder name but HAS PHOTOS (must be preserved)
      const photoPatientId = '22222222-3333-4444-8555-666666666666';
      final photoPatient = Patient(
        id: photoPatientId,
        name: 'Name unavailable',
        displayName: 'Name unavailable',
        source: PatientSource.clinicSheet,
      );

      // 3. Placeholder name but HAS DRIVE FOLDER (must be preserved)
      const drivePatientId = '33333333-4444-4555-8666-777777777777';
      final drivePatient = Patient(
        id: drivePatientId,
        name: 'Name unavailable',
        displayName: 'Name unavailable',
        source: PatientSource.clinicSheet,
        driveFolderId: 'folder_drive_xyz',
      );

      // 4. Manually-created DOCTOR patient with placeholder-like name (must NEVER be deleted)
      const doctorPatientId = '44444444-5555-4666-8777-888888888888';
      final doctorPatient = Patient(
        id: doctorPatientId,
        name: 'Name unavailable',
        displayName: 'Name unavailable',
        source: PatientSource.doctorCreated,
      );

      await db.upsertPatients([stalePatient, photoPatient, drivePatient, doctorPatient]);

      // Add a photo for photoPatient
      await db.insertUpload(UploadItem(
        id: 'upload-test-1',
        sessionId: 'sess-1',
        patientId: photoPatientId,
        localPath: '/path/test.jpg',
        fileName: 'test.jpg',
        status: UploadStatus.waiting,
        createdAt: DateTime.now(),
        capturedAt: DateTime.now(),
      ));

      // Run safe reconciliation
      final cleanedCount = await db.reconcileStalePlaceholderPatients();

      // Exactly 1 record should be cleaned up (stalePatient)
      expect(cleanedCount, 1);

      final remaining = await db.getPatients();
      expect(remaining.length, 3);
      expect(remaining.any((p) => p.id == staleId), isFalse);
      expect(remaining.any((p) => p.id == photoPatientId), isTrue);
      expect(remaining.any((p) => p.id == drivePatientId), isTrue);
      expect(remaining.any((p) => p.id == doctorPatientId), isTrue);
    });

    test('Supabase RLS policy error is explicitly detected, surfaces diagnostic message, and keeps local status pending_cloud', () async {
      final db = InMemoryAppDatabase();
      final failingSupabase = FailingRlsSupabasePatientService();
      final sync = PatientSyncService(
        database: db,
        supabaseService: failingSupabase,
        sheetsService: sheetsService,
      );

      final incoming = Patient(
        id: '1000099',
        legacyPatientId: '1000099',
        name: 'Gaurav Sen',
        phoneNumber: '9900112233',
        source: PatientSource.clinicSheet,
      );

      final result = await sync.reconcileSheetPatients([incoming]);

      // Reconciliation should succeed locally
      expect(result.reconciledPatients.length, 1);
      // But cloud sync must report false with descriptive RLS error
      expect(result.isSupabaseSynced, isFalse);
      expect(result.supabaseError, contains("require the 'authenticated' role, but the app connects with the 'anon' role"));

      // Local patient must NOT be marked synced; it must remain pending_cloud!
      final local = (await db.getPatients()).first;
      expect(local.syncStatus, 'pending_cloud');
    });
  });
}

class FailingRlsSupabasePatientService extends InMemorySupabasePatientService {
  @override
  Future<Patient> upsertPatient(Patient patient) async {
    throw Exception('PostgrestException(message: {"code":"42501","details":null,"hint":null,"message":"new row violates row-level security policy for table \\"patients\\""}, code: 401, details: Unauthorized, hint: null)');
  }

  @override
  Future<List<Patient>> fetchAllPatients() async {
    // Under RLS, unauthenticated SELECT returns empty list
    return [];
  }
}

class FakeLegacyMigrationDatabase extends Fake implements Database {
  final List<Map<String, Object?>> patients;
  final List<Map<String, Object?>> uploads;
  final List<Map<String, Object?>> sessions;
  final List<Map<String, Object?>> patientSources = [];
  final List<Map<String, Object?>> updatedPatients = [];
  final List<Map<String, Object?>> updatedUploads = [];
  final List<Map<String, Object?>> updatedSessions = [];

  FakeLegacyMigrationDatabase({
    required this.patients,
    required this.uploads,
    required this.sessions,
  });

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {
    if (sql.contains('SELECT * FROM patients WHERE id NOT LIKE')) {
      return patients.where((p) => !Patient.isValidUuid(p['id']?.toString())).toList();
    }
    if (sql.contains('COUNT(*) FROM uploads')) {
      final pid = arguments?.first?.toString();
      final count = uploads.where((u) => u['patient_id'] == pid).length;
      return [{'COUNT(*)': count}];
    }
    if (sql.contains('COUNT(*) FROM capture_sessions')) {
      final pid = arguments?.first?.toString();
      final count = sessions.where((s) => s['patient_id'] == pid).length;
      return [{'COUNT(*)': count}];
    }
    if (sql.contains('SELECT id, patient_id FROM patient_sources')) {
      return patientSources.where((s) => !Patient.isValidUuid(s['patient_id']?.toString())).toList();
    }
    return [];
  }

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) async {
    return 1;
  }

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action, {bool? exclusive}) async {
    final txn = FakeLegacyMigrationTxn(this);
    return await action(txn);
  }
}

class FakeLegacyMigrationTxn extends Fake implements Transaction {
  final FakeLegacyMigrationDatabase db;
  FakeLegacyMigrationTxn(this.db);

  @override
  Future<int> update(String table, Map<String, Object?> values, {String? where, List<Object?>? whereArgs, ConflictAlgorithm? conflictAlgorithm}) async {
    if (table == 'patients') {
      db.updatedPatients.add(values);
    } else if (table == 'uploads') {
      db.updatedUploads.add(values);
    } else if (table == 'capture_sessions') {
      db.updatedSessions.add(values);
    }
    return 1;
  }

  @override
  Future<List<Map<String, Object?>>> query(String table, {bool? distinct, List<String>? columns, String? where, List<Object?>? whereArgs, String? groupBy, String? having, String? orderBy, int? limit, int? offset}) async {
    if (table == 'patient_sources') {
      return db.patientSources.where((s) => s['source'] == whereArgs?[0] && s['external_id'] == whereArgs?[1]).toList();
    }
    return [];
  }

  @override
  Future<int> insert(String table, Map<String, Object?> values, {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) async {
    if (table == 'patient_sources') {
      db.patientSources.add(values);
    }
    return 1;
  }
}
