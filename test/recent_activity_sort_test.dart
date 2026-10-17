import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

class FakeV11MigrationDatabase extends Fake implements Database {
  final List<Map<String, Object?>> patientsTableInfo;
  final List<String> executedStatements = [];

  FakeV11MigrationDatabase({required this.patientsTableInfo});

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {
    executedStatements.add(sql);
    if (sql.contains('PRAGMA table_info(patients)')) {
      return patientsTableInfo;
    }
    return [];
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    executedStatements.add(sql);
    if (sql.contains('ALTER TABLE patients ADD COLUMN last_viewed_at')) {
      patientsTableInfo.add({
        'cid': patientsTableInfo.length,
        'name': 'last_viewed_at',
        'type': 'TEXT',
        'notnull': 0,
        'dflt_value': null,
        'pk': 0,
      });
    }
  }

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action, {bool? exclusive}) async {
    final fakeTxn = FakeV11MigrationTransaction(this);
    return await action(fakeTxn);
  }
}

class FakeV11MigrationTransaction extends Fake implements Transaction {
  final FakeV11MigrationDatabase db;
  FakeV11MigrationTransaction(this.db);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) => db.execute(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) => db.rawQuery(sql, arguments);
}

void main() {
  group('Phase 5: Recent-Activity Patient Sorting & Semantics', () {
    final t0 = DateTime.utc(2026, 1, 1, 10, 0, 0);
    final t1 = DateTime.utc(2026, 1, 2, 10, 0, 0);
    final t2 = DateTime.utc(2026, 1, 3, 10, 0, 0);

    test('1. effectiveActivityAt calculation evaluates max(last_viewed_at, updated_at, created_at)', () {
      // Case A: Last viewed is newest
      final pA = Patient(
        id: 'p-a',
        name: 'Patient A',
        createdAt: t0,
        updatedAt: t1,
        lastViewedAt: t2,
      );
      expect(pA.effectiveActivityAt, t2);

      // Case B: Clinical update is newest
      final pB = Patient(
        id: 'p-b',
        name: 'Patient B',
        createdAt: t0,
        updatedAt: t2,
        lastViewedAt: t1,
      );
      expect(pB.effectiveActivityAt, t2);

      // Case C: Neither viewed nor updated -> created_at
      final pC = Patient(
        id: 'p-c',
        name: 'Patient C',
        createdAt: t0,
        updatedAt: null,
        lastViewedAt: null,
      );
      expect(pC.effectiveActivityAt, t0);
    });

    test('2. compareByLastModified orders patients by effectiveActivityAt DESC with deterministic tie-breakers', () {
      final pViewedRecently = Patient(
        id: 'uuid-1',
        name: 'Zack View',
        createdAt: t0,
        updatedAt: t0,
        lastViewedAt: t2,
      );
      final pEditedRecently = Patient(
        id: 'uuid-2',
        name: 'Bob Edit',
        createdAt: t0,
        updatedAt: t1,
        lastViewedAt: null,
      );
      final pOlder = Patient(
        id: 'uuid-3',
        name: 'Alice Old',
        createdAt: t0,
        updatedAt: null,
        lastViewedAt: null,
      );

      final list = [pOlder, pViewedRecently, pEditedRecently];
      list.sort(Patient.compareByLastModified);

      expect(list.map((p) => p.id).toList(), ['uuid-1', 'uuid-2', 'uuid-3']);
    });

    test('3. Deterministic tie-breaker uses case-insensitive display name then stable UUID', () {
      final pAlpha = Patient(
        id: 'uuid-b',
        name: 'alpha user',
        displayName: 'alpha user',
        createdAt: t0,
        updatedAt: t1,
      );
      final pBeta = Patient(
        id: 'uuid-a',
        name: 'Beta User',
        displayName: 'Beta User',
        createdAt: t0,
        updatedAt: t1,
      );
      final pAlphaTie = Patient(
        id: 'uuid-a',
        name: 'alpha user',
        displayName: 'alpha user',
        createdAt: t0,
        updatedAt: t1,
      );

      // alpha vs Beta (case-insensitive: 'alpha user' before 'Beta User')
      final list1 = [pBeta, pAlpha];
      list1.sort(Patient.compareByLastModified);
      expect(list1.first.id, 'uuid-b');

      // identical names break tie by UUID ('uuid-a' before 'uuid-b')
      final list2 = [pAlpha, pAlphaTie];
      list2.sort(Patient.compareByLastModified);
      expect(list2.first.id, 'uuid-a');
    });

    test('4. recordPatientViewed updates last_viewed_at without dirtying updated_at or sync_status', () async {
      final database = InMemoryAppDatabase();
      addTearDown(database.close);

      final original = Patient(
        id: 'patient-view-test',
        name: 'Kavita Singh',
        phoneNumber: '9876543210',
        driveFolderId: 'folder_kavita',
        folderStatus: FolderStatus.available,
        createdAt: t0,
        updatedAt: t1,
        lastViewedAt: null,
        syncStatus: 'synced',
      );
      await database.upsertPatients([original]);

      // Record patient viewed
      await database.recordPatientViewed('patient-view-test');

      final updated = await database.getPatient('patient-view-test');
      expect(updated, isNotNull);
      expect(updated!.lastViewedAt, isNotNull);
      expect(updated.lastViewedAt!.isAfter(t1), isTrue);

      // Invariant: Clinical updatedAt is UNTOUCHED
      expect(updated.updatedAt, t1);

      // Invariant: syncStatus remains 'synced' (viewing is purely local activity and never marks dirty for cloud push)
      expect(updated.syncStatus, 'synced');
    });

    test('5. Non-destructive SQLite schema migration to v11 preserves all patient records and adds last_viewed_at', () async {
      // Table info before v11 (missing last_viewed_at)
      final v10TableInfo = <Map<String, Object?>>[
        {'cid': 0, 'name': 'id', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 1},
        {'cid': 1, 'name': 'display_name', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
        {'cid': 2, 'name': 'normalized_name', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
        {'cid': 3, 'name': 'phone_display', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
        {'cid': 4, 'name': 'normalized_phone', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
        {'cid': 5, 'name': 'source', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
        {'cid': 6, 'name': 'drive_folder_id', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
        {'cid': 7, 'name': 'folder_status', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
        {'cid': 8, 'name': 'created_at', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
        {'cid': 9, 'name': 'updated_at', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
        {'cid': 10, 'name': 'sync_status', 'type': 'TEXT', 'notnull': 0, 'dflt_value': 'synced', 'pk': 0},
      ];

      final fakeDb = FakeV11MigrationDatabase(patientsTableInfo: v10TableInfo);

      // Verify last_viewed_at is not present before migration
      expect(fakeDb.patientsTableInfo.any((c) => c['name'] == 'last_viewed_at'), isFalse);

      // Execute migration to v11
      await SqliteAppDatabase.migrateToV11ForTesting(fakeDb);

      // Verify last_viewed_at column was added
      expect(fakeDb.patientsTableInfo.any((c) => c['name'] == 'last_viewed_at'), isTrue);
      expect(
        fakeDb.executedStatements.any((s) => s.contains('ALTER TABLE patients ADD COLUMN last_viewed_at TEXT')),
        isTrue,
      );
      expect(
        fakeDb.executedStatements.any((s) => s.contains('CREATE TABLE IF NOT EXISTS remote_photo_cache')),
        isTrue,
      );
    });
  });
}
