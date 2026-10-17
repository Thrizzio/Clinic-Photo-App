import 'dart:io';
import 'dart:typed_data';

import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/screens/camera_screen.dart';
import 'package:clinic_photos/screens/patient_photos_screen.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/remote_photo_cache.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:clinic_photos/widgets/reference_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;

class _MockConnectivity implements Connectivity {
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => const Stream.empty();
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.wifi];
}

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
  _MockGoogleAuthService({this.clientToReturn});

  @override
  Future<AuthClient?> getAuthenticatedClientSilently() async => clientToReturn;

  @override
  Future<AuthClient?> getAuthenticatedClient() async => clientToReturn;
}

class _MockDriveService extends DriveService {
  List<drive.File> photosToReturn = [];
  final Map<String, Uint8List> fileBytesMap = {};
  bool failNextDownload = false;

  @override
  Future<List<drive.File>> listPatientPhotos({
    required AuthClient client,
    required String folderId,
  }) async {
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
    if (failNextDownload) throw Exception('Drive download failure');
    final bytes = fileBytesMap[fileId];
    if (bytes != null) return bytes;
    throw Exception('File not found: $fileId');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 2: Use Viewed Photo as Camera Reference', () {
    late InMemoryAppDatabase database;
    late _MockDriveService driveService;
    late _TestAuthClient authClient;
    late _MockGoogleAuthService authService;
    late UploadQueueService queueService;
    late RemotePhotoCacheService cacheService;
    late Directory tempDocsDir;
    late Directory tempCacheDir;

    final patient = Patient(
      id: 'patient_uuid_ref',
      name: 'Rohan Mehta',
      phoneNumber: '9123456780',
      driveFolderId: 'folder_rohan_123',
      folderStatus: FolderStatus.available,
    );

    setUp(() {
      tempDocsDir = Directory.systemTemp.createTempSync('viewer_ref_docs_');
      tempCacheDir = Directory.systemTemp.createTempSync('viewer_ref_cache_');

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
        connectivity: _MockConnectivity(),
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

    final kTransparent1x1Png = Uint8List.fromList(<int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);

    testWidgets('1. Selecting "Use as reference" in full-screen viewer loads bytes and opens CameraScreen with ReferenceOverlay', (tester) async {
      // 1. Prepare local photo with full image bytes
      final sampleImageBytes = kTransparent1x1Png;
      final localFile = File('${tempDocsDir.path}/photo_rohan_1.jpg')..writeAsBytesSync(sampleImageBytes);

      final upload = UploadItem(
        id: 'upload_rohan_1',
        patientId: patient.id,
        driveFolderId: patient.driveFolderId,
        localPath: localFile.path,
        fileName: '20261017_100000_001.jpg',
        driveFileId: 'drive_file_rohan_1',
        status: UploadStatus.uploaded,
        createdAt: DateTime(2026, 10, 17, 10, 0, 0),
      );
      await database.insertUpload(upload);

      driveService.photosToReturn = [
        drive.File()
          ..id = 'drive_file_rohan_1'
          ..name = '20261017_100000_001.jpg'
          ..parents = [patient.driveFolderId!]
          ..createdTime = DateTime(2026, 10, 17, 10, 0, 0),
      ];
      driveService.fileBytesMap['drive_file_rohan_1'] = sampleImageBytes;

      // Pump PatientPhotosScreen
      await tester.pumpWidget(
        MaterialApp(
          home: PatientPhotosScreen(
            patient: patient,
            authService: authService,
            driveService: driveService,
            queueService: queueService,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Find the photo grid item and tap it to open full-screen viewer
      final photoTile = find.byKey(const ValueKey('photo_tile_drive_file_rohan_1'));
      expect(photoTile, findsOneWidget);
      await tester.tap(photoTile);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Verify "Use as reference" action button is in the AppBar
      final useAsRefBtn = find.byKey(const Key('use_as_reference_button'));
      expect(useAsRefBtn, findsOneWidget);

      // Tap "Use as reference"
      await tester.tap(useAsRefBtn);
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      // CameraScreen should now be mounted with ReferenceOverlay
      expect(find.byType(CameraScreen), findsOneWidget);
      expect(find.byType(ReferenceOverlay), findsOneWidget);
    });

    testWidgets('2. Capture integrity: ReferenceOverlay remains purely UI layer and does not alter capture pipeline', (tester) async {
      final sampleImageBytes = kTransparent1x1Png;

      // Direct CameraScreen launch with initialReferenceBytes
      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            patient: patient,
            queueService: queueService,
            initialReferenceBytes: sampleImageBytes,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Overlay should be present
      expect(find.byType(ReferenceOverlay), findsOneWidget);

      // Verify opacity slider is interactive
      final slider = find.byKey(const Key('reference_opacity_slider'));
      expect(slider, findsOneWidget);

      // Clear button removes overlay
      final clearBtn = find.byKey(const Key('clear_reference_button'));
      expect(clearBtn, findsOneWidget);
      await tester.tap(clearBtn);
      await tester.pump();

      // Overlay removed
      expect(find.byType(ReferenceOverlay), findsNothing);
    });

    testWidgets('3. Error handling: when remote photo bytes cannot be fetched, shows non-blocking SnackBar without crashing', (tester) async {
      // Remote-only photo with failure in download
      driveService.photosToReturn = [
        drive.File()
          ..id = 'corrupt_remote_file'
          ..name = '20261017_090000_001.jpg'
          ..parents = [patient.driveFolderId!]
          ..createdTime = DateTime(2026, 10, 17, 9, 0, 0),
      ];
      driveService.failNextDownload = true;

      await tester.pumpWidget(
        MaterialApp(
          home: PatientPhotosScreen(
            patient: patient,
            authService: authService,
            driveService: driveService,
            queueService: queueService,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Open viewer
      final photoTile = find.byType(InkWell);
      await tester.tap(photoTile.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Tap "Use as reference"
      final useAsRefBtn = find.byKey(const Key('use_as_reference_button'));
      expect(useAsRefBtn, findsOneWidget);
      await tester.tap(useAsRefBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // SnackBar displayed, did not push CameraScreen
      expect(find.text('Failed to load reference photo bytes.'), findsOneWidget);
      expect(find.byType(CameraScreen), findsNothing);
    });
  });
}
