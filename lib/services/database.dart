import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
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
  /// DEPRECATED: Do not call in production Sheet sync paths (use [upsertPatients]).
  /// Retained only for legacy unit test setups.
  @Deprecated('Use upsertPatients instead for safe synchronization')
  Future<void> replacePatients(List<Patient> patients);

  /// Upserts a batch of patients (used during incremental sync and deduplication).
  Future<void> upsertPatients(List<Patient> patients);

  /// Retrieves a single patient by ID (UUID or legacy patient ID).
  Future<Patient?> getPatient(String id);

  /// Retrieves a patient by exact business identity (normalized name + normalized phone).
  Future<Patient?> getPatientByBusinessIdentity(String normalizedName, String? normalizedPhone);

  /// Retrieves all cached patients sorted by name.
  Future<List<Patient>> getPatients();

  /// Search patients with optional filter mode (All, Name, Phone, Patient ID).
  Future<List<Patient>> searchPatients(
    String query, {
    SearchFilterMode mode = SearchFilterMode.all,
  });

  /// Links an external source ID (e.g. 'google_sheets' -> '1000048') to a patient UUID.
  Future<void> linkPatientSource({
    required String patientId,
    required String source,
    required String externalId,
  });

  /// Links multiple external source mappings in a single batch.
  Future<void> linkPatientSources(
    List<({String patientId, String source, String externalId})> sources,
  );

  /// Resolves a patient UUID given an external source identifier.
  Future<String?> getPatientIdBySource({
    required String source,
    required String externalId,
  });

  /// Gets all source mappings for a patient UUID.
  Future<List<Map<String, String>>> getSourcesForPatient(String patientId);

  /// Retrieves all external source mappings in the local database.
  Future<List<Map<String, String>>> getAllPatientSources();

  /// Gets all uploads (local photo records) belonging to a given patient.
  Future<List<UploadItem>> getUploadsForPatient(String patientId);

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

  /// Atomically updates a patient's primary ID from [oldId] to [newId] across patients,
  /// uploads, capture_sessions, and patient_sources.
  Future<void> updatePatientId({required String oldId, required String newId});

  /// Safely inspects existing local SQLite patients with unusable names (e.g. "Name unavailable", empty, placeholder):
  /// - Distinguishes doctor-created patients vs stale Google Sheet imports.
  /// - Determines whether they have clinical photos (in uploads) or capture sessions.
  /// - Determines whether they have an established Google Drive folder.
  /// - Hard invariant: NEVER deletes doctor-created patients.
  /// - Hard invariant: NEVER deletes patients with photos, capture sessions, or Drive folders.
  /// - Only removes confirmed stale Sheet-imported records that have NO photos, NO sessions, and NO Drive folder.
  Future<int> reconcileStalePlaceholderPatients();

  /// Atomically assigns an unassigned session and all its photos to a patient.
  Future<void> assignSessionToPatient({
    required String sessionId,
    required String patientId,
    String? driveFolderId,
    Map<String, ({String fileName, String localPath})>? renamedPhotos,
  });

  /// Deletes a patient locally from SQLite along with local source mappings,
  /// sessions, and upload queue items. Does NOT touch Google Drive.
  Future<void> deletePatient(String id);

  /// Adds a pending cloud deletion for a patient ID.
  Future<void> addPendingDeletion(String patientId);

  /// Retrieves all pending patient IDs waiting for cloud deletion.
  Future<List<String>> getPendingDeletions();

  /// Removes a resolved pending deletion.
  Future<void> removePendingDeletion(String patientId);

  /// Records a tombstone for a deleted patient and their external source mappings
  /// to prevent Sheets sync from resurrecting the patient.
  Future<void> recordDeletedTombstone({
    required String patientId,
    String? source,
    String? externalId,
  });

  /// Checks if an external source mapping was previously deleted.
  Future<bool> isSourceDeleted({
    required String source,
    required String externalId,
  });

  /// Checks if a patient UUID was previously deleted.
  Future<bool> isPatientDeleted(String patientId);

  /// Retrieves all deleted tombstone source keys ("$source:$externalId") for fast in-memory checking.
  Future<Set<String>> getAllDeletedTombstoneSources();

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

  /// Retrieves an upload item by its Google Drive file ID.
  Future<UploadItem?> getUploadByDriveFileId(String driveFileId);

  /// Retrieves an upload item by its file name.
  Future<UploadItem?> getUploadByFileName(String fileName);

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
  static const int _dbVersion = 9;

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
              display_name TEXT NOT NULL,
              normalized_name TEXT NOT NULL,
              phone_display TEXT,
              normalized_phone TEXT,
              legacy_patient_id TEXT,
              source TEXT NOT NULL,
              drive_folder_id TEXT,
              folder_status TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT,
              sync_status TEXT DEFAULT 'synced',
              name TEXT,
              phone_number TEXT,
              phone_number_normalized TEXT
            )
          ''');

          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_patients_status ON patients(folder_status)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_patients_business_id ON patients(normalized_name, normalized_phone)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_patients_legacy_id ON patients(legacy_patient_id)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_patients_search ON patients(normalized_name, normalized_phone)',
          );

          await db.execute('''
            CREATE TABLE capture_sessions (
              id TEXT PRIMARY KEY,
              patient_id TEXT,
              drive_folder_id TEXT,
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
              drive_parent_folder_id TEXT,
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
          await db.execute('''
            CREATE TABLE IF NOT EXISTS patient_sources (
              id TEXT PRIMARY KEY,
              patient_id TEXT NOT NULL,
              source TEXT NOT NULL,
              external_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE
            )
          ''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_patient_sources_patient_id ON patient_sources(patient_id)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_patient_sources_source_ext ON patient_sources(source, external_id)',
          );

          await db.execute('''
            CREATE TABLE IF NOT EXISTS pending_deletions (
              patient_id TEXT PRIMARY KEY,
              deleted_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS deleted_patient_tombstones (
              id TEXT PRIMARY KEY,
              patient_id TEXT NOT NULL,
              source TEXT,
              external_id TEXT,
              deleted_at TEXT NOT NULL
            )
          ''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_deleted_tombstones_source_ext ON deleted_patient_tombstones(source, external_id)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_deleted_tombstones_patient_id ON deleted_patient_tombstones(patient_id)',
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
          }

          if (oldVersion < 7) {
            await _migrateToV7(db);
          }

          if (oldVersion < 8) {
            await _migrateToV8(db);
          }

          if (oldVersion < 9) {
            await _migrateToV9(db);
          }
        },
        onOpen: (db) async {
          // Ensure schema compatibility on existing databases
          await _migrateToV7(db);
          await _migrateToV8(db);
          await _migrateToV9(db);
          await _migrateLegacyNonUuidPatients(db);
          await _reconcileStalePlaceholderPatients(db);
          await _ensureUploadsTableSchema(db);

          // Crash recovery: Any upload that was interrupted in 'uploading'
          // status is reset to 'waiting' so processing will resume cleanly.
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
  /// or if folder_status, updated_at, phone_number, or phone_number_normalized are missing (v5 -> v6).
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

  /// Visible for unit testing legacy schema migration.
  @visibleForTesting
  static Future<void> ensurePatientsTableSchemaForTesting(Database db) =>
      _ensurePatientsTableSchema(db);

  /// Migrates older database versions to Schema v7:
  /// - Introduces local UUIDs as primary key while copying numeric IDs to legacy_patient_id
  /// - Normalizes names and phones
  /// - Adds source column ('clinic_sheet' | 'doctor_created' | 'merged')
  /// - Maps uploads.patient_id and capture_sessions.patient_id to new UUIDs
  /// - Adds drive_folder_id to capture_sessions and drive_parent_folder_id to uploads
  static Future<void> _migrateToV7(Database db) async {
    final tableInfo = await db.rawQuery("PRAGMA table_info(patients)");
    if (tableInfo.isEmpty) return;

    final hasDisplayName = tableInfo.any((c) => c['name'] == 'display_name');
    final hasSource = tableInfo.any((c) => c['name'] == 'source');
    final hasLegacyId = tableInfo.any((c) => c['name'] == 'legacy_patient_id');

    if (!hasDisplayName || !hasSource || !hasLegacyId) {
      await db.transaction((txn) async {
        final oldPatients = await txn.query('patients');
        final Map<String, String> oldIdToNewUuid = {};
        const uuidGen = Uuid();

        await txn.execute('ALTER TABLE patients RENAME TO _patients_old_v6');
        await txn.execute('''
          CREATE TABLE patients (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            normalized_name TEXT NOT NULL,
            phone_display TEXT,
            normalized_phone TEXT,
            legacy_patient_id TEXT,
            source TEXT NOT NULL,
            drive_folder_id TEXT,
            folder_status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT,
            name TEXT,
            phone_number TEXT,
            phone_number_normalized TEXT
          )
        ''');

        for (final row in oldPatients) {
          final oldId = row['id']?.toString() ?? '';
          final oldName = (row['name'] ?? row['display_name'] ?? '').toString();
          final oldPhone = (row['phone_display'] ?? row['phone_number'])?.toString();
          final cleanP = Patient.cleanPhone(oldPhone);
          final normP = Patient.normalizePhone(cleanP);
          final normName = Patient.normalizeName(oldName);
          final driveFolderId = row['drive_folder_id']?.toString();
          final folderStatus = row['folder_status']?.toString() ?? 'available';
          final updatedAt = row['updated_at']?.toString();
          final createdAt = row['created_at']?.toString() ?? (updatedAt ?? DateTime.now().toIso8601String());

          final isUuid = oldId.contains('-');
          final newId = isUuid ? oldId : uuidGen.v4();
          final legacyId = isUuid ? (row['legacy_patient_id']?.toString()) : oldId;

          if (!isUuid && oldId.isNotEmpty) {
            oldIdToNewUuid[oldId] = newId;
          }

          await txn.insert('patients', {
            'id': newId,
            'display_name': oldName.isNotEmpty ? oldName : 'Name unavailable',
            'normalized_name': normName,
            'phone_display': cleanP,
            'normalized_phone': normP,
            'legacy_patient_id': legacyId,
            'source': 'clinic_sheet',
            'drive_folder_id': driveFolderId,
            'folder_status': folderStatus,
            'created_at': createdAt,
            'updated_at': updatedAt,
            'name': oldName,
            'phone_number': cleanP,
            'phone_number_normalized': normP,
          });
        }

        await txn.execute('DROP TABLE _patients_old_v6');

        await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_patients_status ON patients(folder_status)',
        );
        await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_patients_business_id ON patients(normalized_name, normalized_phone)',
        );
        await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_patients_legacy_id ON patients(legacy_patient_id)',
        );
        await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_patients_search ON patients(normalized_name, normalized_phone)',
        );

        // Ensure capture_sessions table exists and has drive_folder_id
        final sessionsInfo = await txn.rawQuery("PRAGMA table_info(capture_sessions)");
        if (sessionsInfo.isNotEmpty) {
          final hasSessionDriveFolder = sessionsInfo.any((c) => c['name'] == 'drive_folder_id');
          if (!hasSessionDriveFolder) {
            try {
              await txn.execute('ALTER TABLE capture_sessions ADD COLUMN drive_folder_id TEXT');
            } catch (_) {}
          }
          for (final entry in oldIdToNewUuid.entries) {
            await txn.update(
              'capture_sessions',
              {'patient_id': entry.value},
              where: 'patient_id = ?',
              whereArgs: [entry.key],
            );
          }
        }

        // Ensure uploads table updates patient_id and has drive_parent_folder_id
        final uploadsInfo = await txn.rawQuery("PRAGMA table_info(uploads)");
        if (uploadsInfo.isNotEmpty) {
          final hasDriveParentFolder = uploadsInfo.any((c) => c['name'] == 'drive_parent_folder_id');
          if (!hasDriveParentFolder) {
            try {
              await txn.execute('ALTER TABLE uploads ADD COLUMN drive_parent_folder_id TEXT');
              await txn.execute('UPDATE uploads SET drive_parent_folder_id = drive_folder_id');
            } catch (_) {}
          }
          for (final entry in oldIdToNewUuid.entries) {
            await txn.update(
              'uploads',
              {'patient_id': entry.value},
              where: 'patient_id = ?',
              whereArgs: [entry.key],
            );
          }
        }
      });
    }
  }

  /// Visible for unit testing V7 schema migration.
  @visibleForTesting
  static Future<void> migrateToV7ForTesting(Database db) =>
      _migrateToV7(db);

  /// Migrates uploads table if columns are missing or malformed.
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
    final hasParentFolder = tableInfo.any((c) => c['name'] == 'drive_parent_folder_id');

    final isPatientIdNotNull = patientIdCol['notnull'] == 1;
    final needsMigration = isPatientIdNotNull || !hasSessionId || !hasCapturedAt || !hasSeq || !hasParentFolder;

    if (needsMigration) {
      await db.transaction((txn) async {
        await txn.execute('ALTER TABLE uploads RENAME TO _uploads_old');
        await txn.execute('''
          CREATE TABLE uploads (
            id TEXT PRIMARY KEY,
            session_id TEXT,
            patient_id TEXT,
            drive_folder_id TEXT,
            drive_parent_folder_id TEXT,
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
        final oldHasParent = oldColumns.any((c) => c['name'] == 'drive_parent_folder_id');

        final selectSessionId = oldHasSessionId ? "session_id" : "NULL";
        final selectCapturedAt = oldHasCapturedAt ? "captured_at" : "created_at";
        final selectSeq = oldHasSeq ? "sequence_number" : "1";
        final selectParent = oldHasParent ? "drive_parent_folder_id" : "drive_folder_id";

        await txn.execute('''
          INSERT INTO uploads (id, session_id, patient_id, drive_folder_id, drive_parent_folder_id, local_path, file_name, status, retry_count, last_error, drive_file_id, created_at, captured_at, sequence_number)
          SELECT id, $selectSessionId, patient_id, drive_folder_id, $selectParent, local_path, file_name, status, retry_count, last_error, drive_file_id, created_at, $selectCapturedAt, $selectSeq
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

  /// Migrates older database versions to Schema v8:
  /// - Ensures sync_status column exists in patients table
  /// - Creates patient_sources table for mapping external IDs to canonical UUIDs
  /// - Migrates existing legacy_patient_id records into patient_sources
  static Future<void> _migrateToV8(Database db) async {
    final patientInfo = await db.rawQuery("PRAGMA table_info(patients)");
    if (patientInfo.isNotEmpty) {
      final hasSyncStatus = patientInfo.any((c) => c['name'] == 'sync_status');
      if (!hasSyncStatus) {
        try {
          await db.execute("ALTER TABLE patients ADD COLUMN sync_status TEXT DEFAULT 'synced'");
        } catch (_) {}
      }
    }

    await db.execute('''
      CREATE TABLE IF NOT EXISTS patient_sources (
        id TEXT PRIMARY KEY,
        patient_id TEXT NOT NULL,
        source TEXT NOT NULL,
        external_id TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_patient_sources_patient_id ON patient_sources(patient_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_patient_sources_source_ext ON patient_sources(source, external_id)',
    );

    final legacyPatients = await db.query(
      'patients',
      columns: ['id', 'legacy_patient_id', 'created_at'],
      where: "legacy_patient_id IS NOT NULL AND legacy_patient_id != ''",
    );
    const uuidGen = Uuid();
    for (final row in legacyPatients) {
      final pId = row['id']?.toString() ?? '';
      final legId = row['legacy_patient_id']?.toString() ?? '';
      final createdAt = row['created_at']?.toString() ?? DateTime.now().toIso8601String();
      if (pId.isNotEmpty && legId.isNotEmpty) {
        final existing = await db.query(
          'patient_sources',
          where: 'source = ? AND external_id = ?',
          whereArgs: ['google_sheets', legId],
          limit: 1,
        );
        if (existing.isEmpty) {
          await db.insert('patient_sources', {
            'id': uuidGen.v4(),
            'patient_id': pId,
            'source': 'google_sheets',
            'external_id': legId,
            'created_at': createdAt,
          });
        }
      }
    }
  }

  /// Migrates older database versions to Schema v9:
  /// - Creates pending_deletions table for offline deletion queue
  /// - Creates deleted_patient_tombstones table for Sheets reconciliation resurrection prevention
  static Future<void> _migrateToV9(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_deletions (
        patient_id TEXT PRIMARY KEY,
        deleted_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS deleted_patient_tombstones (
        id TEXT PRIMARY KEY,
        patient_id TEXT NOT NULL,
        source TEXT,
        external_id TEXT,
        deleted_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_deleted_tombstones_source_ext ON deleted_patient_tombstones(source, external_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_deleted_tombstones_patient_id ON deleted_patient_tombstones(patient_id)',
    );
  }

  /// Migrates any legacy patients that have non-UUID primary keys (e.g. numeric Sheet IDs like '1000001')
  /// to valid UUIDs while preserving all foreign keys in uploads, capture_sessions, and patient_sources.
  static Future<void> _migrateLegacyNonUuidPatients(Database db) async {
    final rows = await db.rawQuery(
      "SELECT * FROM patients WHERE id NOT LIKE '%-%' OR length(id) != 36",
    );
    if (rows.isEmpty) return;

    final uuidGen = const Uuid();
    for (final row in rows) {
      final oldId = row['id']?.toString() ?? '';
      if (oldId.isEmpty) continue;

      final oldName = (row['display_name'] ?? row['name'] ?? '').toString();
      final hasUsable = Patient.isUsableName(oldName, oldId);

      // Check if patient has any uploads or capture sessions
      final uploadCount = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM uploads WHERE patient_id = ?',
        [oldId],
      )) ?? 0;
      final sessionCount = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM capture_sessions WHERE patient_id = ?',
        [oldId],
      )) ?? 0;

      if (!hasUsable && uploadCount == 0 && sessionCount == 0) {
        // Discard unusable placeholder rows that have zero photos and zero sessions
        await db.delete('patients', where: 'id = ?', whereArgs: [oldId]);
        continue;
      }

      // Legitimate patient or patient with photos: assign a new UUID
      final newUuid = uuidGen.v4();
      final legacyId = (row['legacy_patient_id'] != null && row['legacy_patient_id'].toString().isNotEmpty)
          ? row['legacy_patient_id'].toString()
          : oldId;

      await db.transaction((txn) async {
        // 1. Update patient record
        await txn.update(
          'patients',
          {
            'id': newUuid,
            'legacy_patient_id': legacyId,
            'sync_status': 'pending_cloud',
          },
          where: 'id = ?',
          whereArgs: [oldId],
        );

        // 2. Update foreign keys in uploads and capture_sessions
        await txn.update(
          'uploads',
          {'patient_id': newUuid},
          where: 'patient_id = ?',
          whereArgs: [oldId],
        );
        await txn.update(
          'capture_sessions',
          {'patient_id': newUuid},
          where: 'patient_id = ?',
          whereArgs: [oldId],
        );

        // 3. Ensure patient_sources mapping exists
        final existingSources = await txn.query(
          'patient_sources',
          where: 'source = ? AND external_id = ?',
          whereArgs: ['google_sheets', legacyId],
        );
        if (existingSources.isEmpty) {
          await txn.insert('patient_sources', {
            'id': uuidGen.v4(),
            'patient_id': newUuid,
            'source': 'google_sheets',
            'external_id': legacyId,
            'created_at': DateTime.now().toIso8601String(),
          });
        } else {
          await txn.update(
            'patient_sources',
            {'patient_id': newUuid},
            where: 'source = ? AND external_id = ?',
            whereArgs: ['google_sheets', legacyId],
          );
        }
      });
    }

    // Fix any remaining patient_sources rows that pointed to non-UUIDs
    final legacySources = await db.rawQuery(
      "SELECT id, patient_id FROM patient_sources WHERE patient_id NOT LIKE '%-%' OR length(patient_id) != 36",
    );
    for (final s in legacySources) {
      final sId = s['id']?.toString();
      final pId = s['patient_id']?.toString() ?? '';
      final mappedPatient = await db.query(
        'patients',
        columns: ['id'],
        where: 'legacy_patient_id = ?',
        whereArgs: [pId],
        limit: 1,
      );
      if (mappedPatient.isNotEmpty && sId != null) {
        final newPatientId = mappedPatient.first['id']?.toString();
        if (newPatientId != null && Patient.isValidUuid(newPatientId)) {
          await db.update(
            'patient_sources',
            {'patient_id': newPatientId},
            where: 'id = ?',
            whereArgs: [sId],
          );
        }
      }
    }
  }

  /// Visible for unit testing legacy non-UUID patients migration.
  @visibleForTesting
  static Future<void> migrateLegacyNonUuidPatientsForTesting(Database db) =>
      _migrateLegacyNonUuidPatients(db);

  /// Safely inspects existing local SQLite patients with unusable names (e.g. "Name unavailable", empty, placeholder):
  /// - Distinguishes doctor-created patients vs stale Google Sheet imports.
  /// - Determines whether they have clinical photos (in uploads) or capture sessions.
  /// - Determines whether they have an established Google Drive folder.
  /// - Hard invariant: NEVER deletes doctor-created patients.
  /// - Hard invariant: NEVER deletes patients with photos, capture sessions, or Drive folders.
  /// - Only removes confirmed stale Sheet-imported records that have NO photos, NO sessions, and NO Drive folder.
  static Future<int> _reconcileStalePlaceholderPatients(Database db) async {
    final rows = await db.query('patients');
    int cleanedCount = 0;
    for (final row in rows) {
      final id = row['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      final name = (row['display_name'] ?? row['name'] ?? '').toString();
      final legacyId = row['legacy_patient_id']?.toString();
      final isUsable = Patient.isUsableName(name, id, legacyId);

      if (isUsable) continue;

      final source = row['source']?.toString() ?? '';
      final isDoctorCreated = source == PatientSource.doctorCreated.name ||
          source == 'doctorCreated' ||
          source == 'doctor_created';

      // 1. Manually-created doctor patients must NEVER be deleted
      if (isDoctorCreated) continue;

      // 2. Check for associated photos (uploads)
      final uploadCount = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM uploads WHERE patient_id = ?',
        [id],
      )) ?? 0;

      // 3. Check for associated capture sessions
      final sessionCount = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM capture_sessions WHERE patient_id = ?',
        [id],
      )) ?? 0;

      // 4. Check for Google Drive folder
      final driveFolderId = row['drive_folder_id']?.toString() ?? '';

      // If patient has photos, sessions, or a Drive folder, PRESERVE them!
      if (uploadCount > 0 || sessionCount > 0 || driveFolderId.isNotEmpty) {
        continue;
      }

      // 5. Confirmed stale Sheet import record with no useful identity, no photos, no sessions, no Drive folder:
      // Remove safely from patients and patient_sources
      await db.transaction((txn) async {
        await txn.delete('patient_sources', where: 'patient_id = ?', whereArgs: [id]);
        await txn.delete('patients', where: 'id = ?', whereArgs: [id]);
      });
      cleanedCount++;
    }
    return cleanedCount;
  }

  @override
  Future<int> reconcileStalePlaceholderPatients() =>
      _reconcileStalePlaceholderPatients(db);

  /// Visible for unit testing stale placeholder patients reconciliation.
  @visibleForTesting
  static Future<int> reconcileStalePlaceholderPatientsForTesting(Database db) =>
      _reconcileStalePlaceholderPatients(db);

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
        // 1. Check exact UUID match
        List<Map<String, dynamic>> existingRows = await txn.query(
          'patients',
          where: 'id = ?',
          whereArgs: [incoming.id],
          limit: 1,
        );

        // 2. Check exact business identity match: (normalized_name, normalized_phone)
        if (existingRows.isEmpty &&
            incoming.normalizedPhone != null &&
            incoming.normalizedPhone!.isNotEmpty) {
          existingRows = await txn.query(
            'patients',
            where: 'normalized_name = ? AND normalized_phone = ?',
            whereArgs: [incoming.normalizedName, incoming.normalizedPhone],
            limit: 1,
          );
        }

        // 3. Check legacy_patient_id or legacy ID match if incoming has one
        if (existingRows.isEmpty &&
            incoming.legacyPatientId != null &&
            incoming.legacyPatientId!.isNotEmpty) {
          existingRows = await txn.query(
            'patients',
            where: 'legacy_patient_id = ? OR id = ?',
            whereArgs: [incoming.legacyPatientId, incoming.legacyPatientId],
            limit: 1,
          );
        }

        if (existingRows.isEmpty) {
          await txn.insert(
            'patients',
            incoming.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        } else {
          final existing = Patient.fromMap(existingRows.first);
          final canonicalId = (!Patient.isValidUuid(existing.id) && Patient.isValidUuid(incoming.id))
              ? incoming.id
              : existing.id;
          final merged = Patient.merge(existing, incoming).copyWith(id: canonicalId);

          if (existing.id != canonicalId) {
            await txn.delete('patients', where: 'id = ?', whereArgs: [existing.id]);
            await txn.insert('patients', merged.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
            await txn.update('uploads', {'patient_id': canonicalId}, where: 'patient_id = ?', whereArgs: [existing.id]);
            await txn.update('capture_sessions', {'patient_id': canonicalId}, where: 'patient_id = ?', whereArgs: [existing.id]);
            await txn.update('patient_sources', {'patient_id': canonicalId}, where: 'patient_id = ?', whereArgs: [existing.id]);
          } else {
            await txn.update(
              'patients',
              merged.toMap(),
              where: 'id = ?',
              whereArgs: [canonicalId],
            );
          }
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
    if (rows.isNotEmpty) {
      return Patient.fromMap(rows.first);
    }

    // Lookup by source mapping (e.g. Google Sheets external ID)
    final sourceRows = await db.query(
      'patient_sources',
      columns: ['patient_id'],
      where: 'external_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (sourceRows.isNotEmpty) {
      final pId = sourceRows.first['patient_id']?.toString();
      if (pId != null) {
        final p = await getPatient(pId);
        if (p != null) return p;
      }
    }

    // Fallback for lookup by legacy spreadsheet ID
    final legacyRows = await db.query(
      'patients',
      where: 'legacy_patient_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (legacyRows.isNotEmpty) {
      return Patient.fromMap(legacyRows.first);
    }

    return null;
  }

  @override
  Future<void> linkPatientSource({
    required String patientId,
    required String source,
    required String externalId,
  }) async {
    final existing = await db.query(
      'patient_sources',
      where: 'source = ? AND external_id = ?',
      whereArgs: [source, externalId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      await db.update(
        'patient_sources',
        {'patient_id': patientId},
        where: 'source = ? AND external_id = ?',
        whereArgs: [source, externalId],
      );
    } else {
      await db.insert('patient_sources', {
        'id': const Uuid().v4(),
        'patient_id': patientId,
        'source': source,
        'external_id': externalId,
        'created_at': DateTime.now().toIso8601String(),
      });
    }
  }

  @override
  Future<String?> getPatientIdBySource({
    required String source,
    required String externalId,
  }) async {
    final rows = await db.query(
      'patient_sources',
      columns: ['patient_id'],
      where: 'source = ? AND external_id = ?',
      whereArgs: [source, externalId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final pId = rows.first['patient_id']?.toString();
      if (pId != null && Patient.isValidUuid(pId)) {
        return pId;
      }
    }
    return null;
  }

  @override
  Future<List<Map<String, String>>> getSourcesForPatient(String patientId) async {
    final rows = await db.query(
      'patient_sources',
      columns: ['source', 'external_id'],
      where: 'patient_id = ?',
      whereArgs: [patientId],
    );
    return rows.map((r) => {
      'source': r['source']?.toString() ?? '',
      'external_id': r['external_id']?.toString() ?? '',
    }).toList();
  }

  @override
  Future<void> linkPatientSources(
    List<({String patientId, String source, String externalId})> sources,
  ) async {
    if (sources.isEmpty) return;
    const uuidGen = Uuid();
    final nowIso = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      for (final s in sources) {
        final existing = await txn.query(
          'patient_sources',
          columns: ['id'],
          where: 'source = ? AND external_id = ?',
          whereArgs: [s.source, s.externalId],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          await txn.update(
            'patient_sources',
            {'patient_id': s.patientId},
            where: 'source = ? AND external_id = ?',
            whereArgs: [s.source, s.externalId],
          );
        } else {
          await txn.insert('patient_sources', {
            'id': uuidGen.v4(),
            'patient_id': s.patientId,
            'source': s.source,
            'external_id': s.externalId,
            'created_at': nowIso,
          });
        }
      }
    });
  }

  @override
  Future<List<Map<String, String>>> getAllPatientSources() async {
    final rows = await db.query(
      'patient_sources',
      columns: ['patient_id', 'source', 'external_id'],
    );
    return rows.map((r) => {
      'patient_id': r['patient_id']?.toString() ?? '',
      'source': r['source']?.toString() ?? '',
      'external_id': r['external_id']?.toString() ?? '',
    }).toList();
  }

  @override
  Future<List<UploadItem>> getUploadsForPatient(String patientId) async {
    final rows = await db.query(
      'uploads',
      where: 'patient_id = ?',
      whereArgs: [patientId],
      orderBy: 'captured_at DESC, created_at DESC',
    );
    return rows.map(UploadItem.fromMap).toList();
  }

  @override
  Future<Patient?> getPatientByBusinessIdentity(String normalizedName, String? normalizedPhone) async {
    if (normalizedPhone == null || normalizedPhone.isEmpty) return null;
    final rows = await db.query(
      'patients',
      where: 'normalized_name = ? AND normalized_phone = ?',
      whereArgs: [normalizedName, normalizedPhone],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Patient.fromMap(rows.first);
  }

  @override
  Future<List<Patient>> getPatients() async {
    final rows = await db.query(
      'patients',
      orderBy: 'display_name COLLATE NOCASE ASC, name COLLATE NOCASE ASC',
    );
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
        whereClause = 'normalized_name LIKE ? OR LOWER(display_name) LIKE ?';
        whereArgs = ['%$lower%', '%$lower%'];
        break;
      case SearchFilterMode.patientId:
        whereClause = 'LOWER(id) LIKE ? OR legacy_patient_id LIKE ?';
        whereArgs = ['%$lower%', '%$lower%'];
        break;
      case SearchFilterMode.phone:
        if (normPhone != null) {
          whereClause = 'normalized_phone LIKE ? OR phone_display LIKE ?';
          whereArgs = ['%$normPhone%', '%$trimmed%'];
        } else {
          whereClause = 'phone_display LIKE ?';
          whereArgs = ['%$trimmed%'];
        }
        break;
      case SearchFilterMode.all:
        if (normPhone != null) {
          whereClause =
              'normalized_name LIKE ? OR LOWER(display_name) LIKE ? OR normalized_phone LIKE ? OR phone_display LIKE ? OR legacy_patient_id LIKE ? OR LOWER(id) LIKE ?';
          whereArgs = ['%$lower%', '%$lower%', '%$normPhone%', '%$trimmed%', '%$lower%', '%$lower%'];
        } else {
          whereClause =
              'normalized_name LIKE ? OR LOWER(display_name) LIKE ? OR phone_display LIKE ? OR legacy_patient_id LIKE ? OR LOWER(id) LIKE ?';
          whereArgs = ['%$lower%', '%$lower%', '%$trimmed%', '%$lower%', '%$lower%'];
        }
        break;
    }

    final rows = await db.query(
      'patients',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'display_name COLLATE NOCASE ASC, name COLLATE NOCASE ASC',
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

    final session = CaptureSession.fromMap(rows.first);
    final count = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM uploads WHERE session_id = ?',
      [id],
    ));

    return session.copyWith(photoCount: count ?? 0);
  }

  @override
  Future<List<CaptureSession>> getUnassignedSessions() async {
    final rows = await db.rawQuery('''
      SELECT s.id, s.patient_id, s.drive_folder_id, s.created_at, s.status,
             COUNT(u.id) as photo_count
      FROM capture_sessions s
      LEFT JOIN uploads u ON s.id = u.session_id
      WHERE s.status = 'unassigned'
      GROUP BY s.id
      ORDER BY s.created_at DESC
    ''');

    return rows.map((r) => CaptureSession.fromMap(r)).toList();
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
  Future<void> updatePatientId({required String oldId, required String newId}) async {
    await db.transaction((txn) async {
      await txn.update('patients', {'id': newId}, where: 'id = ?', whereArgs: [oldId]);
      await txn.update('uploads', {'patient_id': newId}, where: 'patient_id = ?', whereArgs: [oldId]);
      await txn.update('capture_sessions', {'patient_id': newId}, where: 'patient_id = ?', whereArgs: [oldId]);
      await txn.update('patient_sources', {'patient_id': newId}, where: 'patient_id = ?', whereArgs: [oldId]);
    });
  }

  @override
  Future<void> deletePatient(String id) async {
    await db.transaction((txn) async {
      await txn.delete('uploads', where: 'patient_id = ?', whereArgs: [id]);
      await txn.delete('capture_sessions', where: 'patient_id = ?', whereArgs: [id]);
      await txn.delete('patient_sources', where: 'patient_id = ?', whereArgs: [id]);
      await txn.delete('patients', where: 'id = ?', whereArgs: [id]);
    });
  }

  @override
  Future<void> addPendingDeletion(String patientId) async {
    await db.insert(
      'pending_deletions',
      {
        'patient_id': patientId,
        'deleted_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<String>> getPendingDeletions() async {
    final rows = await db.query('pending_deletions');
    return rows.map((r) => r['patient_id'].toString()).toList();
  }

  @override
  Future<void> removePendingDeletion(String patientId) async {
    await db.delete(
      'pending_deletions',
      where: 'patient_id = ?',
      whereArgs: [patientId],
    );
  }

  @override
  Future<void> recordDeletedTombstone({
    required String patientId,
    String? source,
    String? externalId,
  }) async {
    await db.insert('deleted_patient_tombstones', {
      'id': const Uuid().v4(),
      'patient_id': patientId,
      'source': source,
      'external_id': externalId,
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  @override
  Future<bool> isSourceDeleted({
    required String source,
    required String externalId,
  }) async {
    final rows = await db.query(
      'deleted_patient_tombstones',
      where: 'source = ? AND external_id = ?',
      whereArgs: [source, externalId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<Set<String>> getAllDeletedTombstoneSources() async {
    final rows = await db.query(
      'deleted_patient_tombstones',
      columns: ['source', 'external_id'],
    );
    return rows
        .where((r) => r['source'] != null && r['external_id'] != null)
        .map((r) => '${r['source']}:${r['external_id']}')
        .toSet();
  }

  @override
  Future<bool> isPatientDeleted(String patientId) async {
    final rows = await db.query(
      'deleted_patient_tombstones',
      where: 'patient_id = ?',
      whereArgs: [patientId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<void> assignSessionToPatient({
    required String sessionId,
    required String patientId,
    String? driveFolderId,
    Map<String, ({String fileName, String localPath})>? renamedPhotos,
  }) async {
    final hasFolder = driveFolderId != null && driveFolderId.isNotEmpty;
    final targetStatus = hasFolder ? UploadStatus.waiting.name : UploadStatus.pending.name;

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
              'drive_parent_folder_id': driveFolderId,
              'file_name': entry.value.fileName,
              'local_path': entry.value.localPath,
              'status': targetStatus,
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
            'drive_parent_folder_id': driveFolderId,
            'status': targetStatus,
          },
          where: 'session_id = ? AND (drive_file_id IS NULL OR drive_file_id = "")',
          whereArgs: [sessionId],
        );
      }

      // Preserve status = 'uploaded' for items that were already moved or uploaded on Drive
      if (hasFolder) {
        await txn.update(
          'uploads',
          {
            'patient_id': patientId,
            'drive_folder_id': driveFolderId,
            'drive_parent_folder_id': driveFolderId,
            'status': UploadStatus.uploaded.name,
          },
          where: 'session_id = ? AND drive_file_id IS NOT NULL AND drive_file_id != ""',
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
      where: 'status = ? OR status = ?',
      whereArgs: [UploadStatus.waiting.name, UploadStatus.pending.name],
      orderBy: 'created_at ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return UploadItem.fromMap(rows.first);
  }

  @override
  Future<int> getActiveUploadsCount() async {
    final count = Sqflite.firstIntValue(await db.rawQuery(
      "SELECT COUNT(*) FROM uploads WHERE status = 'waiting' OR status = 'uploading' OR status = 'pending'",
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
  Future<UploadItem?> getUploadByDriveFileId(String driveFileId) async {
    final rows = await db.query(
      'uploads',
      where: 'drive_file_id = ?',
      whereArgs: [driveFileId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return UploadItem.fromMap(rows.first);
  }

  @override
  Future<UploadItem?> getUploadByFileName(String fileName) async {
    final rows = await db.query(
      'uploads',
      where: 'file_name = ?',
      whereArgs: [fileName],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return UploadItem.fromMap(rows.first);
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
  final Map<String, String> _sourceToPatientId = {};
  final Map<String, List<({String source, String externalId})>> _patientSources = {};
  final Set<String> _pendingDeletions = {};
  final List<({String patientId, String? source, String? externalId, DateTime deletedAt})> _deletedTombstones = [];

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
      Patient? existing = _patients[incoming.id];

      // Match by exact business identity
      if (existing == null &&
          incoming.normalizedPhone != null &&
          incoming.normalizedPhone!.isNotEmpty) {
        for (final p in _patients.values) {
          if (p.matchesBusinessIdentity(incoming.normalizedName, incoming.normalizedPhone)) {
            existing = p;
            break;
          }
        }
      }

      // Match by legacy_patient_id
      if (existing == null &&
          incoming.legacyPatientId != null &&
          incoming.legacyPatientId!.isNotEmpty) {
        for (final p in _patients.values) {
          if (p.legacyPatientId == incoming.legacyPatientId) {
            existing = p;
            break;
          }
        }
      }

      if (existing == null) {
        _patients[incoming.id] = incoming;
      } else {
        final canonicalId = (!Patient.isValidUuid(existing.id) && Patient.isValidUuid(incoming.id))
            ? incoming.id
            : existing.id;
        final merged = Patient.merge(existing, incoming).copyWith(id: canonicalId);
        if (existing.id != canonicalId) {
          _patients.remove(existing.id);
          _patients[canonicalId] = merged;
          for (final entry in _sourceToPatientId.entries.toList()) {
            if (entry.value == existing.id) {
              _sourceToPatientId[entry.key] = canonicalId;
            }
          }
          final sources = _patientSources.remove(existing.id);
          if (sources != null) {
            _patientSources[canonicalId] = sources;
          }
        } else {
          _patients[canonicalId] = merged;
        }
      }
    }
  }

  @override
  Future<Patient?> getPatient(String id) async {
    if (_patients.containsKey(id)) {
      return _patients[id];
    }
    // Lookup by source mapping (e.g. Google Sheets external ID)
    final pId = _sourceToPatientId['google_sheets:$id'] ??
        _sourceToPatientId.entries.firstWhere((e) => e.key.endsWith(':$id'), orElse: () => const MapEntry('', '')).value;
    if (pId.isNotEmpty && _patients.containsKey(pId)) {
      return _patients[pId];
    }
    for (final p in _patients.values) {
      if (p.legacyPatientId == id) {
        return p;
      }
    }
    return null;
  }

  @override
  Future<void> linkPatientSource({
    required String patientId,
    required String source,
    required String externalId,
  }) async {
    _sourceToPatientId['$source:$externalId'] = patientId;
    final list = _patientSources.putIfAbsent(patientId, () => []);
    list.removeWhere((item) => item.source == source && item.externalId == externalId);
    list.add((source: source, externalId: externalId));
  }

  @override
  Future<String?> getPatientIdBySource({
    required String source,
    required String externalId,
  }) async {
    final pId = _sourceToPatientId['$source:$externalId'];
    if (pId != null && Patient.isValidUuid(pId)) {
      return pId;
    }
    return null;
  }

  @override
  Future<void> linkPatientSources(
    List<({String patientId, String source, String externalId})> sources,
  ) async {
    for (final s in sources) {
      await linkPatientSource(
        patientId: s.patientId,
        source: s.source,
        externalId: s.externalId,
      );
    }
  }

  @override
  Future<List<Map<String, String>>> getAllPatientSources() async {
    final list = <Map<String, String>>[];
    for (final entry in _patientSources.entries) {
      for (final s in entry.value) {
        list.add({
          'patient_id': entry.key,
          'source': s.source,
          'external_id': s.externalId,
        });
      }
    }
    return list;
  }

  @override
  Future<List<Map<String, String>>> getSourcesForPatient(String patientId) async {
    final list = _patientSources[patientId] ?? [];
    return list.map((s) => {'source': s.source, 'external_id': s.externalId}).toList();
  }

  @override
  Future<List<UploadItem>> getUploadsForPatient(String patientId) async {
    final list = _uploads.values.where((u) => u.patientId == patientId).toList();
    list.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    return list;
  }

  @override
  Future<Patient?> getPatientByBusinessIdentity(String normalizedName, String? normalizedPhone) async {
    if (normalizedPhone == null || normalizedPhone.isEmpty) return null;
    for (final patient in _patients.values) {
      if (patient.matchesBusinessIdentity(normalizedName, normalizedPhone)) {
        return patient;
      }
    }
    return null;
  }

  @override
  Future<List<Patient>> getPatients() async {
    final list = _patients.values.toList();
    list.sort((a, b) {
      final cmp = a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      if (cmp != 0) return cmp;
      return a.id.compareTo(b.id);
    });
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
      final matchesId = p.id.toLowerCase().contains(lower) ||
          (p.legacyPatientId != null && p.legacyPatientId!.toLowerCase().contains(lower));
      final matchesName = p.displayName.toLowerCase().contains(lower) ||
          p.normalizedName.contains(lower);
      final matchesPhone = (p.phoneDisplay != null && p.phoneDisplay!.toLowerCase().contains(lower)) ||
          (normPhone != null && p.normalizedPhone != null && p.normalizedPhone!.contains(normPhone));

      return switch (mode) {
        SearchFilterMode.all => matchesId || matchesName || matchesPhone,
        SearchFilterMode.name => matchesName,
        SearchFilterMode.phone => matchesPhone,
        SearchFilterMode.patientId => matchesId,
      };
    }).toList();

    matches.sort((a, b) {
      final cmp = a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      if (cmp != 0) return cmp;
      return a.id.compareTo(b.id);
    });
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
  Future<void> updatePatientId({required String oldId, required String newId}) async {
    final p = _patients.remove(oldId);
    if (p != null) {
      _patients[newId] = p.copyWith(id: newId);
    }
    for (final entry in _sourceToPatientId.entries.toList()) {
      if (entry.value == oldId) {
        _sourceToPatientId[entry.key] = newId;
      }
    }
    final sources = _patientSources.remove(oldId);
    if (sources != null) {
      _patientSources[newId] = sources;
    }
    for (final key in _sessions.keys.toList()) {
      final s = _sessions[key]!;
      if (s.patientId == oldId) {
        _sessions[key] = s.copyWith(patientId: newId);
      }
    }
    for (final key in _uploads.keys.toList()) {
      final u = _uploads[key]!;
      if (u.patientId == oldId) {
        _uploads[key] = u.copyWith(patientId: newId);
      }
    }
  }

  @override
  Future<int> reconcileStalePlaceholderPatients() async {
    final toRemove = <String>[];
    for (final p in _patients.values) {
      if (Patient.isUsableName(p.displayName, p.id, p.legacyPatientId)) continue;
      if (p.source == PatientSource.doctorCreated) continue;
      if (p.driveFolderId != null && p.driveFolderId!.isNotEmpty) continue;

      final hasUploads = _uploads.values.any((u) => u.patientId == p.id);
      if (hasUploads) continue;

      final hasSessions = _sessions.values.any((s) => s.patientId == p.id);
      if (hasSessions) continue;

      toRemove.add(p.id);
    }

    for (final id in toRemove) {
      _patients.remove(id);
      _patientSources.remove(id);
      _sourceToPatientId.removeWhere((_, targetId) => targetId == id);
    }
    return toRemove.length;
  }

  @override
  Future<void> assignSessionToPatient({
    required String sessionId,
    required String patientId,
    String? driveFolderId,
    Map<String, ({String fileName, String localPath})>? renamedPhotos,
  }) async {
    final hasFolder = driveFolderId != null && driveFolderId.isNotEmpty;
    final targetStatus = hasFolder ? UploadStatus.waiting : UploadStatus.pending;
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
        final isAlreadyUploaded =
            entry.value.driveFileId != null && entry.value.driveFileId!.isNotEmpty;
        _uploads[entry.key] = entry.value.copyWith(
          patientId: patientId,
          driveFolderId: driveFolderId,
          driveParentFolderId: driveFolderId,
          fileName: rename?.fileName,
          localPath: rename?.localPath,
          status: isAlreadyUploaded ? UploadStatus.uploaded : targetStatus,
        );
      }
    }
  }

  @override
  Future<void> deletePatient(String id) async {
    _patients.remove(id);
    final sources = _patientSources.remove(id);
    if (sources != null) {
      for (final s in sources) {
        _sourceToPatientId.remove('${s.source}:${s.externalId}');
      }
    }
    _sessions.removeWhere((_, s) => s.patientId == id);
    _uploads.removeWhere((_, u) => u.patientId == id);
  }

  @override
  Future<void> addPendingDeletion(String patientId) async {
    _pendingDeletions.add(patientId);
  }

  @override
  Future<List<String>> getPendingDeletions() async {
    return List.from(_pendingDeletions);
  }

  @override
  Future<void> removePendingDeletion(String patientId) async {
    _pendingDeletions.remove(patientId);
  }

  @override
  Future<void> recordDeletedTombstone({
    required String patientId,
    String? source,
    String? externalId,
  }) async {
    _deletedTombstones.add((
      patientId: patientId,
      source: source,
      externalId: externalId,
      deletedAt: DateTime.now(),
    ));
  }

  @override
  Future<bool> isSourceDeleted({
    required String source,
    required String externalId,
  }) async {
    return _deletedTombstones.any((t) => t.source == source && t.externalId == externalId);
  }

  @override
  Future<bool> isPatientDeleted(String patientId) async {
    return _deletedTombstones.any((t) => t.patientId == patientId);
  }

  @override
  Future<Set<String>> getAllDeletedTombstoneSources() async {
    final set = <String>{};
    for (final t in _deletedTombstones) {
      if (t.source != null && t.externalId != null) {
        set.add('${t.source}:${t.externalId}');
      }
    }
    return set;
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
        .where((u) =>
            u.status == UploadStatus.waiting ||
            u.status == UploadStatus.pending)
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
            u.status == UploadStatus.uploading ||
            u.status == UploadStatus.pending)
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

  @override
  Future<UploadItem?> getUploadByDriveFileId(String driveFileId) async {
    for (final u in _uploads.values) {
      if (u.driveFileId == driveFileId) return u;
    }
    return null;
  }

  @override
  Future<UploadItem?> getUploadByFileName(String fileName) async {
    for (final u in _uploads.values) {
      if (u.fileName == fileName) return u;
    }
    return null;
  }

  Map<String, UploadItem> dumpUploads() => Map.from(_uploads);
  Map<String, CaptureSession> dumpSessions() => Map.from(_sessions);
  Map<String, Patient> dumpPatients() => Map.from(_patients);

  @override
  Future<void> close() async {
    // In-memory cleanup
  }
}
