import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UploadQueue in AppDatabase', () {
    late AppDatabase database;

    setUp(() async {
      database = InMemoryAppDatabase();
    });

    tearDown(() async {
      await database.close();
    });

    test('enqueues item with waiting status', () async {
      final item = UploadItem(
        id: 'upload_001',
        patientId: 'P001',
        driveFolderId: 'folder_001',
        localPath: '/data/user/0/com.clinic.photoapp/photo_queue/P001_photo1.jpg',
        fileName: 'P001_photo1.jpg',
        createdAt: DateTime.now(),
      );

      await database.insertUpload(item);

      final next = await database.getNextPendingUpload();
      expect(next, isNotNull);
      expect(next!.id, 'upload_001');
      expect(next.status, UploadStatus.waiting);
      expect(await database.getActiveUploadsCount(), 1);
      expect(await database.getFailedUploadsCount(), 0);
    });

    test('state transition: waiting -> uploading', () async {
      final item = UploadItem(
        id: 'upload_002',
        patientId: 'P001',
        driveFolderId: 'folder_001',
        localPath: '/data/user/0/com.clinic.photoapp/photo_queue/P001_photo2.jpg',
        fileName: 'P001_photo2.jpg',
        createdAt: DateTime.now(),
      );

      await database.insertUpload(item);
      await database.updateUpload(item.copyWith(status: UploadStatus.uploading));

      final all = await database.getAllUploads();
      expect(all.first.status, UploadStatus.uploading);
      expect(await database.getActiveUploadsCount(), 1);
    });

    test('upload confirmed: deletes SQLite record completely (no accumulating rows)', () async {
      final item = UploadItem(
        id: 'upload_003',
        patientId: 'P001',
        driveFolderId: 'folder_001',
        localPath: '/data/user/0/com.clinic.photoapp/photo_queue/P001_photo3.jpg',
        fileName: 'P001_photo3.jpg',
        createdAt: DateTime.now(),
      );

      await database.insertUpload(item);
      expect(await database.getActiveUploadsCount(), 1);

      // Drive confirms file creation -> delete from uploads
      await database.deleteUpload(item.id);

      expect(await database.getActiveUploadsCount(), 0);
      expect(await database.getAllUploads(), isEmpty);
    });

    test('failure and manual retry flow: waiting -> failed -> retry resets to waiting', () async {
      final item = UploadItem(
        id: 'upload_004',
        patientId: 'P001',
        driveFolderId: 'folder_001',
        localPath: '/data/user/0/com.clinic.photoapp/photo_queue/P001_photo4.jpg',
        fileName: 'P001_photo4.jpg',
        createdAt: DateTime.now(),
      );

      await database.insertUpload(item);

      // Fail upload after multiple attempts
      await database.updateUpload(item.copyWith(
        status: UploadStatus.failed,
        retryCount: 4,
        lastError: 'Google API network timeout',
      ));

      expect(await database.getActiveUploadsCount(), 0);
      expect(await database.getFailedUploadsCount(), 1);

      // Doctor taps retry -> resets all failed to waiting
      await database.resetFailedToWaiting();

      expect(await database.getActiveUploadsCount(), 1);
      expect(await database.getFailedUploadsCount(), 0);

      final next = await database.getNextPendingUpload();
      expect(next, isNotNull);
      expect(next!.status, UploadStatus.waiting);
      expect(next.retryCount, 0);
      expect(next.lastError, isNull);
    });

    test('Startup crash recovery rule: resets any "uploading" item to "waiting" on database open', () async {
      // 1. Open database and insert an item that is in the middle of 'uploading'
      final db = InMemoryAppDatabase();

      final item = UploadItem(
        id: 'crashed_upload_005',
        patientId: 'P005',
        driveFolderId: 'folder_005',
        localPath: '/data/photo.jpg',
        fileName: 'photo.jpg',
        status: UploadStatus.uploading,
        createdAt: DateTime.now(),
      );
      await db.insertUpload(item);

      // Verify it was saved as uploading
      var items = await db.getAllUploads();
      expect(items.first.status, UploadStatus.uploading);

      // 2. Simulate app restart: re-opening database from persisted storage
      final persistedUploads = db.dumpUploads();
      final reopenedDb = InMemoryAppDatabase(initialUploads: persistedUploads);

      // Verify crash recovery reset status from 'uploading' back to 'waiting'
      items = await reopenedDb.getAllUploads();
      expect(items.first.status, UploadStatus.waiting);
      expect(items.first.retryCount, 1);
      expect(items.first.nextAttemptAt, isNull);
    });

    test('worker claim is atomic when two queue runners see the same item', () async {
      final item = UploadItem(
        id: 'claim_once_008',
        patientId: 'P008',
        driveFolderId: 'folder_008',
        localPath: '/data/claim.jpg',
        fileName: 'claim.jpg',
        createdAt: DateTime.now(),
      );
      await database.insertUpload(item);

      final claims = await Future.wait([
        database.claimUpload(item.id),
        database.claimUpload(item.id),
      ]);

      expect(claims.whereType<UploadItem>(), hasLength(1));
      expect((await database.getAllUploads()).single.status, UploadStatus.uploading);
    });

    test('persisted backoff keeps a future retry out of the worker eligibility query', () async {
      final futureItem = UploadItem(
        id: 'backoff_future_006',
        patientId: 'P006',
        driveFolderId: 'folder_006',
        localPath: '/data/future.jpg',
        fileName: 'future.jpg',
        status: UploadStatus.waiting,
        retryCount: 1,
        nextAttemptAt: DateTime.now().add(const Duration(minutes: 10)),
        createdAt: DateTime.now(),
      );
      final readyItem = futureItem.copyWith(
        id: 'backoff_ready_007',
        fileName: 'ready.jpg',
        nextAttemptAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );

      await database.insertUpload(futureItem);
      await database.insertUpload(readyItem);

      final next = await database.getNextPendingUpload();
      expect(next?.id, readyItem.id);

      await database.resetFailedToWaiting();
      final persistedFuture = (await database.getAllUploads())
          .firstWhere((item) => item.id == futureItem.id);
      expect(persistedFuture.nextAttemptAt, isNotNull);
    });
  });
}
