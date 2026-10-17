import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/remote_cache_entry.dart';
import 'database.dart';
import 'drive.dart';

/// Managed cache service for remote Google Drive photos and thumbnails.
///
/// Features:
/// - App-private storage isolated from local captures (`remote_photo_cache/`).
/// - Separate subdirectories for `thumbnails/` and `full/`.
/// - SQLite metadata tracking (`remote_photo_cache` table).
/// - Configurable 500 MB cache budget with LRU eviction to 400 MB.
/// - 30-day retention based on `last_accessed_at`.
/// - Hard invariant: eviction NEVER deletes cloud originals or local captures.
class RemotePhotoCacheService {
  final AppDatabase database;
  final DriveService driveService;
  final String? customBaseDirectory;
  final int maxBudgetBytes;
  final int targetBudgetBytes;
  final Duration maxAge;

  bool _isEvicting = false;

  RemotePhotoCacheService({
    required this.database,
    required this.driveService,
    this.customBaseDirectory,
    this.maxBudgetBytes = 500 * 1024 * 1024, // 500 MB
    this.targetBudgetBytes = 400 * 1024 * 1024, // 400 MB
    this.maxAge = const Duration(days: 30),
  });

  Future<String> _getBasePath() async {
    if (customBaseDirectory != null && customBaseDirectory!.isNotEmpty) {
      return customBaseDirectory!;
    }
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      final dir = Directory(p.join(Directory.systemTemp.path, 'clinic_remote_cache'));
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return dir.path;
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      return docs.path;
    } catch (_) {
      final dir = Directory(p.join(Directory.systemTemp.path, 'clinic_remote_cache'));
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return dir.path;
    }
  }

  Future<Directory> getThumbnailsDirectory() async {
    final base = await _getBasePath();
    final dir = Directory(p.join(base, 'remote_photo_cache', 'thumbnails'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<Directory> getFullImageDirectory() async {
    final base = await _getBasePath();
    final dir = Directory(p.join(base, 'remote_photo_cache', 'full'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// Retrieves thumbnail bytes for a remote Drive photo.
  ///
  /// Checks local managed disk cache first. If found, updates [lastAccessedAt]
  /// and returns bytes. Otherwise, fetches bytes via [DriveService.getThumbnailBytes],
  /// writes to disk, tracks in SQLite, and checks cache budget.
  Future<Uint8List?> getThumbnail({
    required AuthClient client,
    required String driveFileId,
    String? thumbnailLink,
    String? patientId,
  }) async {
    final cached = await getCachedBytes(driveFileId, 'thumbnail');
    if (cached != null) {
      return cached;
    }

    try {
      final bytes = await driveService.getThumbnailBytes(
        client: client,
        fileId: driveFileId,
        thumbnailLink: thumbnailLink,
      );
      if (bytes == null || bytes.isEmpty) return null;

      final dir = await getThumbnailsDirectory();
      final file = File(p.join(dir.path, '$driveFileId.jpg'));
      await file.writeAsBytes(bytes, flush: true);

      final now = DateTime.now();
      final entry = RemoteCacheEntry(
        driveFileId: driveFileId,
        cacheType: 'thumbnail',
        filePath: file.path,
        fileSize: bytes.length,
        patientId: patientId,
        createdAt: now,
        lastAccessedAt: now,
      );
      await database.insertRemoteCacheEntry(entry);

      _scheduleEvictionCheck();
      return bytes;
    } catch (e) {
      debugPrint('Failed to download thumbnail for $driveFileId: $e');
      return null;
    }
  }

  /// Retrieves full-resolution image bytes for a remote Drive photo.
  ///
  /// Checks local managed disk cache first. If found, updates [lastAccessedAt]
  /// and returns bytes. Otherwise, downloads via [DriveService.getFileBytes],
  /// writes to disk, tracks in SQLite, and checks cache budget.
  Future<Uint8List?> getFullImage({
    required AuthClient client,
    required String driveFileId,
    String? patientId,
  }) async {
    final cached = await getCachedBytes(driveFileId, 'full');
    if (cached != null) {
      return cached;
    }

    try {
      final bytes = await driveService.getFileBytes(
        client: client,
        fileId: driveFileId,
      );
      if (bytes.isEmpty) return null;

      final dir = await getFullImageDirectory();
      final file = File(p.join(dir.path, '$driveFileId.jpg'));
      await file.writeAsBytes(bytes, flush: true);

      final now = DateTime.now();
      final entry = RemoteCacheEntry(
        driveFileId: driveFileId,
        cacheType: 'full',
        filePath: file.path,
        fileSize: bytes.length,
        patientId: patientId,
        createdAt: now,
        lastAccessedAt: now,
      );
      await database.insertRemoteCacheEntry(entry);

      _scheduleEvictionCheck();
      return bytes;
    } catch (e) {
      debugPrint('Failed to download full image for $driveFileId: $e');
      return null;
    }
  }

  /// Reads cached bytes from disk if metadata exists and file is present.
  /// Updates [lastAccessedAt] on hit.
  Future<Uint8List?> getCachedBytes(String driveFileId, String cacheType) async {
    final entry = await database.getRemoteCacheEntry(driveFileId, cacheType);
    if (entry == null) return null;

    final file = File(entry.filePath);
    if (!file.existsSync()) {
      // Inconsistent cache state: remove stale record
      await database.deleteRemoteCacheEntry(driveFileId, cacheType);
      return null;
    }

    try {
      final bytes = await file.readAsBytes();
      await database.updateRemoteCacheAccess(driveFileId, cacheType, DateTime.now());
      return bytes;
    } catch (e) {
      debugPrint('Error reading cached file ${entry.filePath}: $e');
      return null;
    }
  }

  void _scheduleEvictionCheck() {
    if (_isEvicting) return;
    Future.microtask(() async {
      try {
        await evictLruIfNeeded();
      } catch (e) {
        debugPrint('Cache eviction error: $e');
      }
    });
  }

  /// Evicts cached entries older than [age] (defaults to [maxAge], 30 days).
  Future<int> evictExpiredEntries({Duration? age}) async {
    final effectiveAge = age ?? maxAge;
    final cutoff = DateTime.now().subtract(effectiveAge);
    final expired = await database.getExpiredRemoteCacheEntries(cutoff);
    int count = 0;
    for (final entry in expired) {
      if (await _deleteEntrySafely(entry)) {
        count++;
      }
    }
    return count;
  }

  /// Enforces cache budget and expiration policies.
  ///
  /// 1. Evicts entries older than [maxAge] (30 days).
  /// 2. If total size exceeds [maxBudgetBytes] (500 MB), evicts least recently
  ///    used (LRU) files until total size falls to [targetBudgetBytes] (400 MB).
  ///
  /// CRITICAL SAFETY: Only files strictly within `remote_photo_cache/` are
  /// ever deleted.
  Future<int> evictLruIfNeeded() async {
    if (_isEvicting) return 0;
    _isEvicting = true;
    int evictedCount = 0;
    try {
      // 1. Evict expired entries (30 days)
      await evictExpiredEntries();

      // 2. Check total cache size
      var currentSize = await database.getTotalRemoteCacheSize();
      if (currentSize <= maxBudgetBytes) return 0;

      // 3. LRU eviction down to targetBudgetBytes (400 MB)
      final lruEntries = await database.getLruRemoteCacheEntries();
      for (final entry in lruEntries) {
        if (currentSize <= targetBudgetBytes) break;
        final deleted = await _deleteEntrySafely(entry);
        if (deleted) {
          currentSize -= entry.fileSize;
          evictedCount++;
        }
      }
      return evictedCount;
    } finally {
      _isEvicting = false;
    }
  }

  Future<bool> _deleteEntrySafely(RemoteCacheEntry entry) async {
    try {
      final file = File(entry.filePath);
      // Hard invariant check: must be in remote_photo_cache directory
      final normalized = p.normalize(file.path);
      if (!normalized.contains('remote_photo_cache')) {
        debugPrint('SAFETY ABORT: Refusing to delete file outside remote_photo_cache: ${file.path}');
        return false;
      }

      if (file.existsSync()) {
        file.deleteSync();
      }
      await database.deleteRemoteCacheEntry(entry.driveFileId, entry.cacheType);
      return true;
    } catch (e) {
      debugPrint('Error deleting cached entry ${entry.filePath}: $e');
      return false;
    }
  }

  /// Invalidates all cached files and metadata for a specific Drive file ID
  /// (e.g. when confirmed deleted or moved on Drive).
  Future<void> invalidate(String driveFileId) async {
    final entries = await database.getRemoteCacheEntriesForDriveFile(driveFileId);
    for (final entry in entries) {
      await _deleteEntrySafely(entry);
    }
  }

  /// Invalidates all cached files and metadata for a patient.
  Future<void> invalidateForPatient(String patientId) async {
    final entries = await database.getRemoteCacheEntriesForPatient(patientId);
    for (final entry in entries) {
      await _deleteEntrySafely(entry);
    }
  }
}
