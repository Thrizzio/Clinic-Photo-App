import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/patient.dart';
import '../models/upload_item.dart';

class AppDatabase {
  static const String _dbName = 'clinic_photos.db';
  static const int _dbVersion = 1;

  final Database db;

  AppDatabase(this.db);

  static Future<AppDatabase> init({
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

    return AppDatabase(database);
  }

  // --- Patients Cache Operations ---

  /// Replaces the entire patients table with fresh records in a single transaction.
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

  /// Retrieves all cached patients.
  Future<List<Patient>> getPatients() async {
    final rows = await db.query('patients', orderBy: 'id ASC');
    return rows.map(Patient.fromMap).toList();
  }

  /// Case-insensitive local search by Patient ID or Name.
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

  /// Inserts a new pending upload item.
  Future<void> insertUpload(UploadItem item) async {
    await db.insert('uploads', item.toMap());
  }

  /// Updates an existing upload item (status, retries, errors).
  Future<void> updateUpload(UploadItem item) async {
    await db.update(
      'uploads',
      item.toMap(),
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  /// Deletes an upload item once Drive upload is confirmed successful.
  Future<void> deleteUpload(String id) async {
    await db.delete(
      'uploads',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Gets the next waiting or failed upload item to process.
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

  /// Gets count of active uploads (waiting or uploading).
  Future<int> getActiveUploadsCount() async {
    final count = Sqflite.firstIntValue(await db.rawQuery(
      "SELECT COUNT(*) FROM uploads WHERE status = 'waiting' OR status = 'uploading'",
    ));
    return count ?? 0;
  }

  /// Gets count of failed uploads.
  Future<int> getFailedUploadsCount() async {
    final count = Sqflite.firstIntValue(await db.rawQuery(
      "SELECT COUNT(*) FROM uploads WHERE status = 'failed'",
    ));
    return count ?? 0;
  }

  /// Resets all failed uploads back to waiting for manual retry.
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

  /// Gets all items currently in the queue.
  Future<List<UploadItem>> getAllUploads() async {
    final rows = await db.query('uploads', orderBy: 'created_at ASC');
    return rows.map(UploadItem.fromMap).toList();
  }

  Future<void> close() async {
    await db.close();
  }
}
