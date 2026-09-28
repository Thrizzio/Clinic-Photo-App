import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/patient.dart';
import '../models/upload_item.dart';

/// Abstract contract for clinic data storage.
abstract class AppDatabase {
  // --- Patients Cache Operations ---

  /// Replaces the entire patients cache with fresh records.
  Future<void> replacePatients(List<Patient> patients);

  /// Retrieves all cached patients sorted by ID.
  Future<List<Patient>> getPatients();

  /// Case-insensitive search by Patient ID or Name.
  Future<List<Patient>> searchPatients(String query);

  // --- Upload Queue Operations ---

  /// Inserts a new pending upload item.
  Future<void> insertUpload(UploadItem item);

  /// Updates an existing upload item (status, retries, errors).
  Future<void> updateUpload(UploadItem item);

  /// Deletes an upload item once Drive upload is confirmed successful.
  Future<void> deleteUpload(String id);

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
    Map<String, UploadItem>? initialUploads,
    bool performCrashRecovery = true,
  }) {
    return InMemoryAppDatabase(
      initialPatients: initialPatients,
      initialUploads: initialUploads,
      performCrashRecovery: performCrashRecovery,
    );
  }
}

/// SQLite-backed production database implementation for Android.
class SqliteAppDatabase implements AppDatabase {
  static const String _dbName = 'clinic_photos.db';
  static const int _dbVersion = 1;

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
              drive_folder_id TEXT NOT NULL
            )
          ''');

          await db.execute('''
            CREATE TABLE uploads (
              id TEXT PRIMARY KEY,
              patient_id TEXT NOT NULL,
              drive_folder_id TEXT NOT NULL,
              local_path TEXT NOT NULL,
              file_name TEXT NOT NULL,
              status TEXT NOT NULL,
              retry_count INTEGER NOT NULL DEFAULT 0,
              last_error TEXT,
              drive_file_id TEXT,
              created_at TEXT NOT NULL
            )
          ''');
        },
        onOpen: (db) async {
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
  Future<List<Patient>> getPatients() async {
    final rows = await db.query('patients', orderBy: 'id ASC');
    return rows.map(Patient.fromMap).toList();
  }

  @override
  Future<List<Patient>> searchPatients(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return getPatients();
    }

    final rows = await db.query(
      'patients',
      where: 'LOWER(id) LIKE ? OR LOWER(name) LIKE ?',
      whereArgs: [
        '%${trimmed.toLowerCase()}%',
        '%${trimmed.toLowerCase()}%',
      ],
      orderBy: 'id ASC',
    );
    return rows.map(Patient.fromMap).toList();
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
  final Map<String, UploadItem> _uploads = {};

  InMemoryAppDatabase({
    Map<String, Patient>? initialPatients,
    Map<String, UploadItem>? initialUploads,
    bool performCrashRecovery = true,
  }) {
    if (initialPatients != null) {
      _patients.addAll(initialPatients);
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
  Future<List<Patient>> getPatients() async {
    final list = _patients.values.toList();
    list.sort((a, b) => a.id.compareTo(b.id));
    return list;
  }

  @override
  Future<List<Patient>> searchPatients(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return getPatients();
    }
    final lower = trimmed.toLowerCase();
    final matches = _patients.values.where((p) {
      return p.id.toLowerCase().contains(lower) ||
          p.name.toLowerCase().contains(lower);
    }).toList();
    matches.sort((a, b) => a.id.compareTo(b.id));
    return matches;
  }

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
  Map<String, Patient> dumpPatients() => Map.from(_patients);

  @override
  Future<void> close() async {
    // In-memory cleanup
  }
}
