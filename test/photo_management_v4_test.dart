import 'dart:io';
import 'dart:typed_data';
import 'package:clinic_photos/models/capture_session.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/screens/patient_photos_screen.dart';
import 'package:clinic_photos/screens/unassigned_photos_screen.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/patient_folder_service.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/upload_queue.dart';
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

class FakeV4DriveService extends DriveService {
  // Map of folderId -> list of drive.File
  final Map<String, List<drive.File>> folderFiles = {};
  final List<String> deletedFileIds = [];
  final List<String> deletedFolderIds = [];
  final List<({String fileId, String source, String target})> moveOperations = [];
  bool failNextMove = false;
  String? failMoveFileId;
  bool failNextDelete = false;
  String? failDeleteFileId;

  @override
  Future<List<drive.File>> listPatientPhotos({
    required AuthClient client,
    required String folderId,
  }) async {
    return List.from(folderFiles[folderId] ?? []);
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
  Future<String> getOrCreateUnassignedRootFolder({
    required AuthClient client,
    required String parentFolderId,
  }) async {
    return 'fake_unassigned_root';
  }

  @override
  Future<String> getOrCreateUnassignedSessionFolder({
    required AuthClient client,
    required String unassignedRootId,
    required String sessionFolderTimestamp,
  }) async {
    final folderId = 'session_folder_$sessionFolderTimestamp';
    folderFiles.putIfAbsent(folderId, () => []);
    return folderId;
  }

  @override
  Future<void> moveFile({
    required AuthClient client,
    required String fileId,
    required String sourceFolderId,
    required String targetFolderId,
  }) async {
    if (failNextMove || (failMoveFileId != null && failMoveFileId == fileId)) {
      throw StateError('Simulated Drive moveFile failure for $fileId');
    }

    moveOperations.add((fileId: fileId, source: sourceFolderId, target: targetFolderId));

    // Remove from source
    final sourceList = folderFiles[sourceFolderId] ?? [];
    final fileIdx = sourceList.indexWhere((f) => f.id == fileId);
    drive.File? fileToMove;
    if (fileIdx != -1) {
      fileToMove = sourceList.removeAt(fileIdx);
    } else {
      fileToMove = drive.File()..id = fileId..name = 'photo_$fileId.jpg';
    }

    // Add to target
    fileToMove.parents = [targetFolderId];
    folderFiles.putIfAbsent(targetFolderId, () => []).add(fileToMove);
  }

  @override
  Future<void> deleteFile({
    required AuthClient client,
    required String fileId,
  }) async {
    if (failNextDelete || (failDeleteFileId != null && failDeleteFileId == fileId)) {
      throw StateError('Simulated Drive deleteFile failure for $fileId');
    }

    deletedFileIds.add(fileId);

    // Remove file from all folders
    for (final list in folderFiles.values) {
      list.removeWhere((f) => f.id == fileId);
    }

    if (folderFiles.containsKey(fileId)) {
      deletedFolderIds.add(fileId);
      folderFiles.remove(fileId);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryAppDatabase database;
  late FakeAuthClient fakeClient;
  late FakeGoogleAuthService fakeAuthService;
  late FakeV4DriveService fakeDriveService;
  late UploadQueueService queueService;
  late ConfigService configService;
  late PatientFolderService folderService;
  late Directory tempRootDir;

  final testPatient = Patient(
    id: 'test-patient-uuid-1',
    displayName: 'Rahul Sharma',
    normalizedName: 'rahul sharma',
    phoneDisplay: '9876543210',
    normalizedPhone: '9876543210',
    driveFolderId: 'patient_folder_rahul',
    folderStatus: FolderStatus.available,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'parentDriveFolderId': 'clinic_parent_root',
      'spreadsheetId': 'test_sheet',
      'sheetTabName': 'Visits',
    });
    configService = await ConfigService.init();

    database = InMemoryAppDatabase(initialPatients: {testPatient.id: testPatient});
    tempRootDir = await Directory.systemTemp.createTemp('clinic_v4_photo_mgmt_test_');

    fakeClient = FakeAuthClient();
    fakeAuthService = FakeGoogleAuthService(fakeClient);
    fakeDriveService = FakeV4DriveService();

    // Populate patient Drive folder with 3 test photos
    fakeDriveService.folderFiles['patient_folder_rahul'] = [
      drive.File()
        ..id = 'drive_file_1'
        ..name = '20261001_100000_000_001.jpg'
        ..parents = ['patient_folder_rahul']
        ..createdTime = DateTime(2026, 10, 1, 10, 0, 0),
      drive.File()
        ..id = 'drive_file_2'
        ..name = '20261001_100500_000_002.jpg'
        ..parents = ['patient_folder_rahul']
        ..createdTime = DateTime(2026, 10, 1, 10, 5, 0),
      drive.File()
        ..id = 'drive_file_3'
        ..name = '20261001_101000_000_003.jpg'
        ..parents = ['patient_folder_rahul']
        ..createdTime = DateTime(2026, 10, 1, 10, 10, 0),
    ];

    queueService = UploadQueueService(
      database: database,
      authService: fakeAuthService,
      driveService: fakeDriveService,
      customDocsDirectory: tempRootDir.path,
    );

    folderService = PatientFolderService(
      driveService: fakeDriveService,
      configService: configService,
      authService: fakeAuthService,
      sheetsService: SheetsService(),
      database: database,
    );
  });

