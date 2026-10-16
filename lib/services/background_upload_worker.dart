import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'config_service.dart';
import 'database.dart';
import 'drive.dart';
import 'google_auth.dart';
import 'patient_folder_service.dart';
import 'sheets.dart';
import 'upload_queue.dart';

/// WorkManager task type used by both immediate and periodic queue work.
const String uploadQueueTaskName = 'clinic_photos.upload_queue';
const String uploadQueueUniqueName = 'clinic_photos.upload_queue.now';
const String uploadQueuePeriodicName = 'clinic_photos.upload_queue.periodic';

/// A small adapter around WorkManager so the queue remains testable without a
/// platform scheduler. Android persists these requests across process death;
/// the queue's SQLite state remains the source of truth for individual photos.
class BackgroundUploadWorker {
  bool _initialized = false;
  Future<void>? _initializing;

  Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    if (_initialized) return;
    if (_initializing != null) {
      await _initializing;
      return;
    }

    _initializing = _initialize();
    try {
      await _initializing;
    } finally {
      _initializing = null;
    }
  }

  Future<void> _initialize() async {
    await Workmanager().initialize(uploadQueueDispatcher);
    await Workmanager().registerPeriodicTask(
      uploadQueuePeriodicName,
      uploadQueueTaskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 1),
      tag: uploadQueueTaskName,
    );
    _initialized = true;
  }

  /// Enqueues one persisted, network-constrained run. KEEP prevents rapid
  /// captures from cancelling a worker that is already uploading another item.
  Future<void> scheduleNow() async {
    if (!Platform.isAndroid) return;
    await initialize();
    await Workmanager().registerOneOffTask(
      uploadQueueUniqueName,
      uploadQueueTaskName,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 1),
      tag: uploadQueueTaskName,
    );
  }
}

/// WorkManager starts this top-level entry point in a fresh Flutter isolate.
/// Every dependency is recreated here; no UI isolate state is required.
@pragma('vm:entry-point')
void uploadQueueDispatcher() {
  Workmanager().executeTask((taskName, _) async {
    DartPluginRegistrant.ensureInitialized();
    if (taskName != uploadQueueTaskName) return true;

    AppDatabase? database;
    UploadQueueService? queue;
    try {
      database = await AppDatabase.init();
      final configService = await ConfigService.init();
      final authService = GoogleAuthService();
      final driveService = DriveService();
      final sheetsService = SheetsService();
      final folderService = PatientFolderService(
        driveService: driveService,
        sheetsService: sheetsService,
        authService: authService,
        configService: configService,
        database: database,
      );
      queue = UploadQueueService(
        database: database,
        authService: authService,
        driveService: driveService,
        patientFolderService: folderService,
      );

      // wake() deliberately uses silent authentication. If the account or
      // Drive scopes are unavailable, the task exits cleanly and the next
      // persisted run will retry without opening an OAuth prompt.
      await queue.wake();
      return true;
    } catch (error, stackTrace) {
      debugPrint('Background upload worker failed: $error\n$stackTrace');
      return false;
    } finally {
      queue?.dispose();
      // WorkManager runs the Dart callback in the app process on some Android
      // versions. The database handle can therefore be shared with the UI
      // isolate even though this callback was created as a fresh isolate.
      // Closing it here races the patient screens and leaves their futures
      // failing with `database_closed`. The OS closes the worker's handle when
      // the worker/isolate exits; never close the shared clinic database here.
    }
  });
}
