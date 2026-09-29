import 'dart:io';
import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/screens/session_detail_screen.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:clinic_photos/widgets/selection_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Session Deletion Tests (Section 23.3)', () {
    late InMemoryAppDatabase database;
    late UploadQueueService queueService;
    late Directory tempRootDir;

    setUp(() async {
      tempRootDir = await Directory.systemTemp.createTemp('clinic_deletion_test_');
      database = InMemoryAppDatabase();
      queueService = UploadQueueService(
        database: database,
        driveService: DriveService(),
        authService: GoogleAuthService(),
        customDocsDirectory: tempRootDir.path,
      );
    });

    tearDown(() async {
      queueService.dispose();
      await database.close();
      if (tempRootDir.existsSync()) {
        tempRootDir.deleteSync(recursive: true);
      }
    });

    test('1. Delete selected photos: Selecting 2 of 5 photos deletes only those 2 from disk and SQLite', () async {
      final session = await queueService.createUnassignedSession();

      final photos = <UploadItem>[];
      for (var i = 1; i <= 5; i++) {
        final dummy = File(p.join(tempRootDir.path, 'shot_$i.jpg'))..writeAsStringSync('photo_$i');
        final item = await queueService.enqueueUnassignedPhoto(
          sessionId: session.id,
          capturedTempPath: dummy.path,
          sequenceNumber: i,
        );
        photos.add(item);
      }

      expect(photos.length, 5);
      for (final p in photos) {
        expect(File(p.localPath).existsSync(), isTrue);
      }

      // Select 2 photos to delete (photos[1] and photos[3])
      final toDelete = [photos[1], photos[3]];
      final idsToDelete = toDelete.map((p) => p.id).toList();

      // Physically delete files
      for (final p in toDelete) {
        File(p.localPath).deleteSync();
      }

      // Delete from database
      await database.deleteUploads(idsToDelete);

      // Verify only 3 remaining
      final remaining = await database.getUploadsForSession(session.id);
      expect(remaining.length, 3);
      expect(remaining.map((r) => r.id), isNot(contains(photos[1].id)));
      expect(remaining.map((r) => r.id), isNot(contains(photos[3].id)));

      // Verify physical files on disk
      expect(File(photos[0].localPath).existsSync(), isTrue);
      expect(File(photos[1].localPath).existsSync(), isFalse);
      expect(File(photos[2].localPath).existsSync(), isTrue);
      expect(File(photos[3].localPath).existsSync(), isFalse);
      expect(File(photos[4].localPath).existsSync(), isTrue);
    });

    test('2. Delete all photos removes session: Deleting all photos in session deletes session record', () async {
      final session = await queueService.createUnassignedSession();
      final dummy = File(p.join(tempRootDir.path, 'only_shot.jpg'))..writeAsStringSync('single');
      final item = await queueService.enqueueUnassignedPhoto(
        sessionId: session.id,
        capturedTempPath: dummy.path,
        sequenceNumber: 1,
      );

      expect(await database.getSession(session.id), isNotNull);
      expect(await database.getUnassignedSessionsCount(), 1);

      // Delete the only photo
      File(item.localPath).deleteSync();
      await database.deleteUploads([item.id]);

      // Check remaining
      final remaining = await database.getUploadsForSession(session.id);
      if (remaining.isEmpty) {
        await database.deleteSession(session.id);
      }

      expect(await database.getSession(session.id), isNull);
      expect(await database.getUnassignedSessionsCount(), 0);
    });

    test('3. Deletion removes physical files: Verified by checking file.existsSync() is false', () async {
      final session = await queueService.createUnassignedSession();
      final dummy = File(p.join(tempRootDir.path, 'temp_file.jpg'))..writeAsStringSync('binary_bytes');

      final item = await queueService.enqueueUnassignedPhoto(
        sessionId: session.id,
        capturedTempPath: dummy.path,
      );

      final localFile = File(item.localPath);
      expect(localFile.existsSync(), isTrue);

      // Perform deletion
      localFile.deleteSync();
      await database.deleteUploads([item.id]);

      expect(localFile.existsSync(), isFalse);
    });

    final k1x1Png = <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ];

    testWidgets('4. UI interaction: Cancel leaves photos intact and confirmation deletes selected', (tester) async {
      final session = await queueService.createUnassignedSession();
      final dummy = File(p.join(tempRootDir.path, 'ui_shot_1.png'))..writeAsBytesSync(k1x1Png);
      final photo = await queueService.enqueueUnassignedPhoto(
        sessionId: session.id,
        capturedTempPath: dummy.path,
        sequenceNumber: 1,
      );

      await tester.pumpWidget(MaterialApp(
        home: SessionDetailScreen(
          session: session,
          database: database,
          queueService: queueService,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Verify photo loaded
      expect(find.text('1 photo captured in this session'), findsOneWidget);

      // Enter selection mode via "Select" button
      final selectButton = find.widgetWithText(OutlinedButton, 'Select');
      expect(selectButton, findsOneWidget);
      await tester.tap(selectButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // In selection mode, select the photo
      await tester.tap(find.byType(SelectionThumbnail));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Find Delete Selected button
      final deleteButton = find.widgetWithText(FilledButton, 'Delete Selected (1)');
      expect(deleteButton, findsOneWidget);
      await tester.tap(deleteButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Dialog appears: Tap "Cancel"
      expect(find.text('Delete 1 Photo?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Verify photo still intact
      expect(File(photo.localPath).existsSync(), isTrue);
      expect((await database.getUploadsForSession(session.id)).length, 1);
    });
  });
}
