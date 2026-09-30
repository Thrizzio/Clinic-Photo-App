import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/capture_session.dart';
import '../models/patient.dart';
import '../models/upload_item.dart';

enum SearchFilterMode {
  all,
  name,
  phone,
  patientId;

  String get label => switch (this) {
        SearchFilterMode.all => 'All',
        SearchFilterMode.name => 'Name',
        SearchFilterMode.phone => 'Phone',
        SearchFilterMode.patientId => 'Patient ID',
      };
}

/// Abstract contract for clinic data storage.
abstract class AppDatabase {
  // --- Patients Cache Operations ---

  /// Replaces the entire patients cache with fresh records.
  Future<void> replacePatients(List<Patient> patients);

  /// Upserts a batch of patients (used during incremental sync).
  Future<void> upsertPatients(List<Patient> patients);

  /// Retrieves a single patient by ID.
  Future<Patient?> getPatient(String id);

  /// Retrieves all cached patients sorted by ID.
  Future<List<Patient>> getPatients();

  /// Search patients with optional filter mode (All, Name, Phone, Patient ID).
  Future<List<Patient>> searchPatients(
    String query, {
    SearchFilterMode mode = SearchFilterMode.all,
  });

  // --- Capture Sessions Operations ---

  /// Inserts a new capture session.
  Future<void> insertSession(CaptureSession session);

  /// Retrieves a capture session by ID.
  Future<CaptureSession?> getSession(String id);

  /// Retrieves all unassigned sessions with their photo counts.
  Future<List<CaptureSession>> getUnassignedSessions();

  /// Gets the count of pending unassigned sessions.
  Future<int> getUnassignedSessionsCount();

  /// Updates an existing capture session.
  Future<void> updateSession(CaptureSession session);

  /// Deletes a capture session.
  Future<void> deleteSession(String id);

  /// Gets all uploads belonging to a given session.
  Future<List<UploadItem>> getUploadsForSession(String sessionId);

  /// Updates a patient's cached record.
  Future<void> updatePatient(Patient patient);

  /// Atomically assigns an unassigned session and all its photos to a patient,
  /// transitioning all photos to waiting status for upload.
  Future<void> assignSessionToPatient({
    required String sessionId,
    required String patientId,
    required String driveFolderId,
    Map<String, ({String fileName, String localPath})>? renamedPhotos,
  });

  // --- Upload Queue Operations ---

  /// Inserts a new upload item.
  Future<void> insertUpload(UploadItem item);

  /// Updates an existing upload item (status, retries, errors).
  Future<void> updateUpload(UploadItem item);

  /// Deletes an upload item once Drive upload is confirmed successful.
  Future<void> deleteUpload(String id);

  /// Deletes multiple upload items in a single transaction.
  Future<void> deleteUploads(List<String> ids);

  /// Gets the next waiting upload item to process.
  Future<UploadItem?> getNextPendingUpload();

  /// Gets count of active uploads (waiting or uploading).
  Future<int> getActiveUploadsCount();

  /// Gets count of failed uploads.
  Future<int> getFailedUploadsCount();

  /// Resets all failed uploads back to waiting for manual retry.
  Future<void> resetFailedToWaiting();

  /// Gets all items currently in the queue.
  Future<List<UploadItem>> getAllUploads();

  /// Closes the database connection.
  Future<void> close();

  /// Default production factory: opens SQLite on Android.
  static Future<AppDatabase> init({
    DatabaseFactory? databaseFactory,
    String? customPath,
  }) async {
    return SqliteAppDatabase.init(
      databaseFactory: databaseFactory,
      customPath: customPath,
    );
  }

  /// In-memory implementation for fast unit tests without FFI/native assets.
  factory AppDatabase.inMemory({
    Map<String, Patient>? initialPatients,
    Map<String, CaptureSession>? initialSessions,
    Map<String, UploadItem>? initialUploads,
    bool performCrashRecovery = true,
  }) {
    return InMemoryAppDatabase(
      initialPatients: initialPatients,
      initialSessions: initialSessions,
      initialUploads: initialUploads,
      performCrashRecovery: performCrashRecovery,
    );
  }
}

