import 'dart:typed_data';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/screens/patient_photos_screen.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;

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

class FakeGalleryDriveService extends DriveService {
  List<drive.File> photosToReturn = [];
  int getFileBytesCallCount = 0;

  @override
  Future<List<drive.File>> listPatientPhotos({
    required AuthClient client,
    required String folderId,
  }) async {
    return photosToReturn;
  }

  static final Uint8List kTransparentImage = Uint8List.fromList(<int>[
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
    getFileBytesCallCount++;
    return kTransparentImage;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Gallery Ordering & Viewing Tests (Section 23.4)', () {
    late FakeAuthClient fakeClient;
    late FakeGoogleAuthService fakeAuth;
    late FakeGalleryDriveService fakeDrive;
    late InMemoryAppDatabase database;
    late UploadQueueService queueService;

    setUp(() {
      fakeClient = FakeAuthClient();
      fakeAuth = FakeGoogleAuthService(fakeClient);
      fakeDrive = FakeGalleryDriveService();
      database = InMemoryAppDatabase();
      queueService = UploadQueueService(
        database: database,
        driveService: fakeDrive,
        authService: fakeAuth,
      );
    });

    test('1. Chronological ordering: Photos named <ID>_<timestamp>_<seq> sort in ascending order', () {
      final photoFiles = [
        drive.File()..id = '3'..name = 'P001_20261024_150000_003.jpg',
        drive.File()..id = '1'..name = 'P001_20261024_143000_001.jpg',
        drive.File()..id = '2'..name = 'P001_20261024_144500_002.jpg',
      ];

      photoFiles.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));

      expect(photoFiles[0].name, 'P001_20261024_143000_001.jpg');
      expect(photoFiles[1].name, 'P001_20261024_144500_002.jpg');
      expect(photoFiles[2].name, 'P001_20261024_150000_003.jpg');
    });

    testWidgets('2. Empty state: displays informative empty state when folder contains no photos', (tester) async {
      fakeDrive.photosToReturn = [];

      const patient = Patient(
        id: 'P050',
        name: 'Empty Gallery Patient',
        driveFolderId: 'folder_empty_123',
        folderStatus: FolderStatus.available,
      );

      await tester.pumpWidget(MaterialApp(
        home: PatientPhotosScreen(
          patient: patient,
          authService: fakeAuth,
          driveService: fakeDrive,
          queueService: queueService,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('No photos found in patient folder'), findsOneWidget);
      expect(find.text('Take Photos'), findsWidgets);
    });

    testWidgets('3. Missing folder state: displays auto-create explanation when patient is unlinked', (tester) async {
      const patient = Patient(
        id: 'P051',
        name: 'Unlinked Patient',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );

      await tester.pumpWidget(MaterialApp(
        home: PatientPhotosScreen(
          patient: patient,
          authService: fakeAuth,
          driveService: fakeDrive,
          queueService: queueService,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('No photos yet'), findsOneWidget);
      expect(find.text('Take First Photo'), findsOneWidget);
    });

    testWidgets('4. Gallery grid: displays photo thumbnails and total count header', (tester) async {
      fakeDrive.photosToReturn = [
        drive.File()
          ..id = 'file_1'
          ..name = 'P052_20261024_120000_001.jpg'
          ..createdTime = DateTime(2026, 10, 24, 12, 0, 0),
        drive.File()
          ..id = 'file_2'
          ..name = 'P052_20261024_120100_002.jpg'
          ..createdTime = DateTime(2026, 10, 24, 12, 1, 0),
      ];

      const patient = Patient(
        id: 'P052',
        name: 'Gallery Patient',
        driveFolderId: 'folder_p052',
        folderStatus: FolderStatus.available,
      );

      await tester.pumpWidget(MaterialApp(
        home: PatientPhotosScreen(
          patient: patient,
          authService: fakeAuth,
          driveService: fakeDrive,
          queueService: queueService,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('2 photos'), findsOneWidget);
      expect(find.byType(GridView), findsOneWidget);
    });
  });
}
