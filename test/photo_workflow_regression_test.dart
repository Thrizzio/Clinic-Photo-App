import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/screens/camera_screen.dart';
import 'package:clinic_photos/screens/patient_photos_screen.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/patient_folder_service.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:clinic_photos/widgets/upload_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

class FakeConnectivity implements Connectivity {
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => const Stream.empty();

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.wifi];
}

class MockDriveService extends DriveService {
  final Map<String, List<drive.File>> parentFolders = {};
  final Map<String, List<drive.File>> folderFiles = {};
  int createFolderCalls = 0;
  int uploadPhotoCalls = 0;
  bool shouldFailFolderCreation = false;
  Completer<void>? uploadGate;

  @override
  Future<List<drive.File>> findFoldersByName({
    required AuthClient client,
    required String parentFolderId,
    required String folderName,
  }) async {
    final list = parentFolders[parentFolderId] ?? [];
    return list.where((f) => f.name == folderName).toList();
  }

  @override
  Future<String> createFolder({
    required AuthClient client,
    required String parentFolderId,
    required String folderName,
  }) async {
    if (shouldFailFolderCreation) {
      throw const SocketException('Simulated offline / network error');
    }
    createFolderCalls++;
    final folderId = 'drive_folder_$createFolderCalls';
    final newFolder = drive.File()
      ..id = folderId
      ..name = folderName;
    parentFolders.putIfAbsent(parentFolderId, () => []).add(newFolder);
    return folderId;
  }

  @override
  Future<String> uploadPhoto({
    required AuthClient client,
    required File file,
    required String folderId,
    required String fileName,
  }) async {
    if (uploadGate != null) {
      await uploadGate!.future;
    }
    uploadPhotoCalls++;
    final fileId = 'uploaded_file_$uploadPhotoCalls';
    final uploaded = drive.File()
      ..id = fileId
      ..name = fileName
      ..createdTime = DateTime.now();
    folderFiles.putIfAbsent(folderId, () => []).add(uploaded);
    return fileId;
  }

