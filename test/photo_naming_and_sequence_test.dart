import 'dart:io';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Photo Naming & Sequence Tests (Section 23.2)', () {
    late InMemoryAppDatabase database;
    late UploadQueueService queueService;
    late Directory tempRootDir;

    setUp(() async {
      tempRootDir = await Directory.systemTemp.createTemp('clinic_naming_test_');
      database = InMemoryAppDatabase();
      queueService = UploadQueueService(
        database: database,
        driveService: DriveService(),
        authService: GoogleAuthService(),
        customDocsDirectory: tempRootDir.path,
      );
    });

    tearDown(() async {
      queueService.dispose();
      await database.close();
      if (tempRootDir.existsSync()) {
        tempRootDir.deleteSync(recursive: true);
      }
    });

    test('1. Sequence numbering: incrementing sequence numbers in session', () async {
      const patient = Patient(
        id: 'P010',
        name: 'Sequence Tester',
        driveFolderId: 'folder_p010',
      );

      final dummy1 = File(p.join(tempRootDir.path, 'dummy1.jpg'))..writeAsStringSync('data1');
      final dummy2 = File(p.join(tempRootDir.path, 'dummy2.jpg'))..writeAsStringSync('data2');
      final dummy3 = File(p.join(tempRootDir.path, 'dummy3.jpg'))..writeAsStringSync('data3');

      final capturedAt = DateTime(2026, 10, 24, 14, 30, 22);

      final photo1 = await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: dummy1.path,
        capturedAt: capturedAt,
        sequenceNumber: 1,
      );
      final photo2 = await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: dummy2.path,
        capturedAt: capturedAt,
        sequenceNumber: 2,
      );
      final photo3 = await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: dummy3.path,
        capturedAt: capturedAt,
        sequenceNumber: 3,
      );

      expect(photo1.sequenceNumber, 1);
      expect(photo1.fileName, 'P010_20261024_143022_001.jpg');

      expect(photo2.sequenceNumber, 2);
      expect(photo2.fileName, 'P010_20261024_143022_002.jpg');

      expect(photo3.sequenceNumber, 3);
      expect(photo3.fileName, 'P010_20261024_143022_003.jpg');
    });

    test('2. Assigned photo name format: <Patient ID>_<yyyyMMdd_HHmmss>_<seq>.jpg', () async {
      const patient = Patient(
        id: 'P999',
        name: 'Format Patient',
        driveFolderId: 'folder_p999',
      );

      final dummy = File(p.join(tempRootDir.path, 'dummy.jpg'))..writeAsStringSync('test');
      final timestamp = DateTime(2026, 5, 12, 9, 5, 8);

      final item = await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: dummy.path,
        capturedAt: timestamp,
        sequenceNumber: 5,
      );

      expect(item.fileName, 'P999_20260512_090508_005.jpg');
    });

    test('3. Unassigned photo name format: unassigned_<yyyyMMdd_HHmmss>_<seq>.jpg', () async {
      final session = await queueService.createUnassignedSession();
      final dummy = File(p.join(tempRootDir.path, 'dummy_unassigned.jpg'))..writeAsStringSync('test');
      final timestamp = DateTime(2026, 7, 4, 18, 22, 45);

      final item = await queueService.enqueueUnassignedPhoto(
        sessionId: session.id,
        capturedTempPath: dummy.path,
        capturedAt: timestamp,
        sequenceNumber: 1,
      );

      expect(item.fileName, 'unassigned_20260704_182245_001.jpg');
      expect(item.sequenceNumber, 1);
    });

    test('4. Renaming on assignment: preserves capture timestamp and sequence number with new patient ID', () async {
      final session = await queueService.createUnassignedSession();
      final dummy = File(p.join(tempRootDir.path, 'dummy_to_assign.jpg'))..writeAsStringSync('patient_image_content');
      final capturedTime = DateTime(2026, 8, 15, 11, 45, 30);

      final item = await queueService.enqueueUnassignedPhoto(
        sessionId: session.id,
        capturedTempPath: dummy.path,
        capturedAt: capturedTime,
        sequenceNumber: 7,
      );

      expect(item.fileName, 'unassigned_20260815_114530_007.jpg');
      expect(File(item.localPath).existsSync(), isTrue);

      const targetPatient = Patient(
        id: 'P777',
        name: 'Assigned Target',
        driveFolderId: 'folder_target_777',
      );

      await queueService.assignSession(
        sessionId: session.id,
        patient: targetPatient,
      );

      final uploads = await database.getUploadsForSession(session.id);
      expect(uploads.length, 1);
      final assignedItem = uploads.first;

      // Expect fileName to be renamed with target patient ID while preserving timestamp and sequence number
      final expectedFileName = 'P777_20260815_114530_007.jpg';
      expect(assignedItem.fileName, expectedFileName);
      expect(assignedItem.patientId, 'P777');
      expect(assignedItem.driveFolderId, 'folder_target_777');
      expect(assignedItem.sequenceNumber, 7);

      // Verifies physical file was renamed on disk
      final renamedFile = File(assignedItem.localPath);
      expect(renamedFile.existsSync(), isTrue);
      expect(p.basename(renamedFile.path), expectedFileName);
      expect(renamedFile.readAsStringSync(), 'patient_image_content');
    });

    test('5. Sequence independence: Two different sessions for same patient restart sequence at 1', () async {
      const patient = Patient(
        id: 'P020',
        name: 'Independent Sessions',
        driveFolderId: 'folder_p020',
      );

      final session1Photo = await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: (File(p.join(tempRootDir.path, 's1.jpg'))..writeAsStringSync('s1')).path,
        sequenceNumber: 1,
      );

      final session2Photo = await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: (File(p.join(tempRootDir.path, 's2.jpg'))..writeAsStringSync('s2')).path,
        sequenceNumber: 1,
      );

      expect(session1Photo.sequenceNumber, 1);
      expect(session2Photo.sequenceNumber, 1);
      expect(session1Photo.fileName.endsWith('_001.jpg'), isTrue);
      expect(session2Photo.fileName.endsWith('_001.jpg'), isTrue);
    });
  });
}
