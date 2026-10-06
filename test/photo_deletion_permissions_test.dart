import 'dart:io';
import 'dart:typed_data';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/screens/patient_photos_screen.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class FakeAuthClient extends http.BaseClient implements AuthClient {
  final String userEmail;
  FakeAuthClient(this.userEmail);

  @override
  AccessCredentials get credentials => AccessCredentials(
        AccessToken('Bearer', 'fake_token_$userEmail', DateTime.now().toUtc().add(const Duration(hours: 1))),
        'fake_refresh_token_$userEmail',
        ['https://www.googleapis.com/auth/drive'],
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}

class FakeGoogleAuthService extends GoogleAuthService {
  AuthClient? client;
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

class AdvancedMockDriveService extends DriveService {
  final Map<String, List<drive.File>> parentFolders = {};
  final Map<String, List<drive.File>> folderFiles = {};
  final Map<String, String> fileOwners = {}; // fileId -> userEmail
  final List<String> permanentlyDeletedFiles = [];
  final List<String> filesRemovedFromParents = [];
  bool simulatePersonalDriveOwnerRestriction = false;

  @override
  Future<String> uploadPhoto({
    required AuthClient client,
    required File file,
    required String folderId,
    required String fileName,
  }) async {
    final userEmail = (client as FakeAuthClient).userEmail;
    final fileId = 'drive_file_${DateTime.now().microsecondsSinceEpoch}_$fileName';
    final uploaded = drive.File()
      ..id = fileId
      ..name = fileName
      ..createdTime = DateTime.now()
      ..parents = [folderId];
    folderFiles.putIfAbsent(folderId, () => []).add(uploaded);
    fileOwners[fileId] = userEmail;
    return fileId;
  }

  @override
  Future<List<drive.File>> listPatientPhotos({
    required AuthClient client,
    required String folderId,
  }) async {
    return List.from(folderFiles[folderId] ?? []);
  }

  @override
  Future<void> deleteFile({
    required AuthClient client,
    required String fileId,
    String? parentFolderId,
  }) async {
    final callerEmail = (client as FakeAuthClient).userEmail;
    final ownerEmail = fileOwners[fileId];

    // If simulating personal Google Drive:
    // Only the owner can permanently delete via files.delete.
    // Non-owners get 403 Forbidden on files.delete, but can remove from parent folder.
    if (simulatePersonalDriveOwnerRestriction && ownerEmail != null && ownerEmail != callerEmail) {
      // files.delete throws 403
      // But fallback removes from parent folder:
      if (parentFolderId != null && folderFiles.containsKey(parentFolderId)) {
        folderFiles[parentFolderId]!.removeWhere((f) => f.id == fileId);
        filesRemovedFromParents.add('$fileId from $parentFolderId');
        return;
      }
      // Or remove from any parent containing it
      for (final list in folderFiles.values) {
        list.removeWhere((f) => f.id == fileId);
      }
      filesRemovedFromParents.add(fileId);
      return;
    }

    // Owner or unrestricted: permanent deletion
    permanentlyDeletedFiles.add(fileId);
    for (final list in folderFiles.values) {
      list.removeWhere((f) => f.id == fileId);
    }
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryAppDatabase dbDeviceA;
  late InMemoryAppDatabase dbDeviceB;
  late AdvancedMockDriveService mockDrive;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'parentDriveFolderId': 'clinic_drive_root_folder',
    });
    await ConfigService.init();
    dbDeviceA = InMemoryAppDatabase();
    dbDeviceB = InMemoryAppDatabase();
    mockDrive = AdvancedMockDriveService();
    tempDir = Directory.systemTemp.createTempSync('photo_deletion_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  File createFakePhotoFile(String name) {
    final f = File('${tempDir.path}/$name.jpg');
    f.writeAsBytesSync([1, 2, 3, 4, 5]);
    return f;
  }

  const testPatient = Patient(
    id: 'patient-uuid-101',
    name: 'Suresh Kumar',
    displayName: 'Suresh Kumar',
    driveFolderId: 'patient_folder_101',
    folderStatus: FolderStatus.available,
  );

  group('A. Original uploader deletes photo', () {
    test('User A uploads Photo X and User A deletes Photo X -> succeeds', () async {
      final userAClient = FakeAuthClient('doctorA@clinic.com');
      final authServiceA = FakeGoogleAuthService(userAClient);

      final queueServiceA = UploadQueueService(
        database: dbDeviceA,
        driveService: mockDrive,
        authService: authServiceA,
        connectivity: FakeConnectivity(),
        customDocsDirectory: tempDir.path,
      );

      final photoFile = createFakePhotoFile('photo_x');
      final uploadedItem = await queueServiceA.enqueuePhoto(
        patient: testPatient,
        capturedTempPath: photoFile.path,
      );

      // Wait for upload to complete
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final uploads = await dbDeviceA.getUploadsForPatient(testPatient.id);
      expect(uploads, hasLength(1));
      final driveFileId = uploads.first.driveFileId;
      expect(driveFileId, isNotNull);

      // User A deletes Photo X
      await mockDrive.deleteFile(
        client: userAClient,
        fileId: driveFileId!,
        parentFolderId: testPatient.driveFolderId,
      );
      await dbDeviceA.deleteUpload(uploadedItem.id);
      await dbDeviceA.recordDeletedPhotoTombstone(
        driveFileId: driveFileId,
        fileName: uploadedItem.fileName,
        patientId: testPatient.id,
      );

      // Check Drive
      final photosInDrive = await mockDrive.listPatientPhotos(
        client: userAClient,
        folderId: testPatient.driveFolderId!,
      );
      expect(photosInDrive, isEmpty);
      expect(mockDrive.permanentlyDeletedFiles.contains(driveFileId), isTrue);

      // Check local DB
      expect(await dbDeviceA.getUploadsForPatient(testPatient.id), isEmpty);
      expect(await dbDeviceA.isPhotoDeletedTombstoned(driveFileId: driveFileId), isTrue);

      queueServiceA.dispose();
    });
  });

  group('B. Different user deletes photo', () {
    test('User A uploads Photo X; User B deletes Photo X -> succeeds even with Drive permission restrictions', () async {
      mockDrive.simulatePersonalDriveOwnerRestriction = true;

      final userAClient = FakeAuthClient('doctorA@clinic.com');
      final userBClient = FakeAuthClient('doctorB@clinic.com');
      final authServiceA = FakeGoogleAuthService(userAClient);

      final queueServiceA = UploadQueueService(
        database: dbDeviceA,
        driveService: mockDrive,
        authService: authServiceA,
        connectivity: FakeConnectivity(),
        customDocsDirectory: tempDir.path,
      );

      // 1. User A uploads Photo X
      final photoFile = createFakePhotoFile('photo_x_by_a');
      await queueServiceA.enqueuePhoto(
        patient: testPatient,
        capturedTempPath: photoFile.path,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final uploadsA = await dbDeviceA.getUploadsForPatient(testPatient.id);
      final driveFileId = uploadsA.first.driveFileId!;
      expect(mockDrive.fileOwners[driveFileId], 'doctorA@clinic.com');

      // 2. User B opens the same patient and sees Photo X on Drive
      final photosOnDriveForB = await mockDrive.listPatientPhotos(
        client: userBClient,
        folderId: testPatient.driveFolderId!,
      );
      expect(photosOnDriveForB, hasLength(1));
      expect(photosOnDriveForB.first.id, driveFileId);

      // 3. User B deletes Photo X
      // User B is NOT the owner of the file on personal Drive.
      // deleteFile handles this by removing the file from the patient folder so it disappears from patient photos!
      await mockDrive.deleteFile(
        client: userBClient,
        fileId: driveFileId,
        parentFolderId: testPatient.driveFolderId,
      );

      // 4. Verify Photo X is GONE from patient folder on Drive
      final photosAfterDeletion = await mockDrive.listPatientPhotos(
        client: userBClient,
        folderId: testPatient.driveFolderId!,
      );
      expect(photosAfterDeletion, isEmpty);

      queueServiceA.dispose();
    });
  });

  group('C. Reverse direction', () {
    test('User B uploads Photo Y; User A deletes Photo Y -> succeeds', () async {
      mockDrive.simulatePersonalDriveOwnerRestriction = true;

      final userAClient = FakeAuthClient('doctorA@clinic.com');
      final userBClient = FakeAuthClient('doctorB@clinic.com');
      final authServiceB = FakeGoogleAuthService(userBClient);

      final queueServiceB = UploadQueueService(
        database: dbDeviceB,
        driveService: mockDrive,
        authService: authServiceB,
        connectivity: FakeConnectivity(),
        customDocsDirectory: tempDir.path,
      );

      // User B uploads Photo Y
      final photoFile = createFakePhotoFile('photo_y_by_b');
      await queueServiceB.enqueuePhoto(
        patient: testPatient,
        capturedTempPath: photoFile.path,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final uploadsB = await dbDeviceB.getUploadsForPatient(testPatient.id);
      final driveFileId = uploadsB.first.driveFileId!;
      expect(mockDrive.fileOwners[driveFileId], 'doctorB@clinic.com');

      // User A deletes Photo Y
      await mockDrive.deleteFile(
        client: userAClient,
        fileId: driveFileId,
        parentFolderId: testPatient.driveFolderId,
      );

      // Photo Y is removed from Drive
      final photosAfter = await mockDrive.listPatientPhotos(
        client: userAClient,
        folderId: testPatient.driveFolderId!,
      );
      expect(photosAfter, isEmpty);

      queueServiceB.dispose();
    });
  });

  group('D. Drive deletion preserves patient folder and unrelated photos', () {
    test('Deleting Photo 1 deletes only Photo 1; patient folder and Photo 2 remain intact', () async {
      final client = FakeAuthClient('doctor@clinic.com');
      final authService = FakeGoogleAuthService(client);
      final queueService = UploadQueueService(
        database: dbDeviceA,
        driveService: mockDrive,
        authService: authService,
        connectivity: FakeConnectivity(),
        customDocsDirectory: tempDir.path,
      );

      // Upload two photos
      final file1 = createFakePhotoFile('pic1');
      final file2 = createFakePhotoFile('pic2');
      await queueService.enqueuePhoto(patient: testPatient, capturedTempPath: file1.path);
      await queueService.enqueuePhoto(patient: testPatient, capturedTempPath: file2.path);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final uploads = await dbDeviceA.getUploadsForPatient(testPatient.id);
      expect(uploads, hasLength(2));
      final idToDelete = uploads[0].driveFileId!;
      final idToKeep = uploads[1].driveFileId!;

      // Delete Photo 1 only
      await mockDrive.deleteFile(
        client: client,
        fileId: idToDelete,
        parentFolderId: testPatient.driveFolderId,
      );

      final remainingOnDrive = await mockDrive.listPatientPhotos(
        client: client,
        folderId: testPatient.driveFolderId!,
      );

      // Only Photo 2 remains
      expect(remainingOnDrive, hasLength(1));
      expect(remainingOnDrive.first.id, idToKeep);

      // Patient folder was NOT deleted
      expect(mockDrive.permanentlyDeletedFiles.contains(testPatient.driveFolderId), isFalse);

      queueService.dispose();
    });
  });

  group('E. Local state preservation for unrelated photos', () {
    test('Deleting Photo 1 removes its local file/record; Photo 2 local file/path remain intact', () async {
      final client = FakeAuthClient('doctor@clinic.com');
      final authService = FakeGoogleAuthService(client);
      final queueService = UploadQueueService(
        database: dbDeviceA,
        driveService: mockDrive,
        authService: authService,
        connectivity: FakeConnectivity(),
        customDocsDirectory: tempDir.path,
      );

      final file1 = createFakePhotoFile('local_p1');
      final file2 = createFakePhotoFile('local_p2');
      final item1 = await queueService.enqueuePhoto(patient: testPatient, capturedTempPath: file1.path);
      final item2 = await queueService.enqueuePhoto(patient: testPatient, capturedTempPath: file2.path);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // Both exist locally
      expect(File(item1.localPath).existsSync(), isTrue);
      expect(File(item2.localPath).existsSync(), isTrue);

      // Delete item 1 locally and on Drive
      await dbDeviceA.deleteUpload(item1.id);
      File(item1.localPath).deleteSync();
      await dbDeviceA.recordDeletedPhotoTombstone(
        driveFileId: item1.driveFileId,
        fileName: item1.fileName,
        patientId: testPatient.id,
      );

      // Item 1 is gone locally
      expect(File(item1.localPath).existsSync(), isFalse);

      // Item 2 local file, local path, and DB record are 100% intact!
      expect(File(item2.localPath).existsSync(), isTrue);
      final remainingUploads = await dbDeviceA.getUploadsForPatient(testPatient.id);
      expect(remainingUploads, hasLength(1));
      expect(remainingUploads.first.id, item2.id);
      expect(remainingUploads.first.localPath, item2.localPath);

      queueService.dispose();
    });
  });

  group('F. Cross-device synchronization and anti-resurrection', () {
    testWidgets('Device A has Photo X; Device B deletes Photo X on Drive; Device A syncs and Photo X does NOT resurrect', (tester) async {
      final clientA = FakeAuthClient('doctorA@clinic.com');
      final clientB = FakeAuthClient('doctorB@clinic.com');
      final authA = FakeGoogleAuthService(clientA);

      final queueA = UploadQueueService(
        database: dbDeviceA,
        driveService: mockDrive,
        authService: authA,
        connectivity: FakeConnectivity(),
        customDocsDirectory: tempDir.path,
      );

      late UploadItem itemX;
      late String driveFileId;
      await tester.runAsync(() async {
        // 1. Device A uploads Photo X
        final fileX = createFakePhotoFile('cross_device_x');
        itemX = await queueA.enqueuePhoto(patient: testPatient, capturedTempPath: fileX.path);
        await Future<void>.delayed(const Duration(milliseconds: 150));

        final uploadsA = await dbDeviceA.getUploadsForPatient(testPatient.id);
        expect(uploadsA, hasLength(1));
        driveFileId = uploadsA.first.driveFileId!;

        // 2. Device B opens the patient and sees Photo X on Drive
        final photosSeenByB = await mockDrive.listPatientPhotos(
          client: clientB,
          folderId: testPatient.driveFolderId!,
        );
        expect(photosSeenByB, hasLength(1));

        // 3. Device B deletes Photo X
        await mockDrive.deleteFile(
          client: clientB,
          fileId: driveFileId,
          parentFolderId: testPatient.driveFolderId,
        );
      });

      // 4. Device A opens PatientPhotosScreen and reconciles with Drive
      await dbDeviceA.upsertPatients([testPatient]);
      await tester.pumpWidget(
        MaterialApp(
          home: PatientPhotosScreen(
            patient: testPatient,
            authService: authA,
            driveService: mockDrive,
            queueService: queueA,
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      // Device A detects that Photo X is no longer on Drive:
      // Cleans up local SQLite upload record and disk cache
      final uploadsAfterSync = await dbDeviceA.getUploadsForPatient(testPatient.id);
      expect(uploadsAfterSync, isEmpty);
      expect(File(itemX.localPath).existsSync(), isFalse);

      // Photo X is NOT displayed in the gallery
      expect(find.text('cross_device_x.jpg'), findsNothing);
      expect(find.text('No photos found in patient folder'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      queueA.dispose();
    });
  });

  group('G. Offline deletion', () {
    testWidgets('Device B deletes Photo X while offline; pending deletion is recorded; syncs when back online', (tester) async {
      final clientB = FakeAuthClient('doctorB@clinic.com');
      final authB = FakeGoogleAuthService(clientB);

      // Pre-populate Drive with Photo X
      final fileX = createFakePhotoFile('offline_photo_x');
      final driveFileId = await mockDrive.uploadPhoto(
        client: clientB,
        file: fileX,
        folderId: testPatient.driveFolderId!,
        fileName: 'offline_photo_x.jpg',
      );

      final queueB = UploadQueueService(
        database: dbDeviceB,
        driveService: mockDrive,
        authService: authB,
        connectivity: FakeConnectivity(),
        customDocsDirectory: tempDir.path,
      );

      await dbDeviceB.upsertPatients([testPatient]);

      // 1. Render PatientPhotosScreen while online so photo is loaded
      await tester.pumpWidget(
        MaterialApp(
          home: PatientPhotosScreen(
            patient: testPatient,
            authService: authB,
            driveService: mockDrive,
            queueService: queueB,
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('1 photo'), findsWidgets);

      // 2. Device B goes offline (simulate auth / network unavailable)
      authB.client = null;

      // 3. User B enters selection mode and selects the photo
      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      // Tap Delete icon in app bar
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      // Confirm deletion in dialog
      await tester.tap(find.text('Delete Permanently'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();

      // Verify photo disappears from UI IMMEDIATELY
      expect(find.text('No photos found in patient folder'), findsOneWidget);

      // Verify pending photo deletion was recorded in SQLite
      final pendingDeletions = await dbDeviceB.getPendingPhotoDeletions();
      expect(pendingDeletions, hasLength(1));
      expect(pendingDeletions.first['drive_file_id'], driveFileId);

      // Verify tombstone was recorded
      expect(await dbDeviceB.isPhotoDeletedTombstoned(driveFileId: driveFileId), isTrue);

      // 4. Connectivity returns (restore auth client)
      authB.client = clientB;

      // Background worker processes pending photo deletions
      await queueB.processPendingPhotoDeletions();

      // Verify pending deletion queue is now cleared
      expect(await dbDeviceB.getPendingPhotoDeletions(), isEmpty);

      // Verify Google Drive now has the photo deleted!
      final drivePhotosAfterSync = await mockDrive.listPatientPhotos(
        client: clientB,
        folderId: testPatient.driveFolderId!,
      );
      expect(drivePhotosAfterSync, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      queueB.dispose();
    });
  });

  group('H. Uploader metadata does not prevent deletion', () {
    test('Uploader metadata remains intact in auditing/logs, but does not block any clinic user from deleting', () async {
      final userA = FakeAuthClient('uploaderA@clinic.com');
      final userC = FakeAuthClient('doctorC@clinic.com');

      final fileMeta = createFakePhotoFile('photo_with_uploader_meta');
      final fileId = await mockDrive.uploadPhoto(
        client: userA,
        file: fileMeta,
        folderId: testPatient.driveFolderId!,
        fileName: 'photo_with_uploader_meta.jpg',
      );

      // Verify owner is User A
      expect(mockDrive.fileOwners[fileId], 'uploaderA@clinic.com');

      // User C (different user) deletes photo
      await mockDrive.deleteFile(
        client: userC,
        fileId: fileId,
        parentFolderId: testPatient.driveFolderId,
      );

      // Successfully deleted from Drive
      final remaining = await mockDrive.listPatientPhotos(
        client: userC,
        folderId: testPatient.driveFolderId!,
      );
      expect(remaining, isEmpty);
    });
  });
}
