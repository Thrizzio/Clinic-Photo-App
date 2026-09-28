import 'dart:io';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Photo Persistence & Rapid Queue Enqueue', () {
    late AppDatabase database;
    late Directory tempDir;
    late UploadQueueService queueService;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('clinic_photos_test_');

      database = InMemoryAppDatabase();

      queueService = UploadQueueService(
        database: database,
        authService: GoogleAuthService(),
        driveService: DriveService(),
        customDocsDirectory: tempDir.path,
      );
    });

    tearDown(() async {
      queueService.dispose();
      await database.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('enqueuePhoto saves file locally and creates database record with waiting status', () async {
      // 1. Create a dummy captured photo file
      final mockCapturedFile = File(p.join(tempDir.path, 'temp_shutter_pic.jpg'));
      await mockCapturedFile.writeAsBytes([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]); // Fake JPEG header

      const patient = Patient(
        id: 'P001',
        name: 'Rahul Sharma',
        driveFolderId: 'folder_drive_p001',
      );

      // 2. Enqueue photo (simulating shutter press)
      final item = await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: mockCapturedFile.path,
      );

      // 3. Verify upload item record
      expect(item.patientId, 'P001');
      expect(item.driveFolderId, 'folder_drive_p001');
      expect(item.status, UploadStatus.waiting);
      expect(item.fileName, startsWith('P001_'));
      expect(item.fileName, endsWith('.jpg'));

      // 4. Verify record in database
      final next = await database.getNextPendingUpload();
      expect(next, isNotNull);
      expect(next!.id, item.id);
      expect(next.fileName, item.fileName);
      expect(next.status, UploadStatus.waiting);

      // 5. Verify file was copied to private documents folder
      final savedFile = File(item.localPath);
      expect(savedFile.existsSync(), isTrue);
      expect(savedFile.lengthSync(), 6);
    });
  });
}
