import 'dart:io';
import 'dart:typed_data';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/screens/camera_screen.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/remote_photo_cache.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;

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

class _MockGoogleAuthService extends GoogleAuthService {
  final AuthClient? clientToReturn;
  bool returnNullClient = false;

  _MockGoogleAuthService({this.clientToReturn});

  @override
  Future<AuthClient?> getAuthenticatedClientSilently() async {
    if (returnNullClient) return null;
    return clientToReturn;
  }

  @override
  Future<AuthClient?> getAuthenticatedClient() async {
    if (returnNullClient) return null;
    return clientToReturn;
  }
}

class _MockDriveService extends DriveService {
  List<drive.File> photosToReturn = [];
  bool simulateOffline = false;
  int listPhotosCalls = 0;
  final Map<String, Uint8List> fileBytesMap = {};

  @override
  Future<List<drive.File>> listPatientPhotos({
    required AuthClient client,
    required String folderId,
  }) async {
    listPhotosCalls++;
    if (simulateOffline) {
      throw Exception('Network unreachable');
    }
    return photosToReturn;
  }

  @override
  Future<Uint8List?> getThumbnailBytes({
    required AuthClient client,
    required String fileId,
    String? thumbnailLink,
  }) async {
    return fileBytesMap[fileId];
  }

  @override
  Future<Uint8List> getFileBytes({
    required AuthClient client,
    required String fileId,
  }) async {
    final bytes = fileBytesMap[fileId];
    if (bytes != null) return bytes;
    throw Exception('File not found');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 1: Shared Cloud Photo Discovery & Reference Picker', () {
    late InMemoryAppDatabase database;
    late _MockDriveService driveService;
    late _TestAuthClient authClient;
    late _MockGoogleAuthService authService;
    late UploadQueueService queueService;
    late RemotePhotoCacheService cacheService;
    late Directory tempDocsDir;
    late Directory tempCacheDir;

    final patient = Patient(
      id: 'patient_uuid_101',
      name: 'Priya Sharma',
      phoneNumber: '9876543210',
      driveFolderId: 'drive_folder_priya',
      folderStatus: FolderStatus.available,
    );

    setUp(() {
      tempDocsDir = Directory.systemTemp.createTempSync('shared_photos_test_');
      tempCacheDir = Directory.systemTemp.createTempSync('shared_cache_test_');

      database = InMemoryAppDatabase(initialPatients: {patient.id: patient});
      driveService = _MockDriveService();
      authClient = _TestAuthClient();
      authService = _MockGoogleAuthService(clientToReturn: authClient);
      cacheService = RemotePhotoCacheService(
        database: database,
        driveService: driveService,
        customBaseDirectory: tempCacheDir.path,
      );
      queueService = UploadQueueService(
        database: database,
        authService: authService,
        driveService: driveService,
        remotePhotoCacheService: cacheService,
        customDocsDirectory: tempDocsDir.path,
      );
    });

    tearDown(() {
      queueService.dispose();
      try {
        tempDocsDir.deleteSync(recursive: true);
      } catch (_) {}
      try {
        tempCacheDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    testWidgets('1. Remote photos with NO prior local upload record appear in picker with thumbnails', (tester) async {
      final sampleThumbBytes = Uint8List.fromList([10, 20, 30, 40]);
      driveService.fileBytesMap['remote_file_dev_b'] = sampleThumbBytes;

      // Photo captured on Device B: exists in Drive folder, NOT in Device A's local SQLite
      driveService.photosToReturn = [
        drive.File()
          ..id = 'remote_file_dev_b'
          ..name = '20261017_150000_001.jpg'
          ..parents = ['drive_folder_priya']
          ..createdTime = DateTime(2026, 10, 17, 15, 0, 0),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            patient: patient,
            queueService: queueService,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Tap Reference button on camera screen
      final refBtn = find.byTooltip('Reference photo');
      expect(refBtn, findsOneWidget);
      await tester.tap(refBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      // Picker bottom sheet opens
      expect(find.text('Choose reference photo'), findsOneWidget);

      // Verify that remote photo from Device B appears in the picker
      expect(find.textContaining('15:00:00'), findsOneWidget);
    });

    testWidgets('2. Deduplication: remote photos that match local upload records are not duplicated', (tester) async {
      // Local record already in SQLite
      await database.insertUpload(
        UploadItem(
          id: 'local_upload_1',
          patientId: patient.id,
          driveFolderId: patient.driveFolderId,
          localPath: '/tmp/photo1.jpg',
          fileName: '20261017_120000_001.jpg',
          driveFileId: 'drive_file_existing',
          status: UploadStatus.uploaded,
          createdAt: DateTime(2026, 10, 17, 12, 0, 0),
        ),
      );

      // Drive returns the same file
      driveService.photosToReturn = [
        drive.File()
          ..id = 'drive_file_existing'
          ..name = '20261017_120000_001.jpg'
          ..parents = ['drive_folder_priya']
          ..createdTime = DateTime(2026, 10, 17, 12, 0, 0),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            patient: patient,
            queueService: queueService,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byTooltip('Reference photo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      // There should only be 1 tile rendered for this photo, not 2
      expect(find.textContaining('12:00:00'), findsOneWidget);
    });

    testWidgets('3. Graceful offline/network failure: picker still usable with local photos', (tester) async {
      driveService.simulateOffline = true;

      final localFile = File('${tempDocsDir.path}/offline.jpg')..writeAsBytesSync([1, 2, 3]);
      await database.insertUpload(
        UploadItem(
          id: 'local_offline_1',
          patientId: patient.id,
          driveFolderId: patient.driveFolderId,
          localPath: localFile.path,
          fileName: '20261017_110000_001.jpg',
          driveFileId: 'drive_offline_file',
          status: UploadStatus.uploaded,
          createdAt: DateTime(2026, 10, 17, 11, 0, 0),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            patient: patient,
            queueService: queueService,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byTooltip('Reference photo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      // Does not crash; local candidate remains available
      expect(find.text('Choose reference photo'), findsOneWidget);
      expect(find.textContaining('11:00:00'), findsOneWidget);
    });

    testWidgets('4. Authentication failure: picker functions without throwing unhandled exceptions', (tester) async {
      authService.returnNullClient = true;

      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            patient: patient,
            queueService: queueService,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byTooltip('Reference photo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(find.text('Choose reference photo'), findsOneWidget);
      expect(find.text('No previous local or Drive photos are available as a reference.'), findsOneWidget);
    });
  });
}