  static final kTransparent1x1Png = Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ]);


  @override
  Future<Uint8List> getFileBytes({
    required AuthClient client,
    required String fileId,
  }) async {
    return kTransparent1x1Png;
  }

  @override
  Future<List<drive.File>> listPatientPhotos({
    required AuthClient client,
    required String folderId,
  }) async {
    return List.from(folderFiles[folderId] ?? []);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryAppDatabase db;
  late ConfigService configService;
  late UploadQueueService queueService;
  late PatientFolderService folderService;
  late MockDriveService mockDriveService;
  late FakeGoogleAuthService authService;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'parentDriveFolderId': 'parent_folder_test_root',
    });
    configService = await ConfigService.init();
    db = InMemoryAppDatabase();
    tempDir = Directory.systemTemp.createTempSync('photo_regression_test_');

    mockDriveService = MockDriveService();
    authService = FakeGoogleAuthService(FakeAuthClient());

    folderService = PatientFolderService(
      driveService: mockDriveService,
      sheetsService: SheetsService(),
      database: db,
      configService: configService,
      authService: authService,
    );

    queueService = UploadQueueService(
      database: db,
      driveService: mockDriveService,
      authService: authService,
      patientFolderService: folderService,
      connectivity: FakeConnectivity(),
      customDocsDirectory: tempDir.path,
    );
  });

  tearDown(() {
    queueService.dispose();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  File createFakeTempPhoto(String name) {
    final file = File('${tempDir.path}/$name.jpg');
    file.writeAsBytesSync([1, 2, 3, 4, 5]);
    return file;
  }

  group('A. Capture photo with existing folder', () {
    testWidgets('Photo is persisted locally, local path preserved, and uploaded to existing folder', (tester) async {
      const patient = Patient(
        id: 'patient-with-folder',
        name: 'Arjun Rao',
        displayName: 'Arjun Rao',
        driveFolderId: 'existing_folder_111',
        folderStatus: FolderStatus.available,
      );
      await db.upsertPatients([patient]);

      final tempPhoto = createFakeTempPhoto('photo_a1');
      final item = await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: tempPhoto.path,
      );

      // Verify local file exists and was preserved in photo_queue
      expect(File(item.localPath).existsSync(), isTrue);
      expect(item.driveFolderId, 'existing_folder_111');

      // Verify local record in SQLite
      final uploads = await db.getUploadsForPatient(patient.id);
      expect(uploads, hasLength(1));
      expect(uploads.first.localPath, item.localPath);
      expect(uploads.first.fileName, item.fileName);

      // Wait for background upload to complete
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      final completedUpload = await db.getUploadsForPatient(patient.id);
      expect(completedUpload.first.status, UploadStatus.uploaded);
      expect(completedUpload.first.driveFileId, isNotNull);
      // Local file is NOT deleted, kept for offline instant viewing
      expect(File(item.localPath).existsSync(), isTrue);

      // Verify PatientPhotosScreen displays photo with local thumbnail
      await tester.pumpWidget(
        MaterialApp(
          home: PatientPhotosScreen(
            patient: patient,
            authService: authService,
            driveService: mockDriveService,
            folderService: folderService,
            queueService: queueService,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(GridView), findsOneWidget);
      expect(find.text('1 photo'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('B. Capture first photo when folder does NOT exist', () {
    test('Folder created on photo capture, drive_folder_id populated, local photo preserved', () async {
      const patient = Patient(
        id: 'patient-no-folder',
        name: 'Meera Sen',
        displayName: 'Meera Sen',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );
      await db.upsertPatients([patient]);

      final tempPhoto = createFakeTempPhoto('photo_b1');
      final item = await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: tempPhoto.path,
      );

      // Initially queued as pending awaiting folder creation
      expect(item.status, UploadStatus.pending);
      expect(File(item.localPath).existsSync(), isTrue);

      // Wait for processQueue to create Drive folder and upload
      await Future<void>.delayed(const Duration(milliseconds: 250));

      // Local patient received drive_folder_id
      final updatedPatient = await db.getPatient(patient.id);
      expect(updatedPatient?.driveFolderId, isNotNull);
      expect(updatedPatient?.folderStatus, FolderStatus.available);

      // Local photo record preserved and uploaded
      final uploads = await db.getUploadsForPatient(patient.id);
      expect(uploads, hasLength(1));
      expect(uploads.first.status, UploadStatus.uploaded);
      expect(File(uploads.first.localPath).existsSync(), isTrue);
    });
  });

  group('C. Upload in progress', () {
    testWidgets('UI shows upload in progress, does NOT falsely say All photos uploaded', (tester) async {
      const patient = Patient(
        id: 'patient-in-progress',
        name: 'Deepak Chopra',
        displayName: 'Deepak Chopra',
        driveFolderId: 'folder_dp',
        folderStatus: FolderStatus.available,
      );
      await db.upsertPatients([patient]);

      mockDriveService.uploadGate = Completer<void>();
      final tempPhoto = createFakeTempPhoto('photo_c1');

      // Enqueue photo
      await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: tempPhoto.path,
      );

      // Render UploadStatusPill with patient scope
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UploadStatusPill(
              queueService: queueService,
              patientId: patient.id,
            ),
          ),
        ),
      );
      await tester.pump();

      // Verify it displays uploading status and NOT "All photos uploaded"
      expect(find.text('↑ 1 uploading'), findsOneWidget);
      expect(find.text('All photos uploaded'), findsNothing);

      // Also verify global status doesn't say All photos uploaded
      final status = await queueService.getStatus();
      expect(status.allPhotosUploaded, isFalse);
      expect(status.activeCount, 1);

      // Release gate and allow background upload to finish
      mockDriveService.uploadGate!.complete();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
    });
  });

  group('D. Upload completed & Zero photos handling', () {
    testWidgets('Empty photo list does NOT show All photos uploaded', (tester) async {
      const patient = Patient(
        id: 'empty-patient',
        name: 'Empty Patient',
        displayName: 'Empty Patient',
        driveFolderId: 'folder_empty',
      );
      await db.upsertPatients([patient]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UploadStatusPill(
              queueService: queueService,
              patientId: patient.id,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Zero photos must NEVER show "All photos uploaded"
      expect(find.text('All photos uploaded'), findsNothing);
      expect(find.byType(UploadStatusPill), findsOneWidget);
    });

    testWidgets('Shows All photos uploaded ONLY after photo upload is confirmed by Drive', (tester) async {
      const patient = Patient(
        id: 'patient-done',
        name: 'Done Patient',
        displayName: 'Done Patient',
        driveFolderId: 'folder_done',
      );
      await db.upsertPatients([patient]);

      final tempPhoto = createFakeTempPhoto('photo_done');
      await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: tempPhoto.path,
      );

      // Wait for upload to complete
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UploadStatusPill(
              queueService: queueService,
              patientId: patient.id,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Now with 1 confirmed uploaded photo and 0 active, it shows All photos uploaded
      expect(find.text('All photos uploaded'), findsOneWidget);
    });
  });

  group('E. Folder creation failure', () {
    test('When folder creation fails, local photo record and path are NOT lost', () async {
      mockDriveService.shouldFailFolderCreation = true;

      const patient = Patient(
        id: 'patient-fail',
        name: 'Failed Folder Patient',
        displayName: 'Failed Folder Patient',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );
      await db.upsertPatients([patient]);

      final tempPhoto = createFakeTempPhoto('photo_fail');
      final item = await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: tempPhoto.path,
      );

      // Allow background queue to try and handle failure
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Local file is intact
      expect(File(item.localPath).existsSync(), isTrue);

      // SQLite record is preserved in pending state waiting for network/folder
      final uploads = await db.getUploadsForPatient(patient.id);
      expect(uploads, hasLength(1));
      expect(uploads.first.status, UploadStatus.pending);
      expect(uploads.first.localPath, item.localPath);

      // Patient drive_folder_id remains null
      final currentPatient = await db.getPatient(patient.id);
      expect(currentPatient?.driveFolderId, isNull);
    });
  });

  group('F. Multiple photos captured', () {
    test('Multiple photos have distinct records, paths, sequence numbers and are all preserved', () async {
      const patient = Patient(
        id: 'patient-multi',
        name: 'Multi Photo Patient',
        displayName: 'Multi Photo Patient',
        driveFolderId: null,
      );
      await db.upsertPatients([patient]);

      final photo1 = createFakeTempPhoto('temp_multi_1');
      final photo2 = createFakeTempPhoto('temp_multi_2');
      final photo3 = createFakeTempPhoto('temp_multi_3');

      final item1 = await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: photo1.path,
        sequenceNumber: 1,
      );
      final item2 = await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: photo2.path,
        sequenceNumber: 2,
      );
      final item3 = await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: photo3.path,
        sequenceNumber: 3,
      );

      // All 3 local files exist in private storage
      expect(File(item1.localPath).existsSync(), isTrue);
      expect(File(item2.localPath).existsSync(), isTrue);
      expect(File(item3.localPath).existsSync(), isTrue);

      // Distinct paths and sequences
      expect(item1.localPath, isNot(equals(item2.localPath)));
      expect(item2.localPath, isNot(equals(item3.localPath)));
      expect(item1.sequenceNumber, 1);
      expect(item2.sequenceNumber, 2);
      expect(item3.sequenceNumber, 3);

      // Wait for queue processing
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final allUploads = await db.getUploadsForPatient(patient.id);
      expect(allUploads, hasLength(3));
      for (final u in allUploads) {
        expect(u.status, UploadStatus.uploaded);
        expect(File(u.localPath).existsSync(), isTrue);
      }
    });
  });

  group('G. Camera Done return flow', () {
    testWidgets('Exiting camera screen via Done returns photo count and keeps photos in patient view', (tester) async {
      const patient = Patient(
        id: 'patient-camera-done',
        name: 'Camera Done Patient',
        displayName: 'Camera Done Patient',
        driveFolderId: 'folder_cam_done',
      );
      await db.upsertPatients([patient]);

      // Enqueue a photo as would happen in CameraScreen
      final photo = createFakeTempPhoto('cam_done_pic');
      await queueService.enqueuePhoto(
        patient: patient,
        capturedTempPath: photo.path,
      );

      // Render CameraScreen
      int? returnedResult;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                returnedResult = await Navigator.of(ctx).push<int>(
                  MaterialPageRoute(
                    builder: (_) => CameraScreen(
                      patient: patient,
                      queueService: queueService,
                    ),
                  ),
                );
              },
              child: const Text('Open Camera'),
            ),
          ),
        ),
      );

      // Open camera
      await tester.tap(find.text('Open Camera'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify CameraScreen is displayed
      expect(find.byType(CameraScreen), findsOneWidget);

      // Tap Done button
      await tester.tap(find.widgetWithText(TextButton, 'Done'));
      await tester.pumpAndSettle();

      // Verify we returned directly to initial screen without opening second camera screen
      expect(find.byType(CameraScreen), findsNothing);
      expect(find.text('Open Camera'), findsOneWidget);
      expect(returnedResult, isNotNull);
    });
  });
}