/// SQLite-backed production database implementation for Android.
class SqliteAppDatabase implements AppDatabase {
  static const String _dbName = 'clinic_photos.db';
  static const int _dbVersion = 6;

  final Database db;

  SqliteAppDatabase(this.db);

  static Future<SqliteAppDatabase> init({
    DatabaseFactory? databaseFactory,
    String? customPath,
  }) async {
    final factory = databaseFactory ?? databaseFactorySqflitePlugin;
    final dbPath = customPath ?? p.join(await factory.getDatabasesPath(), _dbName);

    final database = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE patients (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              phone_number TEXT,
              phone_number_normalized TEXT,
              drive_folder_id TEXT,
              folder_status TEXT NOT NULL,
              updated_at TEXT
            )
          ''');

          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_patients_status ON patients(folder_status)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_patients_search ON patients(id, name, phone_number_normalized)',
          );

          await db.execute('''
            CREATE TABLE capture_sessions (
              id TEXT PRIMARY KEY,
              patient_id TEXT,
              created_at TEXT NOT NULL,
              status TEXT NOT NULL
            )
          ''');

          await db.execute('''
            CREATE TABLE uploads (
              id TEXT PRIMARY KEY,
              session_id TEXT,
              patient_id TEXT,
              drive_folder_id TEXT,
              local_path TEXT NOT NULL,
              file_name TEXT NOT NULL,
              status TEXT NOT NULL,
              retry_count INTEGER NOT NULL DEFAULT 0,
              last_error TEXT,
              drive_file_id TEXT,
              created_at TEXT NOT NULL,
              captured_at TEXT NOT NULL,
              sequence_number INTEGER NOT NULL DEFAULT 1
            )
          ''');

          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_uploads_patient_id ON uploads(patient_id)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_uploads_session_id ON uploads(session_id)',
          );
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS capture_sessions (
                id TEXT PRIMARY KEY,
                patient_id TEXT,
                created_at TEXT NOT NULL,
                status TEXT NOT NULL
              )
            ''');

