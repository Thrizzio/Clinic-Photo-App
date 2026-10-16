import 'dart:io';

import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;

class _FakeAuthClient extends http.BaseClient implements AuthClient {
  @override
  AccessCredentials get credentials => AccessCredentials(
        AccessToken('Bearer', 'fake-token', DateTime.now().toUtc().add(const Duration(hours: 1))),
        'fake-refresh-token',
        ['https://www.googleapis.com/auth/drive'],
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}

class _FakeAuthService extends GoogleAuthService {
  final AuthClient client;

  _FakeAuthService(this.client);

  @override
  Future<AuthClient?> getAuthenticatedClient() async => client;
}

class _FakeConnectivity implements Connectivity {
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => const Stream.empty();

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.wifi];
}

class _FakeDriveService extends DriveService {
  final Map<String, List<drive.File>> filesByFolder = {};
  int uploadCalls = 0;

  @override
  Future<drive.File?> findPhotoByName({
    required AuthClient client,
    required String folderId,
    required String fileName,
  }) async {
    for (final file in filesByFolder[folderId] ?? const <drive.File>[]) {
      if (file.name == fileName) return file;
    }
    return null;
  }

  @override
  Future<String> uploadPhoto({
    required AuthClient client,
    required File file,
    required String folderId,
    required String fileName,
  }) async {
    uploadCalls++;
    return 'unexpected-new-drive-file';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('durable_upload_recovery_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('restart reconciles a Drive-accepted upload without creating a duplicate', () async {
    const patient = Patient(
      id: 'patient-recovered-upload',
      name: 'Recovered Upload',
      displayName: 'Recovered Upload',
      driveFolderId: 'folder-recovered',
      folderStatus: FolderStatus.available,
    );
    final localFile = File('${tempDir.path}/recovered_upload.jpg')..writeAsBytesSync([1, 2, 3]);
    final item = UploadItem(
      id: 'recovered-upload-item',
      patientId: patient.id,
      driveFolderId: patient.driveFolderId,
      localPath: localFile.path,
      fileName: 'recovered_upload.jpg',
      status: UploadStatus.uploading,
      createdAt: DateTime.now(),
    );

    final persistedDb = InMemoryAppDatabase();
    await persistedDb.upsertPatients([patient]);
    await persistedDb.insertUpload(item);

    final fakeDrive = _FakeDriveService();
    final acceptedFile = drive.File()
      ..id = 'drive-recovered-existing'
      ..name = item.fileName
      ..parents = [patient.driveFolderId!];
    fakeDrive.filesByFolder[patient.driveFolderId!] = [acceptedFile];

    final reopenedDb = InMemoryAppDatabase(
      initialPatients: persistedDb.dumpPatients(),
      initialUploads: persistedDb.dumpUploads(),
    );
    final queue = UploadQueueService(
      database: reopenedDb,
      driveService: fakeDrive,
      authService: _FakeAuthService(_FakeAuthClient()),
      connectivity: _FakeConnectivity(),
      customDocsDirectory: tempDir.path,
    );
    addTearDown(queue.dispose);

    await queue.processQueue();

    final recovered = (await reopenedDb.getAllUploads()).single;
    expect(recovered.status, UploadStatus.uploaded);
    expect(recovered.driveFileId, acceptedFile.id);
    expect(fakeDrive.uploadCalls, 0);
    expect(localFile.existsSync(), isTrue);
  });
}
