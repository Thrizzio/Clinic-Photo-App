import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/database.dart';

void main() {
  group('V4 Phase 1: Patient Model & Business Identity Tests', () {
    test('1.1 Name normalization lowercases and collapses whitespaces', () {
      expect(Patient.normalizeName('  Anil   Jain  '), 'anil jain');
      expect(Patient.normalizeName('DR. PRAGATI  WAGHAJI'), 'dr. pragati waghaji');
      expect(Patient.normalizeName(''), '');
    });

    test('1.2 Phone normalization handles Indian formats, prefixes, and rejects placeholders', () {
      const expected = '9876543210';
      expect(Patient.normalizePhone('9876543210'), expected);
      expect(Patient.normalizePhone('+91 98765 43210'), expected);
      expect(Patient.normalizePhone('+919876543210'), expected);
      expect(Patient.normalizePhone('09876543210'), expected);
      expect(Patient.normalizePhone('9.876543210E9'), expected);
      expect(Patient.normalizePhone('9876543210.0'), expected);

      // Invalid / placeholders return null
      expect(Patient.normalizePhone(null), isNull);
      expect(Patient.normalizePhone(''), isNull);
      expect(Patient.normalizePhone('unknown'), isNull);
      expect(Patient.normalizePhone('none'), isNull);
      expect(Patient.normalizePhone('na'), isNull);
      expect(Patient.normalizePhone('n/a'), isNull);
      expect(Patient.normalizePhone('0000000000'), isNull);
    });

    test('1.3 matchesBusinessIdentity requires exact name AND non-null matching phone', () {
      final p1 = Patient(
        id: 'uuid-1',
        name: 'Abhijit Gaikwad',
        phoneNumber: '+91 93732 64424',
      );

      // Exact match
      expect(p1.matchesBusinessIdentity('abhijit gaikwad', '9373264424'), isTrue);

      // Same name, different phone -> NO match
      expect(p1.matchesBusinessIdentity('abhijit gaikwad', '9999999999'), isFalse);

      // Same name, missing phone -> NO match
      expect(p1.matchesBusinessIdentity('abhijit gaikwad', null), isFalse);
      expect(p1.matchesBusinessIdentity('abhijit gaikwad', ''), isFalse);

      // Different name, same phone -> NO match
      expect(p1.matchesBusinessIdentity('rahul gaikwad', '9373264424'), isFalse);

      // Incomplete record (no phone) never matches
      final pIncomplete = Patient(
        id: 'uuid-2',
        name: 'Abhijit Gaikwad',
      );
      expect(pIncomplete.matchesBusinessIdentity('abhijit gaikwad', '9373264424'), isFalse);
    });

    test('1.4 Hard Invariant: Doctor-created patient merged with Sheet patient keeps UUID and Drive folder', () {
      final doctorPatient = Patient(
        id: 'doc-uuid-1234',
        name: 'Abhijit Gaikwad',
        phoneNumber: '9373264424',
        source: PatientSource.doctorCreated,
        driveFolderId: 'drive-folder-existing-777',
        folderStatus: FolderStatus.available,
      );

      final sheetPatient = Patient(
        id: 'sheet-uuid-5678',
        name: 'Abhijit Gaikwad',
        phoneNumber: '+91 93732 64424',
        legacyPatientId: '1000048',
        source: PatientSource.clinicSheet,
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );

      final merged = Patient.merge(doctorPatient, sheetPatient);

      // Retains existing local UUID
      expect(merged.id, 'doc-uuid-1234');
      // Adopts legacy Patient ID from Sheet
      expect(merged.legacyPatientId, '1000048');
      // Transitions source to merged
      expect(merged.source, PatientSource.merged);
      // Preserves existing Drive folder intact
      expect(merged.driveFolderId, 'drive-folder-existing-777');
      expect(merged.folderStatus, FolderStatus.available);
      expect(merged.isUploadable, isTrue);
    });
  });

  group('V4 Phase 1: SQLite V7 Migration & Deduplication Tests', () {
    test('1.5 SQLite schema v7 migration converts numeric IDs to UUIDs, sets legacy_patient_id and maps old IDs', () async {
      // V6 schema table info (missing display_name, source, legacy_patient_id)
      final v6TableInfo = <Map<String, Object?>>[
        {'cid': 0, 'name': 'id', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 1},
        {'cid': 1, 'name': 'name', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
        {'cid': 2, 'name': 'phone_number', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
        {'cid': 3, 'name': 'phone_number_normalized', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
        {'cid': 4, 'name': 'drive_folder_id', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
        {'cid': 5, 'name': 'folder_status', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
        {'cid': 6, 'name': 'updated_at', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
      ];

      final v6PatientsData = <Map<String, Object?>>[
        {
          'id': '1000001',
          'name': 'Anil Jain',
          'phone_number': '+91 94223 01214',
          'phone_number_normalized': '9422301214',
          'drive_folder_id': 'folder_anil_1',
          'folder_status': 'available',
          'updated_at': DateTime.now().toIso8601String(),
        }
      ];

      final fakeDb = FakeV7MigrationDatabase(
        patientsInfo: v6TableInfo,
        patientsData: v6PatientsData,
      );

      await SqliteAppDatabase.migrateToV7ForTesting(fakeDb);

      expect(fakeDb.executedStatements.any((s) => s.contains('ALTER TABLE patients RENAME TO _patients_old_v6')), isTrue);
      expect(fakeDb.executedStatements.any((s) => s.contains('display_name TEXT NOT NULL')), isTrue);
      expect(fakeDb.executedStatements.any((s) => s.contains('legacy_patient_id TEXT')), isTrue);
      expect(fakeDb.executedStatements.any((s) => s.contains('idx_patients_business_id')), isTrue);

      final inserted = fakeDb.lastTxn?.insertedPatients;
      expect(inserted, isNotNull);
      expect(inserted!.length, 1);
      final pRow = inserted.first;
      final newUuid = pRow['id'] as String;
      expect(newUuid.contains('-'), isTrue); // UUID generated
      expect(pRow['legacy_patient_id'], '1000001'); // Preserved old ID as legacy
      expect(pRow['display_name'], 'Anil Jain');
      expect(pRow['normalized_name'], 'anil jain');
      expect(pRow['normalized_phone'], '9422301214');
      expect(pRow['source'], 'clinic_sheet');
    });

    test('1.6 upsertPatients deduplicates incoming Sheet patient against doctor-created patient by (name, phone)', () async {
      final db = AppDatabase.inMemory();

      // 1. Doctor creates patient in app
      final doctorPatient = Patient(
        id: 'doc-uuid-999',
        name: 'Abhijit Gaikwad',
        phoneNumber: '9373264424',
        source: PatientSource.doctorCreated,
        driveFolderId: 'drive_doc_folder',
        folderStatus: FolderStatus.available,
      );

      await db.upsertPatients([doctorPatient]);

      final inDbBefore = await db.getPatient('doc-uuid-999');
      expect(inDbBefore, isNotNull);
      expect(inDbBefore!.source, PatientSource.doctorCreated);
      expect(inDbBefore.legacyPatientId, isNull);

      // 2. Sheet import arrives days later with same person and sheet ID 1000048
      final sheetPatient = Patient(
        id: 'sheet-uuid-888',
        name: 'Abhijit Gaikwad',
        phoneNumber: '+91 93732 64424',
        legacyPatientId: '1000048',
        source: PatientSource.clinicSheet,
      );

      await db.upsertPatients([sheetPatient]);

      // Exactly 1 patient in DB
      final allPatients = await db.getPatients();
      expect(allPatients.length, 1);

      // Retained doctor patient UUID, preserved folder, attached legacyPatientId
      final mergedInDb = allPatients.first;
      expect(mergedInDb.id, 'doc-uuid-999');
      expect(mergedInDb.legacyPatientId, '1000048');
      expect(mergedInDb.source, PatientSource.merged);
      expect(mergedInDb.driveFolderId, 'drive_doc_folder');

      // Resolvable by UUID or legacy ID
      expect(await db.getPatient('doc-uuid-999'), isNotNull);
      expect(await db.getPatient('1000048'), isNotNull);

      // Resolvable by business identity
      final byBiz = await db.getPatientByBusinessIdentity('abhijit gaikwad', '9373264424');
      expect(byBiz, isNotNull);
      expect(byBiz!.id, 'doc-uuid-999');

      await db.close();
    });
  });
}

class FakeV7MigrationDatabase extends Fake implements Database {
  final List<Map<String, Object?>> patientsInfo;
  final List<Map<String, Object?>> patientsData;
  final List<String> executedStatements = [];
  FakeV7MigrationTransaction? lastTxn;

  FakeV7MigrationDatabase({required this.patientsInfo, required this.patientsData});

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {
    executedStatements.add(sql);
    if (sql.contains('PRAGMA table_info(patients)')) {
      return patientsInfo;
    }
    if (sql.contains('PRAGMA table_info(capture_sessions)') || sql.contains('PRAGMA table_info(uploads)')) {
      return [];
    }
    return [];
  }

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action, {bool? exclusive}) async {
    final fakeTxn = FakeV7MigrationTransaction(executedStatements, patientsInfo, patientsData);
    lastTxn = fakeTxn;
    return await action(fakeTxn);
  }
}

class FakeV7MigrationTransaction extends Fake implements Transaction {
  final List<String> executedStatements;
  final List<Map<String, Object?>> patientsInfo;
  final List<Map<String, Object?>> patientsData;
  final List<Map<String, Object?>> insertedPatients = [];

  FakeV7MigrationTransaction(this.executedStatements, this.patientsInfo, this.patientsData);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    executedStatements.add(sql);
  }

  @override
  Future<List<Map<String, Object?>>> query(String table,
      {bool? distinct,
      List<String>? columns,
      String? where,
      List<Object?>? whereArgs,
      String? groupBy,
      String? having,
      String? orderBy,
      int? limit,
      int? offset}) async {
    if (table == 'patients') {
      return patientsData;
    }
    return [];
  }

  @override
  Future<int> insert(String table, Map<String, Object?> values,
      {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) async {
    if (table == 'patients') {
      insertedPatients.add(values);
    }
    return 1;
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {
    executedStatements.add(sql);
    return [];
  }

  @override
  Future<int> update(String table, Map<String, Object?> values,
      {String? where, List<Object?>? whereArgs, ConflictAlgorithm? conflictAlgorithm}) async {
    return 1;
  }
}
