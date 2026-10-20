import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:share_plus/share_plus.dart';

import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/screens/collage_preview_screen.dart';
import 'package:clinic_photos/services/collage_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/photo_export_service.dart';
import 'package:clinic_photos/services/upload_queue.dart';

class FakeAuthClient extends http.BaseClient implements AuthClient {
  @override
  AccessCredentials get credentials => AccessCredentials(
        AccessToken('Bearer', 'fake_token', DateTime.now().toUtc().add(const Duration(hours: 1))),
        'refresh_token',
        ['https://www.googleapis.com/auth/drive'],
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}

class FakeGoogleAuthService implements GoogleAuthService {
  final AuthClient client = FakeAuthClient();

  @override
  Future<AuthClient?> getAuthenticatedClient() async => client;

  @override
  Future<AuthClient?> getAuthenticatedClientSilently() async => client;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeDriveService extends DriveService {
  final List<({String fileName, String folderId})> uploadedPhotos = [];

  @override
  Future<drive.File?> findPhotoByName({
    required AuthClient client,
    required String folderId,
    required String fileName,
  }) async {
    return null;
  }

  @override
  Future<String> uploadPhoto({
    required AuthClient client,
    required File file,
    required String folderId,
    required String fileName,
  }) async {
    uploadedPhotos.add((fileName: fileName, folderId: folderId));
    return 'drive_file_${uploadedPhotos.length}';
  }
}

class MockPhotoExportService implements PhotoExportService {
  String? savedGalleryPath;
  String? sharedFilePath;

  @override
  Future<bool> saveToGallery({
    String? filePath,
    Uint8List? bytes,
    String? fileName,
    String album = 'Clinic Photos',
  }) async {
    savedGalleryPath = filePath;
    return true;
  }

  @override
  Future<ShareResult> shareSinglePhoto({
    String? filePath,
    Uint8List? bytes,
    required String fileName,
    String? text,
    String? subject,
  }) async {
    sharedFilePath = filePath;
    return const ShareResult('', ShareResultStatus.success);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase database;
  late FakeGoogleAuthService authService;
  late FakeDriveService driveService;
  late UploadQueueService queueService;
  late MockPhotoExportService mockExportService;

  final testPatient = Patient(
    id: 'patient-test-uuid',
    displayName: 'Test Patient',
    phoneDisplay: '9876543210',
    normalizedPhone: '9876543210',
    driveFolderId: 'test_drive_folder_id',
    folderStatus: FolderStatus.available,
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('collage_test_');
    database = AppDatabase.inMemory(initialPatients: {testPatient.id: testPatient});
    authService = FakeGoogleAuthService();
    driveService = FakeDriveService();
    mockExportService = MockPhotoExportService();

    queueService = UploadQueueService(
      database: database,
      authService: authService,
      driveService: driveService,
      customDocsDirectory: tempDir.path,
    );
  });

  tearDown(() async {
    queueService.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('Collage Persistence & Upload Queue Unit Tests', () {
    test('formatCollageFileName generates expected deterministic name format', () {
      final dt = DateTime(2026, 10, 20, 16, 30, 0);
      final fileName = UploadQueueService.formatCollageFileName(dt);
      expect(fileName, matches(r'^Collage_\d{4}-\d{2}-\d{2}_\d{6}\.jpg$'));
      expect(fileName.startsWith('Collage_'), isTrue);
    });

    test('enqueueCollage copies file to durable storage and inserts SQLite record', () async {
      final dummySource = File('${tempDir.path}/temp_collage.jpg');
      await dummySource.writeAsBytes(Uint8List.fromList([1, 2, 3, 4, 5]));

      final item = await queueService.enqueueCollage(
        patient: testPatient,
        sourceCollagePath: dummySource.path,
      );

      expect(item.sessionId, equals('collage'));
      expect(item.patientId, equals(testPatient.id));
      expect(item.driveFolderId, equals(testPatient.driveFolderId));
      expect(item.isCollage, isTrue);
      expect(File(item.localPath).existsSync(), isTrue);

      final inDb = await database.getUpload(item.id);
      expect(inDb, isNotNull);
      expect(inDb!.fileName, equals(item.fileName));
      expect(inDb.isCollage, isTrue);
    });

    test('enqueueCollage throws FileSystemException if source file missing', () async {
      expect(
        () => queueService.enqueueCollage(
          patient: testPatient,
          sourceCollagePath: '${tempDir.path}/non_existent.jpg',
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('processQueue uploads persisted collage to Drive and sets status uploaded', () async {
      final dummySource = File('${tempDir.path}/temp_collage.jpg');
      await dummySource.writeAsBytes(Uint8List.fromList([1, 2, 3, 4, 5]));

      final item = await queueService.enqueueCollage(
        patient: testPatient,
        sourceCollagePath: dummySource.path,
      );

      UploadItem? updated;
      for (int i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        updated = await database.getUpload(item.id);
        if (updated?.status == UploadStatus.uploaded) break;
      }

      expect(updated, isNotNull);
      expect(updated!.status, equals(UploadStatus.uploaded));
      expect(updated.driveFileId, equals('drive_file_1'));
      expect(driveService.uploadedPhotos.length, equals(1));
      expect(driveService.uploadedPhotos.first.fileName, equals(item.fileName));
      expect(driveService.uploadedPhotos.first.folderId, equals(testPatient.driveFolderId));
      expect(File(item.localPath).existsSync(), isTrue);
    });
  });

  group('CollagePreviewScreen Widget Tests', () {
    late File dummyCollageFile;

    setUp(() async {
      dummyCollageFile = File('${tempDir.path}/preview_collage.jpg');
      final testImg = img.Image(width: 100, height: 100);
      img.fill(testImg, color: img.ColorRgb8(100, 150, 200));
      await dummyCollageFile.writeAsBytes(img.encodeJpg(testImg));
    });

    testWidgets('Renders preview and Save to Patient button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CollagePreviewScreen(
            patient: testPatient,
            collageResult: CollageResult(
              bytes: dummyCollageFile.readAsBytesSync(),
              filePath: dummyCollageFile.path,
              width: 100,
              height: 100,
            ),
            exportService: mockExportService,
            queueService: queueService,
          ),
        ),
      );

      expect(find.text('Clinical Collage'), findsOneWidget);
      expect(find.byKey(const Key('save_to_patient_button')), findsOneWidget);
      expect(find.byKey(const Key('save_to_device_button')), findsOneWidget);
    });

    testWidgets('Tapping Save to Patient persists collage and reveals View in Gallery', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CollagePreviewScreen(
            patient: testPatient,
            collageResult: CollageResult(
              bytes: dummyCollageFile.readAsBytesSync(),
              filePath: dummyCollageFile.path,
              width: 100,
              height: 100,
            ),
            exportService: mockExportService,
            queueService: queueService,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('save_to_patient_button')));
      await tester.pumpAndSettle();

      final uploads = await database.getUploadsForPatient(testPatient.id);
      expect(uploads.length, equals(1));
      expect(uploads.first.isCollage, isTrue);

      expect(find.byKey(const Key('view_in_patient_gallery_button')), findsOneWidget);
    });

    testWidgets('Tapping To Device saves to MediaStore independently', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CollagePreviewScreen(
            patient: testPatient,
            collageResult: CollageResult(
              bytes: dummyCollageFile.readAsBytesSync(),
              filePath: dummyCollageFile.path,
              width: 100,
              height: 100,
            ),
            exportService: mockExportService,
            queueService: queueService,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('save_to_device_button')));
      await tester.pumpAndSettle();

      expect(mockExportService.savedGalleryPath, equals(dummyCollageFile.path));
    });
  });
}
