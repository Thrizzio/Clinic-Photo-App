import 'dart:io';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late UploadQueueService queueService;
  late Directory tempRootDir;

  setUp(() async {
    database = InMemoryAppDatabase();
    tempRootDir = await Directory.systemTemp.createTemp('clinic_unassigned_test_');

    final authService = GoogleAuthService();
    final driveService = DriveService();

    queueService = UploadQueueService(
      database: database,
      driveService: driveService,
      authService: authService,
      customDocsDirectory: tempRootDir.path,
    );
  });

  tearDown(() async {
    queueService.dispose();
    if (await tempRootDir.exists()) {
      await tempRootDir.delete(recursive: true);
    }
  });

  group('Unassigned Capture Sessions & Workflow B', () {
    test('creates unassigned session and enqueues photos locally', () async {
      final session = await queueService.createUnassignedSession();
      expect(session.id, isNotEmpty);
      expect(session.patientId, isNull);
      expect(session.status, 'unassigned');

      // Create dummy temporary captured photos
      final dummyPhoto1 = File('${tempRootDir.path}/temp_shot_1.jpg');
      await dummyPhoto1.writeAsString('image_data_1');
      final dummyPhoto2 = File('${tempRootDir.path}/temp_shot_2.jpg');
      await dummyPhoto2.writeAsString('image_data_2');

      final item1 = await queueService.enqueueUnassignedPhoto(
        sessionId: session.id,
        capturedTempPath: dummyPhoto1.path,
      );
      final item2 = await queueService.enqueueUnassignedPhoto(
        sessionId: session.id,
        capturedTempPath: dummyPhoto2.path,
      );

      expect(item1.status, UploadStatus.unassigned);
      expect(item2.status, UploadStatus.unassigned);
      expect(item1.sessionId, session.id);
      expect(item2.sessionId, session.id);
      expect(item1.patientId, isNull);
      expect(item2.patientId, isNull);

      // Verify files exist in private storage under unassigned/
      expect(File(item1.localPath).existsSync(), isTrue);
      expect(File(item2.localPath).existsSync(), isTrue);
      expect(item1.localPath.contains('unassigned'), isTrue);

      // Verify session queries
      final unassignedCount = await database.getUnassignedSessionsCount();
      expect(unassignedCount, 1);

      final unassignedSessions = await database.getUnassignedSessions();
      expect(unassignedSessions.length, 1);
      expect(unassignedSessions.first.id, session.id);
      expect(unassignedSessions.first.photoCount, 2);
    });

    test('assigns session to available patient and transitions photos to waiting', () async {
      final session = await queueService.createUnassignedSession();

      final dummyPhoto = File('${tempRootDir.path}/temp_shot_3.jpg');
      await dummyPhoto.writeAsString('image_data_3');

      final item = await queueService.enqueueUnassignedPhoto(
        sessionId: session.id,
        capturedTempPath: dummyPhoto.path,
      );
      expect(item.status, UploadStatus.unassigned);

      const targetPatient = Patient(
        id: 'P100',
        name: 'Dr. Test Patient',
        driveFolderId: 'VALID_DRIVE_FOLDER_123',
        folderStatus: FolderStatus.available,
      );

      await queueService.assignSession(
        sessionId: session.id,
        patient: targetPatient,
      );

      // Session should no longer appear in unassigned sessions
      final unassignedCount = await database.getUnassignedSessionsCount();
      expect(unassignedCount, 0);

      // Upload items should now be in waiting status with patient and folder ID
      final sessionUploads = await database.getUploadsForSession(session.id);
      expect(sessionUploads.length, 1);
      expect(sessionUploads.first.patientId, 'P100');
      expect(sessionUploads.first.driveFolderId, 'VALID_DRIVE_FOLDER_123');
      expect(
        sessionUploads.first.status,
        anyOf(UploadStatus.waiting, UploadStatus.uploading, UploadStatus.failed),
      );
    });

    test('refuses to assign session to patient with missing or conflict folder status', () async {
      final session = await queueService.createUnassignedSession();

      final dummyPhoto = File('${tempRootDir.path}/temp_shot_4.jpg');
      await dummyPhoto.writeAsString('image_data_4');
      await queueService.enqueueUnassignedPhoto(
        sessionId: session.id,
        capturedTempPath: dummyPhoto.path,
      );

      const missingPatient = Patient(
        id: 'P200',
        name: 'Missing Folder Patient',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );

      expect(
        () => queueService.assignSession(
          sessionId: session.id,
          patient: missingPatient,
        ),
        throwsA(isA<ArgumentError>()),
      );

      const conflictPatient = Patient(
        id: 'P300',
        name: 'Conflict Patient',
        driveFolderId: null,
        folderStatus: FolderStatus.conflict,
      );

      expect(
        () => queueService.assignSession(
          sessionId: session.id,
          patient: conflictPatient,
        ),
        throwsA(isA<ArgumentError>()),
      );

      // Photos remain safely in unassigned status without any loss
      final sessionUploads = await database.getUploadsForSession(session.id);
      expect(sessionUploads.length, 1);
      expect(sessionUploads.first.status, UploadStatus.unassigned);
      expect(await database.getUnassignedSessionsCount(), 1);
    });

    test('recovers orphaned unassigned photos from disk', () async {
      const orphanSessionId = 'orphan_sess_999';
      final sessionDir = Directory(
        '${tempRootDir.path}/photo_queue/unassigned/$orphanSessionId',
      );
      sessionDir.createSync(recursive: true);

      final photo1 = File('${sessionDir.path}/unassigned_2026-09-28_12-00-00_abcd.jpg');
      photo1.writeAsStringSync('binary_photo_data_1');
      final photo2 = File('${sessionDir.path}/unassigned_2026-09-28_12-00-01_ef01.jpg');
      photo2.writeAsStringSync('binary_photo_data_2');

      expect(await database.getUnassignedSessionsCount(), 0);

      await queueService.recoverOrphanedUnassignedPhotos();

      expect(await database.getUnassignedSessionsCount(), 1);
      final session = await database.getSession(orphanSessionId);
      expect(session, isNotNull);
      expect(session!.photoCount, 2);

      final uploads = await database.getUploadsForSession(orphanSessionId);
      expect(uploads.length, 2);
      expect(uploads.every((u) => u.status == UploadStatus.unassigned), isTrue);
      expect(uploads.every((u) => u.patientId == null), isTrue);
      expect(uploads.every((u) => u.driveFolderId == null), isTrue);
    });
  });
}