  tearDown(() async {
    queueService.dispose();
    if (await tempRootDir.exists()) {
      await tempRootDir.delete(recursive: true);
    }
  });

  Widget buildPatientPhotosScreen() {
    return MaterialApp(
      home: PatientPhotosScreen(
        patient: testPatient,
        authService: fakeAuthService,
        driveService: fakeDriveService,
        queueService: queueService,
        folderService: folderService,
      ),
    );
  }

  group('A. Multi-Select in Patient Photo Viewer', () {
    testWidgets('enters selection mode via Select button, selects one, multiple, select all, deselect, cancel', (tester) async {
      await tester.pumpWidget(buildPatientPhotosScreen());
      await tester.pumpAndSettle();

      expect(find.text('Rahul Sharma'), findsOneWidget);
      expect(find.textContaining('3 photos'), findsWidgets);

      // Verify normal mode actions
      expect(find.byIcon(Icons.checklist), findsOneWidget);
      expect(find.text('Select All'), findsNothing);

      // 1. Enter selection mode via checklist icon
      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();

      expect(find.text('0 selected'), findsOneWidget);
      expect(find.text('Select All'), findsOneWidget);

      // 2. Select first photo by tapping its tile
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      // 3. Select second photo by tapping second tile
      await tester.tap(find.byType(InkWell).at(1));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      // 4. Deselect second photo
      await tester.tap(find.byType(InkWell).at(1));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      // 5. Tap Select All -> selects all 3
      await tester.tap(find.text('Select All'));
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);
      expect(find.text('Deselect All'), findsOneWidget);

      // 6. Tap Deselect All -> exits selection mode
      await tester.tap(find.text('Deselect All'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.checklist), findsOneWidget);

      // 7. Long-press enters selection mode with that photo selected
      await tester.longPress(find.byType(InkWell).first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      // 8. Cancel via close (X) icon exits selection mode
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.checklist), findsOneWidget);
    });
  });

  group('B. Multi-Delete', () {
    testWidgets('deletes selected photos from Drive first, updates local DB, and removes from gallery', (tester) async {
      await tester.pumpWidget(buildPatientPhotosScreen());
      await tester.pumpAndSettle();

      // Enter selection mode and select 2 photos
      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(InkWell).first);
      await tester.tap(find.byType(InkWell).at(1));
      await tester.pumpAndSettle();

      expect(find.text('2 selected'), findsOneWidget);

      // Tap Delete icon
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      // Verify confirmation dialog
      expect(find.text('Delete 2 Photos?'), findsOneWidget);
      expect(find.text('Permanently delete 2 selected photos from Google Drive?\n\nThis action cannot be undone.'), findsOneWidget);

      // Confirm deletion
      await tester.tap(find.text('Delete Permanently'));
      await tester.pumpAndSettle();

      // Verify Drive service deleted the files
      expect(fakeDriveService.deletedFileIds, containsAll(['drive_file_2', 'drive_file_3']));

      // Verify gallery now only contains 1 photo
      expect(find.textContaining('1 photo'), findsWidgets);
    });

    testWidgets('partial deletion failure: keeps failed photos visible and retryable', (tester) async {
      // Configure Drive service to fail on drive_file_2
      fakeDriveService.failDeleteFileId = 'drive_file_2';

      await tester.pumpWidget(buildPatientPhotosScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(InkWell).first); // drive_file_1
      await tester.tap(find.byType(InkWell).at(1)); // drive_file_2
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete Permanently'));
      await tester.pumpAndSettle();

      // 1 succeeded, 1 failed (drive_file_3 succeeded, drive_file_2 failed)
      expect(fakeDriveService.deletedFileIds, contains('drive_file_3'));
      expect(fakeDriveService.deletedFileIds.contains('drive_file_2'), isFalse);

      // Failed photo remains visible in gallery
      expect(find.textContaining('2 photos'), findsWidgets);
      expect(find.textContaining('Failed to delete 1 photos'), findsOneWidget);
    });
  });

  group('C. Patient -> Unassigned Move & Fixing 0 Photos Bug', () {
    testWidgets('moving photos creates ONE session, updates local uploads table with status uploaded, and shows count in Unassigned UI', (tester) async {
      await tester.pumpWidget(buildPatientPhotosScreen());
      await tester.pumpAndSettle();

      // Select 2 photos to move
      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(InkWell).first);
      await tester.tap(find.byType(InkWell).at(1));
      await tester.pumpAndSettle();

      expect(find.text('2 selected'), findsOneWidget);

      // Tap Move icon
      await tester.tap(find.byIcon(Icons.inbox_outlined));
      await tester.pumpAndSettle();

      // Verify dialog
      expect(find.text('Move 2 photos to Unassigned?'), findsOneWidget);
      await tester.tap(find.text('Move 2 Photos'));
      await tester.pumpAndSettle();

      // 1. Verify Drive move operations executed server-side
      expect(fakeDriveService.moveOperations.length, 2);
      expect(fakeDriveService.moveOperations.any((m) => m.fileId == 'drive_file_3'), isTrue);
      expect(fakeDriveService.moveOperations.any((m) => m.fileId == 'drive_file_2'), isTrue);
      expect(fakeDriveService.moveOperations[0].source, 'patient_folder_rahul');

      final targetFolder = fakeDriveService.moveOperations[0].target;
      expect(targetFolder, startsWith('session_folder_'));

      // 2. Verify local database records: ONE session created
      final unassignedSessions = await database.getUnassignedSessions();
      expect(unassignedSessions.length, 1);
      final session = unassignedSessions.first;
      expect(session.driveFolderId, targetFolder);
      expect(session.status, 'unassigned');
      expect(session.patientId, isNull);

      // 3. CRITICAL INVARIANT: photo_count MUST BE 2, NOT 0!
      expect(session.photoCount, 2);

      // 4. Verify uploads table contains the 2 moved photos with status 'uploaded'
      final uploads = await database.getUploadsForSession(session.id);
      expect(uploads.length, 2);
      for (final u in uploads) {
        expect(u.sessionId, session.id);
        expect(u.patientId, isNull);
        expect(u.driveFolderId, targetFolder);
        expect(u.driveParentFolderId, targetFolder);
        expect(u.status, UploadStatus.uploaded);
        expect(u.driveFileId, isNotNull);
      }

      // 5. Patient gallery now shows only 1 photo remaining
      expect(find.textContaining('1 photo'), findsWidgets);
    });

    testWidgets('UnassignedPhotosScreen renders session with real photo count (2 photos) and thumbnail previews', (tester) async {
      // Create session and insert 2 photos in database
      const sessionId = 'test-session-unassigned-123';
      const sessionFolder = 'drive_session_folder_abc';

      await database.insertSession(CaptureSession(
        id: sessionId,
        patientId: null,
        createdAt: DateTime(2026, 10, 1, 11, 15),
        status: 'unassigned',
        photoCount: 2,
        driveFolderId: sessionFolder,
      ));

      await database.insertUpload(UploadItem(
        id: 'u1',
        sessionId: sessionId,
        patientId: null,
        driveFolderId: sessionFolder,
        driveParentFolderId: sessionFolder,
        driveFileId: 'drive_file_1',
        localPath: '',
        fileName: '20261001_111500_000_001.jpg',
        status: UploadStatus.uploaded,
        createdAt: DateTime(2026, 10, 1, 11, 15),
      ));

      await database.insertUpload(UploadItem(
        id: 'u2',
        sessionId: sessionId,
        patientId: null,
        driveFolderId: sessionFolder,
        driveParentFolderId: sessionFolder,
        driveFileId: 'drive_file_2',
        localPath: '',
        fileName: '20261001_111500_000_002.jpg',
        status: UploadStatus.uploaded,
        createdAt: DateTime(2026, 10, 1, 11, 15),
      ));

      await tester.pumpWidget(
        MaterialApp(
          home: UnassignedPhotosScreen(
            database: database,
            queueService: queueService,
            folderService: folderService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify "2 photos" is displayed (NOT "0 photos")
      expect(find.text('2 photos'), findsOneWidget);
      expect(find.text('Uploaded'), findsOneWidget);
      expect(find.text('View Photos'), findsOneWidget);
      expect(find.text('Assign'), findsOneWidget);
    });
  });

  group('D. Unassigned -> Patient Move & Safe Folder Cleanup', () {
    test('assignSession moves Drive files, verifies empty, deletes Drive session folder and local session', () async {
      const sessionId = 'session_to_assign_1';
      const sessionFolder = 'drive_session_folder_assign';

      // Setup files on Drive in session folder
      fakeDriveService.folderFiles[sessionFolder] = [
        drive.File()..id = 'drive_file_assign_1'..parents = [sessionFolder],
        drive.File()..id = 'drive_file_assign_2'..parents = [sessionFolder],
      ];

      await database.insertSession(CaptureSession(
        id: sessionId,
        patientId: null,
        createdAt: DateTime.now(),
        status: 'unassigned',
        photoCount: 2,
        driveFolderId: sessionFolder,
      ));

      await database.insertUpload(UploadItem(
        id: 'u_assign_1',
        sessionId: sessionId,
        patientId: null,
        driveFolderId: sessionFolder,
        driveParentFolderId: sessionFolder,
        driveFileId: 'drive_file_assign_1',
        localPath: '',
        fileName: 'photo_1.jpg',
        status: UploadStatus.uploaded,
        createdAt: DateTime.now(),
      ));

      await database.insertUpload(UploadItem(
        id: 'u_assign_2',
        sessionId: sessionId,
        patientId: null,
        driveFolderId: sessionFolder,
        driveParentFolderId: sessionFolder,
        driveFileId: 'drive_file_assign_2',
        localPath: '',
        fileName: 'photo_2.jpg',
        status: UploadStatus.uploaded,
        createdAt: DateTime.now(),
      ));

      // Assign to patient
      await queueService.assignSession(
        sessionId: sessionId,
        patient: testPatient,
      );

      // 1. Files moved server-side on Drive to patient folder
      expect(fakeDriveService.folderFiles['patient_folder_rahul']!.any((f) => f.id == 'drive_file_assign_1'), isTrue);
      expect(fakeDriveService.folderFiles['patient_folder_rahul']!.any((f) => f.id == 'drive_file_assign_2'), isTrue);

      // 2. Drive session folder confirmed empty and deleted
      expect(fakeDriveService.deletedFolderIds, contains(sessionFolder));

      // 3. Local session deleted from database
      final remainingSession = await database.getSession(sessionId);
      expect(remainingSession, isNull);
    });

    test('partial move failure preserves session and does NOT delete session folder', () async {
      const sessionId = 'session_partial_fail';
      const sessionFolder = 'drive_session_partial';

      fakeDriveService.folderFiles[sessionFolder] = [
        drive.File()..id = 'good_file'..parents = [sessionFolder],
        drive.File()..id = 'bad_file'..parents = [sessionFolder],
      ];

      fakeDriveService.failMoveFileId = 'bad_file';

      await database.insertSession(CaptureSession(
        id: sessionId,
        patientId: null,
        createdAt: DateTime.now(),
        status: 'unassigned',
        photoCount: 2,
        driveFolderId: sessionFolder,
      ));

      await database.insertUpload(UploadItem(
        id: 'u_good',
        sessionId: sessionId,
        patientId: null,
        driveFolderId: sessionFolder,
        driveFileId: 'good_file',
        localPath: '',
        fileName: 'good.jpg',
        status: UploadStatus.uploaded,
        createdAt: DateTime.now(),
      ));

      await database.insertUpload(UploadItem(
        id: 'u_bad',
        sessionId: sessionId,
        patientId: null,
        driveFolderId: sessionFolder,
        driveFileId: 'bad_file',
        localPath: '',
        fileName: 'bad.jpg',
        status: UploadStatus.uploaded,
        createdAt: DateTime.now(),
      ));

      // Expect StateError on assignment
      await expectLater(
        queueService.assignSession(sessionId: sessionId, patient: testPatient),
        throwsA(isA<StateError>()),
      );

      // Verify good file was moved, bad file remained
      expect(fakeDriveService.folderFiles['patient_folder_rahul']!.any((f) => f.id == 'good_file'), isTrue);

      // Verify Drive session folder was NOT deleted
      expect(fakeDriveService.deletedFolderIds.contains(sessionFolder), isFalse);

      // Verify local session was NOT deleted
      final sessionStillExists = await database.getSession(sessionId);
      expect(sessionStillExists, isNotNull);
    });
  });

  group('E. Unassigned Session Deletion Flow', () {
    test('deleteUnassignedSession deletes Drive files, empty folder, and local records', () async {
      const sessionId = 'session_to_delete';
      const sessionFolder = 'drive_folder_to_delete';

      fakeDriveService.folderFiles[sessionFolder] = [
        drive.File()..id = 'f_del_1'..parents = [sessionFolder],
        drive.File()..id = 'f_del_2'..parents = [sessionFolder],
      ];

      await database.insertSession(CaptureSession(
        id: sessionId,
        patientId: null,
        createdAt: DateTime.now(),
        status: 'unassigned',
        photoCount: 2,
        driveFolderId: sessionFolder,
      ));

      await database.insertUpload(UploadItem(
        id: 'up_del_1',
        sessionId: sessionId,
        driveFolderId: sessionFolder,
        driveFileId: 'f_del_1',
        localPath: '',
        fileName: 'del_1.jpg',
        status: UploadStatus.uploaded,
        createdAt: DateTime.now(),
      ));

      await database.insertUpload(UploadItem(
        id: 'up_del_2',
        sessionId: sessionId,
        driveFolderId: sessionFolder,
        driveFileId: 'f_del_2',
        localPath: '',
        fileName: 'del_2.jpg',
        status: UploadStatus.uploaded,
        createdAt: DateTime.now(),
      ));

      await queueService.deleteUnassignedSession(sessionId);

      // Drive files deleted
      expect(fakeDriveService.deletedFileIds, containsAll(['f_del_1', 'f_del_2']));

      // Drive session folder deleted
      expect(fakeDriveService.deletedFolderIds, contains(sessionFolder));

      // Database session deleted
      expect(await database.getSession(sessionId), isNull);
      expect(await database.getUploadsForSession(sessionId), isEmpty);
    });
  });

  group('F. Session Integrity & Restart Preservation', () {
    test('multiple sessions maintain distinct photo mappings across simulated restart', () async {
      final session1 = CaptureSession(
        id: 's1',
        patientId: null,
        createdAt: DateTime(2026, 10, 1, 9, 0),
        status: 'unassigned',
        photoCount: 2,
        driveFolderId: 'f1',
      );
      final session2 = CaptureSession(
        id: 's2',
        patientId: null,
        createdAt: DateTime(2026, 10, 1, 10, 0),
        status: 'unassigned',
        photoCount: 1,
        driveFolderId: 'f2',
      );

      await database.insertSession(session1);
      await database.insertSession(session2);

      await database.insertUpload(UploadItem(
        id: 'u1_s1',
        sessionId: 's1',
        driveFileId: 'df1',
        localPath: '',
        fileName: 's1_p1.jpg',
        status: UploadStatus.uploaded,
        createdAt: DateTime.now(),
      ));
      await database.insertUpload(UploadItem(
        id: 'u2_s1',
        sessionId: 's1',
        driveFileId: 'df2',
        localPath: '',
        fileName: 's1_p2.jpg',
        status: UploadStatus.uploaded,
        createdAt: DateTime.now(),
      ));
      await database.insertUpload(UploadItem(
        id: 'u1_s2',
        sessionId: 's2',
        driveFileId: 'df3',
        localPath: '',
        fileName: 's2_p1.jpg',
        status: UploadStatus.uploaded,
        createdAt: DateTime.now(),
      ));

      // Verify queries before restart
      var s1Uploads = await database.getUploadsForSession('s1');
      var s2Uploads = await database.getUploadsForSession('s2');
      expect(s1Uploads.length, 2);
      expect(s2Uploads.length, 1);

      // Simulate app restart with InMemoryAppDatabase dump & restore
      final freshDb = InMemoryAppDatabase(
        initialSessions: database.dumpSessions(),
        initialUploads: database.dumpUploads(),
        initialPatients: database.dumpPatients(),
      );

      s1Uploads = await freshDb.getUploadsForSession('s1');
      s2Uploads = await freshDb.getUploadsForSession('s2');
      expect(s1Uploads.length, 2);
      expect(s2Uploads.length, 1);

      final unassigned = await freshDb.getUnassignedSessions();
      expect(unassigned.length, 2);
      expect(unassigned.firstWhere((s) => s.id == 's1').photoCount, 2);
      expect(unassigned.firstWhere((s) => s.id == 's2').photoCount, 1);
    });
  });
}
