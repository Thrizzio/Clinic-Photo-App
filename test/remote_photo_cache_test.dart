import 'dart:io';
import 'dart:typed_data';
import 'package:clinic_photos/models/remote_cache_entry.dart';
import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/remote_photo_cache.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class _TestAuthClient extends http.BaseClient implements AuthClient {
  @override
  AccessCredentials get credentials => AccessCredentials(
        AccessToken('Bearer', 'mock_token', DateTime.now().toUtc().add(const Duration(hours: 1))),
        'mock_refresh',
        ['https://www.googleapis.com/auth/drive'],
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}

class _MockDriveService extends DriveService {
  final Map<String, Uint8List> mockFiles = {};
  int thumbnailCalls = 0;
  int fullFileCalls = 0;
  final List<String> deletedDriveFiles = [];

  @override
  Future<Uint8List?> getThumbnailBytes({
    required AuthClient client,
    required String fileId,
    String? thumbnailLink,
  }) async {
    thumbnailCalls++;
    return mockFiles[fileId];
  }

  @override
  Future<Uint8List> getFileBytes({
    required AuthClient client,
    required String fileId,
  }) async {
    fullFileCalls++;
    final bytes = mockFiles[fileId];
    if (bytes != null) return bytes;
    throw Exception('File not found: $fileId');
  }

  @override
  Future<void> deleteFile({
    required AuthClient client,
    required String fileId,
    String? parentFolderId,
  }) async {
    deletedDriveFiles.add(fileId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 6: Remote Photo Cache & Retention Tests', () {
    late Directory tempCacheDir;
    late InMemoryAppDatabase database;
    late _MockDriveService driveService;
    late RemotePhotoCacheService cacheService;
    late _TestAuthClient authClient;

    setUp(() async {
      tempCacheDir = await Directory.systemTemp.createTemp('remote_cache_test_');
      database = InMemoryAppDatabase();
      driveService = _MockDriveService();
      authClient = _TestAuthClient();
      cacheService = RemotePhotoCacheService(
        database: database,
        driveService: driveService,
        customBaseDirectory: tempCacheDir.path,
        maxBudgetBytes: 1000, // Small budget for testing eviction
        targetBudgetBytes: 600, // Evict down to 600 bytes
        maxAge: const Duration(days: 30),
      );
    });

    tearDown(() async {
      if (await tempCacheDir.exists()) {
        await tempCacheDir.delete(recursive: true);
      }
    });

    test('1. Lazy download & cache hit for remote thumbnails', () async {
      final sampleBytes = Uint8List.fromList(List.generate(100, (i) => i % 256));
      driveService.mockFiles['file_thumb_1'] = sampleBytes;

      // 1. First fetch: downloads lazily from DriveService
      final fetched = await cacheService.getThumbnail(
        client: authClient,
        driveFileId: 'file_thumb_1',
        patientId: 'patient_1',
      );
      expect(fetched, isNotNull);
      expect(fetched!.length, 100);
      expect(driveService.thumbnailCalls, 1);

      // Verify file exists on disk in app-private thumbnails directory
      final thumbFile = File(p.join(tempCacheDir.path, 'remote_photo_cache', 'thumbnails', 'file_thumb_1.jpg'));
      expect(thumbFile.existsSync(), isTrue);

      // Verify record tracked in database
      final entry = await database.getRemoteCacheEntry('file_thumb_1', 'thumbnail');
      expect(entry, isNotNull);
      expect(entry!.driveFileId, 'file_thumb_1');
      expect(entry.fileSize, 100);

      // 2. Second fetch: served from local cache without querying Drive
      final cached = await cacheService.getThumbnail(
        client: authClient,
        driveFileId: 'file_thumb_1',
        patientId: 'patient_1',
      );
      expect(cached, isNotNull);
      expect(cached!.length, 100);
      expect(driveService.thumbnailCalls, 1); // Not incremented!
    });

    test('2. Lazy download & cache hit for full-resolution photos', () async {
      final sampleBytes = Uint8List.fromList(List.generate(300, (i) => i % 256));
      driveService.mockFiles['file_full_1'] = sampleBytes;

      final fetched = await cacheService.getFullImage(
        client: authClient,
        driveFileId: 'file_full_1',
        patientId: 'patient_1',
      );
      expect(fetched, isNotNull);
      expect(fetched!.length, 300);
      expect(driveService.fullFileCalls, 1);

      final fullFile = File(p.join(tempCacheDir.path, 'remote_photo_cache', 'full', 'file_full_1.jpg'));
      expect(fullFile.existsSync(), isTrue);

      // Second read served from cache
      final cached = await cacheService.getFullImage(
        client: authClient,
        driveFileId: 'file_full_1',
        patientId: 'patient_1',
      );
      expect(cached, isNotNull);
      expect(driveService.fullFileCalls, 1);
    });

    test('3. 30-day retention & expiry eviction', () async {
      final oldTime = DateTime.now().subtract(const Duration(days: 35));
      final testFile = File(p.join(tempCacheDir.path, 'remote_photo_cache', 'thumbnails', 'old_file.jpg'));
      await testFile.create(recursive: true);
      await testFile.writeAsBytes([1, 2, 3]);

      await database.insertRemoteCacheEntry(
        RemoteCacheEntry(
          driveFileId: 'old_file',
          cacheType: 'thumbnail',
          filePath: testFile.path,
          fileSize: 3,
          patientId: 'patient_1',
          createdAt: oldTime,
          lastAccessedAt: oldTime,
        ),
      );

      final evicted = await cacheService.evictExpiredEntries();
      expect(evicted, 1);
      expect(testFile.existsSync(), isFalse);
      expect(await database.getRemoteCacheEntry('old_file', 'thumbnail'), isNull);

      // Cloud original invariant: Cache eviction NEVER deletes from Drive
      expect(driveService.deletedDriveFiles, isEmpty);
    });

    test('4. LRU eviction with 1000 -> 600 bytes budget hysteresis', () async {
      // Add 4 entries of 300 bytes each = 1200 bytes total (exceeds 1000 max budget)
      final now = DateTime.now();
      for (var i = 1; i <= 4; i++) {
        final file = File(p.join(tempCacheDir.path, 'remote_photo_cache', 'full', 'lru_$i.jpg'));
        await file.create(recursive: true);
        await file.writeAsBytes(List.generate(300, (idx) => idx % 256));

        await database.insertRemoteCacheEntry(
          RemoteCacheEntry(
            driveFileId: 'lru_$i',
            cacheType: 'full',
            filePath: file.path,
            fileSize: 300,
            patientId: 'patient_1',
            createdAt: now.add(Duration(minutes: i)),
            lastAccessedAt: now.add(Duration(minutes: i)), // lru_1 is oldest
          ),
        );
      }

      final initialSize = await database.getTotalRemoteCacheSize();
      expect(initialSize, 1200);

      // Evict down to target budget (600 bytes)
      final evictedCount = await cacheService.evictLruIfNeeded();
      // Needs to evict 2 entries of 300 bytes = 600 bytes remaining
      expect(evictedCount, 2);

      final finalSize = await database.getTotalRemoteCacheSize();
      expect(finalSize, lessThanOrEqualTo(600));

      // Oldest entries (lru_1, lru_2) were evicted
      expect(await database.getRemoteCacheEntry('lru_1', 'full'), isNull);
      expect(await database.getRemoteCacheEntry('lru_2', 'full'), isNull);
      // Newer entries (lru_3, lru_4) remain
      expect(await database.getRemoteCacheEntry('lru_3', 'full'), isNotNull);
      expect(await database.getRemoteCacheEntry('lru_4', 'full'), isNotNull);

      // Invariant: Drive files were NOT deleted
      expect(driveService.deletedDriveFiles, isEmpty);
    });

    test('5. Invalidation when remote photo is deleted or changed', () async {
      final sampleBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      driveService.mockFiles['file_to_invalidate'] = sampleBytes;

      await cacheService.getThumbnail(
        client: authClient,
        driveFileId: 'file_to_invalidate',
        patientId: 'patient_inv',
      );

      final file = File(p.join(tempCacheDir.path, 'remote_photo_cache', 'thumbnails', 'file_to_invalidate.jpg'));
      expect(file.existsSync(), isTrue);

      // Invalidate specifically
      await cacheService.invalidate('file_to_invalidate');
      expect(file.existsSync(), isFalse);
      expect(await database.getRemoteCacheEntry('file_to_invalidate', 'thumbnail'), isNull);
    });

    test('6. Verified local captures cleanup after 30 days retains pending & unassigned captures', () async {
      final queueDir = Directory(p.join(tempCacheDir.path, 'photo_queue'));
      await queueDir.create(recursive: true);

      // 1. Old verified upload (> 30 days)
      final oldVerifiedFile = File(p.join(queueDir.path, 'old_verified.jpg'));
      await oldVerifiedFile.writeAsBytes([1, 2, 3]);
      final oldItem = UploadItem(
        id: 'upload_old_verified',
        patientId: 'patient_1',
        driveFolderId: 'drive_folder_1',
        localPath: oldVerifiedFile.path,
        fileName: 'old_verified.jpg',
        driveFileId: 'drive_old_1',
        status: UploadStatus.uploaded,
        createdAt: DateTime.now().subtract(const Duration(days: 35)),
      );
      await database.insertUpload(oldItem);

      // 2. Pending upload (> 30 days old timestamp due to offline)
      final pendingFile = File(p.join(queueDir.path, 'pending_photo.jpg'));
      await pendingFile.writeAsBytes([4, 5, 6]);
      final pendingItem = UploadItem(
        id: 'upload_pending',
        patientId: 'patient_1',
        driveFolderId: 'drive_folder_1',
        localPath: pendingFile.path,
        fileName: 'pending_photo.jpg',
        status: UploadStatus.waiting,
        createdAt: DateTime.now().subtract(const Duration(days: 35)),
      );
      await database.insertUpload(pendingItem);

      // 3. Failed upload
      final failedFile = File(p.join(queueDir.path, 'failed_photo.jpg'));
      await failedFile.writeAsBytes([7, 8, 9]);
      final failedItem = UploadItem(
        id: 'upload_failed',
        patientId: 'patient_1',
        driveFolderId: 'drive_folder_1',
        localPath: failedFile.path,
        fileName: 'failed_photo.jpg',
        status: UploadStatus.failed,
        createdAt: DateTime.now().subtract(const Duration(days: 35)),
      );
      await database.insertUpload(failedItem);

      // 4. Unassigned photo
      final unassignedFile = File(p.join(queueDir.path, 'unassigned_photo.jpg'));
      await unassignedFile.writeAsBytes([10, 11, 12]);
      final unassignedItem = UploadItem(
        id: 'upload_unassigned',
        patientId: null,
        sessionId: 'session_1',
        driveFolderId: 'drive_session_folder',
        localPath: unassignedFile.path,
        fileName: 'unassigned_photo.jpg',
        status: UploadStatus.uploaded,
        createdAt: DateTime.now().subtract(const Duration(days: 35)),
      );
      await database.insertUpload(unassignedItem);

      // 5. Recent verified upload (< 30 days)
      final recentVerifiedFile = File(p.join(queueDir.path, 'recent_verified.jpg'));
      await recentVerifiedFile.writeAsBytes([13, 14, 15]);
      final recentItem = UploadItem(
        id: 'upload_recent',
        patientId: 'patient_1',
        driveFolderId: 'drive_folder_1',
        localPath: recentVerifiedFile.path,
        fileName: 'recent_verified.jpg',
        driveFileId: 'drive_recent_1',
        status: UploadStatus.uploaded,
        createdAt: DateTime.now().subtract(const Duration(days: 5)),
      );
      await database.insertUpload(recentItem);

      final queueService = UploadQueueService(
        database: database,
        authService: GoogleAuthService(),
        driveService: driveService,
        customDocsDirectory: tempCacheDir.path,
      );
      addTearDown(queueService.dispose);

      // Run cleanup
      final cleanedCount = await queueService.cleanupOldVerifiedUploads(
        maxAge: const Duration(days: 30),
      );

      // Only the 1 old verified patient upload should be cleaned
      expect(cleanedCount, 1);
      expect(oldVerifiedFile.existsSync(), isFalse);

      // CRITICAL SAFETY INVARIANTS:
      // Pending uploads MUST NOT be deleted
      expect(pendingFile.existsSync(), isTrue);
      // Failed uploads MUST NOT be deleted
      expect(failedFile.existsSync(), isTrue);
      // Unassigned uploads MUST NOT be deleted
      expect(unassignedFile.existsSync(), isTrue);
      // Recent verified uploads (< 30 days) MUST NOT be deleted
      expect(recentVerifiedFile.existsSync(), isTrue);
      // Cloud originals NEVER deleted during local cleanup
      expect(driveService.deletedDriveFiles, isEmpty);

      // SQLite record is preserved with localPath cleared
      final updatedOld = await database.getUploadByDriveFileId('drive_old_1');
      expect(updatedOld, isNotNull);
      expect(updatedOld!.localPath, isEmpty);
      expect(updatedOld.driveFileId, 'drive_old_1');
    });
  });
}
