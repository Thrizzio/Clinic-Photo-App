import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/screens/patient_photos_screen.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/patient_folder_service.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class FakeAuthClient extends http.BaseClient implements AuthClient {
  @override
  AccessCredentials get credentials => AccessCredentials(
        AccessToken('Bearer', 'fake_token', DateTime.now().toUtc().add(const Duration(hours: 1))),
        'fake_refresh_token',
        ['https://www.googleapis.com/auth/drive'],
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}

class FakeGoogleAuthService extends GoogleAuthService {
  final AuthClient client;
  FakeGoogleAuthService(this.client);

  @override
  Future<AuthClient?> getAuthenticatedClient() async => client;
}

class FakeOfflineDriveService extends DriveService {
  int uploadCallCount = 0;
  List<drive.File> photosToReturn = [];

  @override
  Future<String> uploadPhoto({
    required AuthClient client,
    required File file,
    required String folderId,
    required String fileName,
  }) async {
    uploadCallCount++;
    return 'uploaded_drive_file_$uploadCallCount';
  }

  @override
  Future<List<drive.File>> listPatientPhotos({
    required AuthClient client,
    required String folderId,
  }) async {
    return photosToReturn;
  }
}

class FakeSheetsService extends SheetsService {}

class FakePatientFolderService extends PatientFolderService {
  String folderIdToReturn = 'resolved_drive_folder_123';
  int getOrCreateCallCount = 0;
  bool shouldThrow = false;

  FakePatientFolderService({
    required super.driveService,
    required super.sheetsService,
    required super.database,
    required super.configService,
    required super.authService,
  });

  @override
  Future<PatientFolderResult> getOrCreatePatientFolder(
    Patient patient, {
    AuthClient? clientOverride,
  }) async {
    getOrCreateCallCount++;
    if (shouldThrow) {
      throw const SocketException('Simulated offline network error');
    }
    final updated = patient.copyWith(
      driveFolderId: folderIdToReturn,
      folderStatus: FolderStatus.available,
    );
    await database.updatePatient(updated);
    return PatientFolderResult(
      patient: updated,
      driveFolderId: folderIdToReturn,
      createdNew: true,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late FakeAuthClient fakeClient;
  late FakeGoogleAuthService fakeAuth;
  late FakeOfflineDriveService fakeDrive;
  late FakeSheetsService fakeSheets;
  late InMemoryAppDatabase database;
  late ConfigService configService;
  late FakePatientFolderService fakeFolderService;
  late UploadQueueService queueService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    configService = ConfigService(prefs);

    tempDir = Directory.systemTemp.createTempSync('v5_offline_test_');
    fakeClient = FakeAuthClient();
    fakeAuth = FakeGoogleAuthService(fakeClient);
    fakeDrive = FakeOfflineDriveService();
    fakeSheets = FakeSheetsService();
    database = InMemoryAppDatabase();

    fakeFolderService = FakePatientFolderService(
      driveService: fakeDrive,
      sheetsService: fakeSheets,
      database: database,
      configService: configService,
      authService: fakeAuth,
    );

    queueService = UploadQueueService(
      database: database,
      driveService: fakeDrive,
      authService: fakeAuth,
      patientFolderService: fakeFolderService,
      customDocsDirectory: tempDir.path,
    );
  });

  tearDown(() {
    queueService.dispose();
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('V5 Offline-First Photo Capture & Async Upload Tests', () {
    test('Photo capture for offline patient without Drive folder saves to disk as pending', () async {
      // Simulate offline: folder service throws network error
      fakeFolderService.shouldThrow = true;

      final offlinePatient = Patient(
        id: 'patient_offline_001',
        name: 'Sunil Rao',
        phoneNumber: '9422000001',
        source: PatientSource.doctorCreated,
        driveFolderId: null,
        folderStatus: FolderStatus.available,
        syncStatus: 'pending_cloud',
      );
      await database.upsertPatients([offlinePatient]);

      // Create a temporary camera capture file
      final cameraTempFile = File('${tempDir.path}/camera_shutter_tmp.jpg');
      cameraTempFile.writeAsBytesSync([1, 2, 3, 4, 5]);
      expect(cameraTempFile.existsSync(), isTrue);

      // Enqueue photo immediately
      final item = await queueService.enqueuePhoto(
        patient: offlinePatient,
        capturedTempPath: cameraTempFile.path,
      );

      // 1. Shutter temporary file was removed
      expect(cameraTempFile.existsSync(), isFalse);

      // 2. Saved file exists in private storage under patient folder
      final savedFile = File(item.localPath);
      expect(savedFile.existsSync(), isTrue);
      expect(savedFile.lengthSync(), 5);

      // 3. SQLite record has status 'pending' (waiting for Drive folder creation)
      expect(item.status, UploadStatus.pending);
      expect(item.patientId, offlinePatient.id);
      expect(item.driveFolderId, isNull);

      final allUploads = await database.getAllUploads();
      final dbItem = allUploads.firstWhere((u) => u.id == item.id);
      expect(dbItem.status, UploadStatus.pending);
    });

    test('Upload worker resolves patient Drive folder, uploads, and retains local file cache', () async {
      fakeFolderService.shouldThrow = false;

      final offlinePatient = Patient(
        id: 'patient_offline_002',
        name: 'Deepak Joshi',
        phoneNumber: '9422000002',
        source: PatientSource.doctorCreated,
        driveFolderId: null,
        folderStatus: FolderStatus.available,
      );
      await database.upsertPatients([offlinePatient]);

      final cameraTempFile = File('${tempDir.path}/camera_tmp_2.jpg');
      cameraTempFile.writeAsBytesSync([10, 20, 30, 40]);

      final item = await queueService.enqueuePhoto(
        patient: offlinePatient,
        capturedTempPath: cameraTempFile.path,
      );

      final localFile = File(item.localPath);
      expect(localFile.existsSync(), isTrue);

      // Wait for queue processing to complete
      for (int i = 0; i < 50; i++) {
        final active = await database.getActiveUploadsCount();
        if (active == 0) break;
        await Future.delayed(const Duration(milliseconds: 20));
      }

      // 1. Folder service was called to resolve Drive folder
      expect(fakeFolderService.getOrCreateCallCount, greaterThanOrEqualTo(1));

      // 2. Photo was uploaded to Google Drive
      expect(fakeDrive.uploadCallCount, 1);

      // 3. Database upload item status transitioned to uploaded
      final updatedUploads = await database.getAllUploads();
      final updatedItem = updatedUploads.firstWhere((u) => u.id == item.id);
      expect(updatedItem.status, UploadStatus.uploaded);
      expect(updatedItem.driveFileId, isNotNull);

      // 4. CRITICAL: Local disk file is RETAINED for offline gallery viewing!
      expect(localFile.existsSync(), isTrue, reason: 'Local file must be retained as cache');
    });

    testWidgets('PatientPhotosScreen renders local uploads immediately with status badges', (tester) async {
      final patient = Patient(
        id: 'patient_badges_001',
        name: 'Vikas Sharma',
        phoneNumber: '9822300000',
        driveFolderId: 'folder_vikas_123',
        folderStatus: FolderStatus.available,
      );
      await database.upsertPatients([patient]);

      // Create 4 dummy files for the 4 status states
      final pendingFile = File('${tempDir.path}/p_pending.jpg')..writeAsBytesSync([1]);
      final uploadingFile = File('${tempDir.path}/p_uploading.jpg')..writeAsBytesSync([2]);
      final uploadedFile = File('${tempDir.path}/p_uploaded.jpg')..writeAsBytesSync([3]);
      final failedFile = File('${tempDir.path}/p_failed.jpg')..writeAsBytesSync([4]);

      await database.insertUpload(UploadItem(
        id: 'u_pend',
        patientId: patient.id,
        driveFolderId: null,
        localPath: pendingFile.path,
        fileName: 'photo_pending.jpg',
        status: UploadStatus.pending,
        createdAt: DateTime.now().subtract(const Duration(minutes: 4)),
      ));

      await database.insertUpload(UploadItem(
        id: 'u_up',
        patientId: patient.id,
        driveFolderId: patient.driveFolderId,
        localPath: uploadingFile.path,
        fileName: 'photo_uploading.jpg',
        status: UploadStatus.uploading,
        createdAt: DateTime.now().subtract(const Duration(minutes: 3)),
      ));

      await database.insertUpload(UploadItem(
        id: 'u_done',
        patientId: patient.id,
        driveFolderId: patient.driveFolderId,
        localPath: uploadedFile.path,
        fileName: 'photo_uploaded.jpg',
        status: UploadStatus.uploaded,
        driveFileId: 'drive_done_123',
        createdAt: DateTime.now().subtract(const Duration(minutes: 2)),
      ));

      await database.insertUpload(UploadItem(
        id: 'u_fail',
        patientId: patient.id,
        driveFolderId: patient.driveFolderId,
        localPath: failedFile.path,
        fileName: 'photo_failed.jpg',
        status: UploadStatus.failed,
        lastError: 'Simulated network timeout',
        createdAt: DateTime.now().subtract(const Duration(minutes: 1)),
      ));

      // Build PatientPhotosScreen
      await tester.pumpWidget(MaterialApp(
        home: PatientPhotosScreen(
          patient: patient,
          authService: fakeAuth,
          driveService: fakeDrive,
          folderService: fakeFolderService,
          queueService: queueService,
        ),
      ));

      // Use pump() rather than pumpAndSettle() because uploading status renders animated CircularProgressIndicator
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify all 4 status badges are rendered
      expect(find.text('PENDING'), findsOneWidget);
      expect(find.text('UPLOADING'), findsOneWidget);
      expect(find.text('UPLOADED'), findsOneWidget);
      expect(find.text('FAILED'), findsOneWidget);
    });

    test('Assigning unassigned session to patient without Drive folder sets pending status when offline', () async {
      // Simulate offline: folder creation fails
      fakeFolderService.shouldThrow = true;

      final session = await queueService.createUnassignedSession();
      final tempFile = File('${tempDir.path}/unassigned_sample.jpg')..writeAsBytesSync([1, 2, 3]);

      final unassignedPhoto = await queueService.enqueueUnassignedPhoto(
        sessionId: session.id,
        capturedTempPath: tempFile.path,
      );
      expect(unassignedPhoto.status, UploadStatus.unassigned);

      // Target patient with missing Drive folder
      final targetPatient = Patient(
        id: 'patient_target_no_drive',
        name: 'Gaurav Kulkarni',
        phoneNumber: '9422000003',
        source: PatientSource.doctorCreated,
        driveFolderId: null,
        folderStatus: FolderStatus.available,
      );
      await database.upsertPatients([targetPatient]);

      // Assign session to target patient while offline
      await queueService.assignSession(
        sessionId: session.id,
        patient: targetPatient,
      );

      // Verify the upload record in database is assigned to target patient and marked pending
      final assignedUploads = await database.getUploadsForSession(session.id);
      expect(assignedUploads.length, 1);
      expect(assignedUploads.first.patientId, targetPatient.id);
      expect(assignedUploads.first.status, UploadStatus.pending);

      // Verify local file exists under patient folder
      final localFile = File(assignedUploads.first.localPath);
      expect(localFile.existsSync(), isTrue);
      expect(localFile.path, contains(targetPatient.id));
    });
  });
}