            try {
              await db.execute(
                "ALTER TABLE patients ADD COLUMN folder_status TEXT NOT NULL DEFAULT 'available'",
              );
            } catch (_) {}
          }

          if (oldVersion < 3) {
            await _ensureUploadsTableSchema(db);
          }

          if (oldVersion < 4) {
            try {
              await db.execute("ALTER TABLE patients ADD COLUMN updated_at TEXT");
            } catch (_) {}
            try {
              await db.execute("ALTER TABLE uploads ADD COLUMN captured_at TEXT");
            } catch (_) {}
            try {
              await db.execute("ALTER TABLE uploads ADD COLUMN sequence_number INTEGER NOT NULL DEFAULT 1");
            } catch (_) {}
            try {
              await db.execute("CREATE INDEX IF NOT EXISTS idx_uploads_patient_id ON uploads(patient_id)");
              await db.execute("CREATE INDEX IF NOT EXISTS idx_uploads_session_id ON uploads(session_id)");
            } catch (_) {}
          }

          if (oldVersion < 5) {
            await _ensurePatientsTableSchema(db);
          }

          if (oldVersion < 6) {
            await _ensurePatientsTableSchema(db);
          }
        },
        onOpen: (db) async {
          // Ensure schema compatibility on existing databases (nullable patient_id / drive_folder_id)
          await _ensurePatientsTableSchema(db);
          await _ensureUploadsTableSchema(db);

          // Crash recovery: Any upload that was interrupted in 'uploading'
          // status is reset to 'waiting' so processing will resume cleanly.
          // Note: 'unassigned' photos are untouched by crash recovery.
          await db.update(
            'uploads',
            {'status': UploadStatus.waiting.name},
            where: 'status = ?',
            whereArgs: [UploadStatus.uploading.name],
          );
        },
      ),
    );

    return SqliteAppDatabase(database);
  }

  /// Migrates patients table if drive_folder_id has a NOT NULL constraint,
  /// or if folder_status, updated_at, phone_number, or phone_number_normalized are missing.
  static Future<void> _ensurePatientsTableSchema(Database db) async {
    final tableInfo = await db.rawQuery("PRAGMA table_info(patients)");
    if (tableInfo.isEmpty) return;

    final folderIdCol = tableInfo.firstWhere(
      (c) => c['name'] == 'drive_folder_id',
      orElse: () => <String, Object?>{},
    );
    final hasFolderStatus = tableInfo.any((c) => c['name'] == 'folder_status');
    final hasUpdatedAt = tableInfo.any((c) => c['name'] == 'updated_at');
    final hasPhone = tableInfo.any((c) => c['name'] == 'phone_number');
    final hasNormPhone = tableInfo.any((c) => c['name'] == 'phone_number_normalized');

    final isFolderIdNotNull = folderIdCol['notnull'] == 1;
    final needsMigration = isFolderIdNotNull ||
        !hasFolderStatus ||
        !hasUpdatedAt ||
        !hasPhone ||
        !hasNormPhone;

    if (needsMigration) {
      await db.transaction((txn) async {
        await txn.execute('ALTER TABLE patients RENAME TO _patients_old');
        await txn.execute('''
          CREATE TABLE patients (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            phone_number TEXT,
            phone_number_normalized TEXT,
            drive_folder_id TEXT,
            folder_status TEXT NOT NULL,
            updated_at TEXT
          )
        ''');

        final oldColumns = await txn.rawQuery("PRAGMA table_info(_patients_old)");
        final oldHasFolderStatus = oldColumns.any((c) => c['name'] == 'folder_status');
        final oldHasUpdatedAt = oldColumns.any((c) => c['name'] == 'updated_at');
        final oldHasPhone = oldColumns.any((c) => c['name'] == 'phone_number');
        final oldHasNormPhone = oldColumns.any((c) => c['name'] == 'phone_number_normalized');

        final selectStatus = oldHasFolderStatus ? "folder_status" : "'available'";
        final selectUpdatedAt = oldHasUpdatedAt ? "updated_at" : "NULL";
        final selectPhone = oldHasPhone ? "phone_number" : "NULL";
        final selectNormPhone = oldHasNormPhone ? "phone_number_normalized" : "NULL";

        await txn.execute('''
          INSERT INTO patients (id, name, phone_number, phone_number_normalized, drive_folder_id, folder_status, updated_at)
          SELECT id, name, $selectPhone, $selectNormPhone, drive_folder_id, $selectStatus, $selectUpdatedAt
          FROM _patients_old
        ''');

        await txn.execute('DROP TABLE _patients_old');
        await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_patients_status ON patients(folder_status)',
        );
        await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_patients_search ON patients(id, name, phone_number_normalized)',
        );
      });
    }
  }

  /// Visible for unit testing schema migration.
  @visibleForTesting
  static Future<void> ensurePatientsTableSchemaForTesting(Database db) =>
      _ensurePatientsTableSchema(db);

  /// Migrates uploads table if patient_id has a NOT NULL constraint or session_id is missing.
  static Future<void> _ensureUploadsTableSchema(Database db) async {
    final tableInfo = await db.rawQuery("PRAGMA table_info(uploads)");
    if (tableInfo.isEmpty) return;

    final patientIdCol = tableInfo.firstWhere(
      (c) => c['name'] == 'patient_id',
      orElse: () => <String, Object?>{},
    );
    final hasSessionId = tableInfo.any((c) => c['name'] == 'session_id');
    final hasCapturedAt = tableInfo.any((c) => c['name'] == 'captured_at');
    final hasSeq = tableInfo.any((c) => c['name'] == 'sequence_number');

    final isPatientIdNotNull = patientIdCol['notnull'] == 1;
    final needsMigration = isPatientIdNotNull || !hasSessionId || !hasCapturedAt || !hasSeq;

    if (needsMigration) {
      await db.transaction((txn) async {
        await txn.execute('ALTER TABLE uploads RENAME TO _uploads_old');
        await txn.execute('''
          CREATE TABLE uploads (
            id TEXT PRIMARY KEY,
            session_id TEXT,
            patient_id TEXT,
            drive_folder_id TEXT,
            local_path TEXT NOT NULL,
            file_name TEXT NOT NULL,
            status TEXT NOT NULL,
            retry_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            drive_file_id TEXT,
            created_at TEXT NOT NULL,
            captured_at TEXT NOT NULL,
            sequence_number INTEGER NOT NULL DEFAULT 1
          )
        ''');

        final oldColumns = await txn.rawQuery("PRAGMA table_info(_uploads_old)");
        final oldHasSessionId = oldColumns.any((c) => c['name'] == 'session_id');
        final oldHasCapturedAt = oldColumns.any((c) => c['name'] == 'captured_at');
        final oldHasSeq = oldColumns.any((c) => c['name'] == 'sequence_number');

        final selectSessionId = oldHasSessionId ? "session_id" : "NULL";
        final selectCapturedAt = oldHasCapturedAt ? "captured_at" : "created_at";
        final selectSeq = oldHasSeq ? "sequence_number" : "1";

        await txn.execute('''
          INSERT INTO uploads (id, session_id, patient_id, drive_folder_id, local_path, file_name, status, retry_count, last_error, drive_file_id, created_at, captured_at, sequence_number)
          SELECT id, $selectSessionId, patient_id, drive_folder_id, local_path, file_name, status, retry_count, last_error, drive_file_id, created_at, $selectCapturedAt, $selectSeq
          FROM _uploads_old
        ''');

        await txn.execute('DROP TABLE _uploads_old');
        await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_uploads_patient_id ON uploads(patient_id)',
        );
        await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_uploads_session_id ON uploads(session_id)',
        );
      });
    }
  }

  // --- Patients Cache Operations ---

  @override
  Future<void> replacePatients(List<Patient> patients) async {
    await db.transaction((txn) async {
      await txn.delete('patients');
      final batch = txn.batch();
      for (final patient in patients) {
        batch.insert('patients', patient.toMap());
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<void> upsertPatients(List<Patient> patients) async {
    await db.transaction((txn) async {
      for (final incoming in patients) {
        final existingRows = await txn.query(
          'patients',
          where: 'id = ?',
          whereArgs: [incoming.id],
          limit: 1,
        );

        if (existingRows.isEmpty) {
          await txn.insert(
            'patients',
            incoming.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        } else {
          final existing = Patient.fromMap(existingRows.first);
          final merged = Patient.merge(existing, incoming);
          await txn.update(
            'patients',
            merged.toMap(),
            where: 'id = ?',
            whereArgs: [incoming.id],
          );
        }
      }
    });
  }

  @override
  Future<Patient?> getPatient(String id) async {
    final rows = await db.query(
      'patients',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Patient.fromMap(rows.first);
  }

  @override
  Future<List<Patient>> getPatients() async {
    final rows = await db.query('patients', orderBy: 'id ASC');
    return rows.map(Patient.fromMap).toList();
  }

  @override
  Future<List<Patient>> searchPatients(
    String query, {
    SearchFilterMode mode = SearchFilterMode.all,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return getPatients();
    }

    final lower = trimmed.toLowerCase();
    final normPhone = Patient.normalizePhone(trimmed);

    String whereClause;
    List<Object?> whereArgs;

    switch (mode) {
      case SearchFilterMode.name:
        whereClause = 'LOWER(name) LIKE ?';
        whereArgs = ['%$lower%'];
        break;
      case SearchFilterMode.patientId:
        whereClause = 'LOWER(id) LIKE ?';
        whereArgs = ['%$lower%'];
        break;
      case SearchFilterMode.phone:
        if (normPhone != null && normPhone.isNotEmpty) {
          whereClause = '(phone_number_normalized IS NOT NULL AND phone_number_normalized LIKE ?) OR (phone_number IS NOT NULL AND LOWER(phone_number) LIKE ?)';
          whereArgs = ['%$normPhone%', '%$lower%'];
        } else {
          whereClause = 'phone_number IS NOT NULL AND LOWER(phone_number) LIKE ?';
          whereArgs = ['%$lower%'];
        }
        break;
      case SearchFilterMode.all:
        if (normPhone != null && normPhone.isNotEmpty) {
          whereClause = 'LOWER(id) LIKE ? OR LOWER(name) LIKE ? OR (phone_number_normalized IS NOT NULL AND phone_number_normalized LIKE ?) OR (phone_number IS NOT NULL AND LOWER(phone_number) LIKE ?)';
          whereArgs = ['%$lower%', '%$lower%', '%$normPhone%', '%$lower%'];
        } else {
          whereClause = 'LOWER(id) LIKE ? OR LOWER(name) LIKE ? OR (phone_number IS NOT NULL AND LOWER(phone_number) LIKE ?)';
          whereArgs = ['%$lower%', '%$lower%', '%$lower%'];
        }
        break;
    }

    final rows = await db.query(
      'patients',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'id ASC',
    );
    return rows.map(Patient.fromMap).toList();
  }

  // --- Capture Sessions Operations ---

  @override
  Future<void> insertSession(CaptureSession session) async {
    await db.insert('capture_sessions', session.toMap());
  }

  @override
  Future<CaptureSession?> getSession(String id) async {
    final rows = await db.query(
      'capture_sessions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final count = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM uploads WHERE session_id = ?',
      [id],
    ));
    return CaptureSession.fromMap(rows.first, photoCount: count ?? 0);
  }

  @override
  Future<List<CaptureSession>> getUnassignedSessions() async {
    final rows = await db.rawQuery('''
      SELECT s.*, COUNT(u.id) as photo_count
      FROM capture_sessions s
      LEFT JOIN uploads u ON s.id = u.session_id
      WHERE s.status = 'unassigned'
      GROUP BY s.id
      ORDER BY s.created_at DESC
    ''');
    return rows.map(CaptureSession.fromMap).toList();
  }

  @override
  Future<int> getUnassignedSessionsCount() async {
    final count = Sqflite.firstIntValue(await db.rawQuery(
      "SELECT COUNT(*) FROM capture_sessions WHERE status = 'unassigned'",
    ));
    return count ?? 0;
  }

  @override
  Future<void> updateSession(CaptureSession session) async {
    await db.update(
      'capture_sessions',
      session.toMap(),
      where: 'id = ?',
      whereArgs: [session.id],
    );
  }

  @override
  Future<void> deleteSession(String id) async {
    await db.delete(
      'capture_sessions',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<List<UploadItem>> getUploadsForSession(String sessionId) async {
    final rows = await db.query(
      'uploads',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'created_at ASC',
    );
    return rows.map(UploadItem.fromMap).toList();
  }

  @override
  Future<void> updatePatient(Patient patient) async {
    await db.update(
      'patients',
      patient.toMap(),
      where: 'id = ?',
      whereArgs: [patient.id],
    );
  }

  @override
  Future<void> assignSessionToPatient({
    required String sessionId,
    required String patientId,
    required String driveFolderId,
    Map<String, ({String fileName, String localPath})>? renamedPhotos,
  }) async {
    await db.transaction((txn) async {
      await txn.update(
        'capture_sessions',
        {
          'patient_id': patientId,
          'status': 'assigned',
        },
        where: 'id = ?',
        whereArgs: [sessionId],
      );

      if (renamedPhotos != null && renamedPhotos.isNotEmpty) {
        for (final entry in renamedPhotos.entries) {
          await txn.update(
            'uploads',
            {
              'patient_id': patientId,
              'drive_folder_id': driveFolderId,
              'file_name': entry.value.fileName,
              'local_path': entry.value.localPath,
              'status': UploadStatus.waiting.name,
            },
            where: 'id = ? AND session_id = ?',
            whereArgs: [entry.key, sessionId],
          );
        }
      } else {
        await txn.update(
          'uploads',
          {
            'patient_id': patientId,
            'drive_folder_id': driveFolderId,
            'status': UploadStatus.waiting.name,
          },
          where: 'session_id = ?',
          whereArgs: [sessionId],
        );
      }
    });
  }

  // --- Upload Queue Operations ---

  @override
  Future<void> insertUpload(UploadItem item) async {
    await db.insert('uploads', item.toMap());
  }

  @override
  Future<void> updateUpload(UploadItem item) async {
    await db.update(
      'uploads',
      item.toMap(),
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  @override
  Future<void> deleteUpload(String id) async {
    await db.delete(
      'uploads',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> deleteUploads(List<String> ids) async {
    if (ids.isEmpty) return;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final id in ids) {
        batch.delete('uploads', where: 'id = ?', whereArgs: [id]);
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<UploadItem?> getNextPendingUpload() async {
    final rows = await db.query(
      'uploads',
      where: 'status = ?',
      whereArgs: [UploadStatus.waiting.name],
      orderBy: 'created_at ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return UploadItem.fromMap(rows.first);
  }

  @override
  Future<int> getActiveUploadsCount() async {
    final count = Sqflite.firstIntValue(await db.rawQuery(
      "SELECT COUNT(*) FROM uploads WHERE status = 'waiting' OR status = 'uploading'",
    ));
    return count ?? 0;
  }

  @override
  Future<int> getFailedUploadsCount() async {
    final count = Sqflite.firstIntValue(await db.rawQuery(
      "SELECT COUNT(*) FROM uploads WHERE status = 'failed'",
    ));
    return count ?? 0;
  }

  @override
  Future<void> resetFailedToWaiting() async {
    await db.update(
      'uploads',
      {
        'status': UploadStatus.waiting.name,
        'retry_count': 0,
        'last_error': null,
      },
      where: 'status = ?',
      whereArgs: [UploadStatus.failed.name],
    );
  }

  @override
  Future<List<UploadItem>> getAllUploads() async {
    final rows = await db.query('uploads', orderBy: 'created_at ASC');
    return rows.map(UploadItem.fromMap).toList();
  }

  @override
  Future<void> close() async {
    await db.close();
  }
}

/// Pure Dart in-memory database implementation for testing.
class InMemoryAppDatabase implements AppDatabase {
  final Map<String, Patient> _patients = {};
  final Map<String, CaptureSession> _sessions = {};
  final Map<String, UploadItem> _uploads = {};

  InMemoryAppDatabase({
    Map<String, Patient>? initialPatients,
    Map<String, CaptureSession>? initialSessions,
    Map<String, UploadItem>? initialUploads,
    bool performCrashRecovery = true,
  }) {
    if (initialPatients != null) {
      _patients.addAll(initialPatients);
    }
    if (initialSessions != null) {
      _sessions.addAll(initialSessions);
    }
    if (initialUploads != null) {
      _uploads.addAll(initialUploads);
    }
    if (performCrashRecovery) {
      _recoverFromCrash();
    }
  }

  void _recoverFromCrash() {
    for (final entry in _uploads.entries.toList()) {
      if (entry.value.status == UploadStatus.uploading) {
        _uploads[entry.key] = entry.value.copyWith(status: UploadStatus.waiting);
      }
    }
  }

  @override
  Future<void> replacePatients(List<Patient> patients) async {
    _patients.clear();
    for (final patient in patients) {
      _patients[patient.id] = patient;
    }
  }

  @override
  Future<void> upsertPatients(List<Patient> patients) async {
    for (final incoming in patients) {
      final existing = _patients[incoming.id];
      if (existing == null) {
        _patients[incoming.id] = incoming;
      } else {
        _patients[incoming.id] = Patient.merge(existing, incoming);
      }
    }
  }

  @override
  Future<Patient?> getPatient(String id) async {
    return _patients[id];
  }

  @override
  Future<List<Patient>> getPatients() async {
    final list = _patients.values.toList();
    list.sort((a, b) => a.id.compareTo(b.id));
    return list;
  }

  @override
  Future<List<Patient>> searchPatients(
    String query, {
    SearchFilterMode mode = SearchFilterMode.all,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return getPatients();
    }
    final lower = trimmed.toLowerCase();
    final normPhone = Patient.normalizePhone(trimmed);

    final matches = _patients.values.where((p) {
      final matchesId = p.id.toLowerCase().contains(lower);
      final matchesName = p.name.toLowerCase().contains(lower);
      final matchesPhone = (p.phoneNumber != null && p.phoneNumber!.toLowerCase().contains(lower)) ||
          (normPhone != null && p.phoneNumberNormalized != null && p.phoneNumberNormalized!.contains(normPhone));

      return switch (mode) {
        SearchFilterMode.all => matchesId || matchesName || matchesPhone,
        SearchFilterMode.name => matchesName,
        SearchFilterMode.phone => matchesPhone,
        SearchFilterMode.patientId => matchesId,
      };
    }).toList();

    matches.sort((a, b) => a.id.compareTo(b.id));
    return matches;
  }

  // --- Sessions Operations ---

  @override
  Future<void> insertSession(CaptureSession session) async {
    _sessions[session.id] = session;
  }

  @override
  Future<CaptureSession?> getSession(String id) async {
    final session = _sessions[id];
    if (session == null) return null;
    final count = _uploads.values.where((u) => u.sessionId == id).length;
    return session.copyWith(photoCount: count);
  }

  @override
  Future<List<CaptureSession>> getUnassignedSessions() async {
    final list = _sessions.values
        .where((s) => s.status == 'unassigned')
        .map((s) {
          final count = _uploads.values.where((u) => u.sessionId == s.id).length;
          return s.copyWith(photoCount: count);
        })
        .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Future<int> getUnassignedSessionsCount() async {
    return _sessions.values.where((s) => s.status == 'unassigned').length;
  }

  @override
  Future<void> updateSession(CaptureSession session) async {
    _sessions[session.id] = session;
  }

  @override
  Future<void> deleteSession(String id) async {
    _sessions.remove(id);
  }

  @override
  Future<List<UploadItem>> getUploadsForSession(String sessionId) async {
    final list = _uploads.values.where((u) => u.sessionId == sessionId).toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  @override
  Future<void> updatePatient(Patient patient) async {
    _patients[patient.id] = patient;
  }

  @override
  Future<void> assignSessionToPatient({
    required String sessionId,
    required String patientId,
    required String driveFolderId,
    Map<String, ({String fileName, String localPath})>? renamedPhotos,
  }) async {
    final session = _sessions[sessionId];
    if (session != null) {
      _sessions[sessionId] = session.copyWith(
        patientId: patientId,
        status: 'assigned',
      );
    }
    for (final entry in _uploads.entries.toList()) {
      if (entry.value.sessionId == sessionId) {
        final rename = renamedPhotos?[entry.key];
        _uploads[entry.key] = entry.value.copyWith(
          patientId: patientId,
          driveFolderId: driveFolderId,
          fileName: rename?.fileName,
          localPath: rename?.localPath,
          status: UploadStatus.waiting,
        );
      }
    }
  }

  // --- Upload Queue Operations ---

  @override
  Future<void> insertUpload(UploadItem item) async {
    _uploads[item.id] = item;
  }

  @override
  Future<void> updateUpload(UploadItem item) async {
    _uploads[item.id] = item;
  }

  @override
  Future<void> deleteUpload(String id) async {
    _uploads.remove(id);
  }

  @override
  Future<void> deleteUploads(List<String> ids) async {
    for (final id in ids) {
      _uploads.remove(id);
    }
  }

  @override
  Future<UploadItem?> getNextPendingUpload() async {
    final waiting = _uploads.values
        .where((u) => u.status == UploadStatus.waiting)
        .toList();
    if (waiting.isEmpty) return null;
    waiting.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return waiting.first;
  }

  @override
  Future<int> getActiveUploadsCount() async {
    return _uploads.values
        .where((u) =>
            u.status == UploadStatus.waiting ||
            u.status == UploadStatus.uploading)
        .length;
  }

  @override
  Future<int> getFailedUploadsCount() async {
    return _uploads.values.where((u) => u.status == UploadStatus.failed).length;
  }

  @override
  Future<void> resetFailedToWaiting() async {
    for (final entry in _uploads.entries.toList()) {
      if (entry.value.status == UploadStatus.failed) {
        _uploads[entry.key] = entry.value.copyWith(
          status: UploadStatus.waiting,
          retryCount: 0,
          clearLastError: true,
        );
      }
    }
  }

  @override
  Future<List<UploadItem>> getAllUploads() async {
    final list = _uploads.values.toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  Map<String, UploadItem> dumpUploads() => Map.from(_uploads);
  Map<String, CaptureSession> dumpSessions() => Map.from(_sessions);
  Map<String, Patient> dumpPatients() => Map.from(_patients);

  @override
  Future<void> close() async {
    // In-memory cleanup
  }
}
