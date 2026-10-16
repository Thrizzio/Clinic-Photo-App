import 'dart:async';
import 'dart:io';

import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/models/upload_item.dart';
import 'package:clinic_photos/screens/patient_photos_screen.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis_auth/googleapis_auth.dart';

class _BlockingAuthService extends GoogleAuthService {
  final completer = Completer<AuthClient?>();

  @override
  Future<AuthClient?> getAuthenticatedClient() => completer.future;
}

class _OfflineConnectivity implements Connectivity {
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => const Stream.empty();

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.none];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const patient = Patient(
    id: 'patient-detail-loading',
    name: 'Detail Loading Patient',
    displayName: 'Detail Loading Patient',
    driveFolderId: 'drive-folder-detail-loading',
    folderStatus: FolderStatus.available,
  );

  Future<(UploadQueueService, _BlockingAuthService)> buildQueue(
    InMemoryAppDatabase database,
  ) async {
    final directory = Directory.systemTemp.createTempSync('patient_detail_loading_');
    final auth = _BlockingAuthService();
    final queue = UploadQueueService(
      database: database,
      authService: auth,
      driveService: DriveService(),
      connectivity: _OfflineConnectivity(),
      customDocsDirectory: directory.path,
    );
    return (queue, auth);
  }

  testWidgets('empty patient detail leaves the local empty state visible', (tester) async {
    final database = InMemoryAppDatabase();
    await database.upsertPatients([patient]);
    final (queue, auth) = await buildQueue(database);
    addTearDown(queue.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: PatientPhotosScreen(
          patient: patient,
          authService: queue.authService,
          driveService: queue.driveService,
          queueService: queue,
          patientSyncService: null,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('No photos found in patient folder'), findsOneWidget);
    auth.completer.complete(null);
  });

  testWidgets('local patient photos render without waiting for Drive auth', (tester) async {
    final database = InMemoryAppDatabase();
    await database.upsertPatients([patient]);
    final directory = Directory.systemTemp.createTempSync('patient_detail_photo_');
    final photo = File('${directory.path}/20261016_120000_000_001.jpg')
      ..writeAsBytesSync([1, 2, 3]);
    await database.insertUpload(
      UploadItem(
        id: 'local-detail-photo',
        patientId: patient.id,
        driveFolderId: patient.driveFolderId,
        localPath: photo.path,
        fileName: photo.uri.pathSegments.last,
        status: UploadStatus.waiting,
        createdAt: DateTime(2026, 10, 16, 12),
      ),
    );
    final (queue, auth) = await buildQueue(database);
    addTearDown(queue.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: PatientPhotosScreen(
          patient: patient,
          authService: queue.authService,
          driveService: queue.driveService,
          queueService: queue,
          patientSyncService: null,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(GridView), findsOneWidget);
    auth.completer.complete(null);
  });
}
