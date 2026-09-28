import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../models/patient.dart';
import '../models/upload_item.dart';
import 'database.dart';
import 'drive.dart';
import 'google_auth.dart';

class QueueStatus {
  final int activeCount;
  final int failedCount;

  const QueueStatus({
    required this.activeCount,
    required this.failedCount,
  });

  bool get hasFailures => failedCount > 0;
  bool get hasWork => activeCount > 0 || failedCount > 0;
  bool get isIdle => activeCount == 0 && failedCount == 0;
}

class UploadQueueService extends ChangeNotifier {
  final AppDatabase database;
  final GoogleAuthService authService;
  final DriveService driveService;
  final Connectivity connectivity;
  final String? customDocsDirectory;

  bool _isProcessing = false;
  bool _disposed = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  static const _uuid = Uuid();

  // Retry backoff delays in seconds: 5s, 15s, 30s, 60s
  static const List<int> _retryDelaysSeconds = [5, 15, 30, 60];

  UploadQueueService({
    required this.database,
    required this.authService,
    required this.driveService,
    Connectivity? connectivity,
    this.customDocsDirectory,
  }) : connectivity = connectivity ?? Connectivity() {
    _initConnectivityListener();
  }

  void _initConnectivityListener() {
    try {
      _connectivitySub = connectivity.onConnectivityChanged.listen((results) {
        final isDisconnected =
            results.contains(ConnectivityResult.none) && results.length == 1;
        if (!isDisconnected) {
          // Connectivity change is used as a hint to wake up the queue.
          // The Drive upload request itself determines if API access actually succeeds.
          processQueue();
        }
      });
    } catch (_) {
      // In test environments, connectivity stream may not be available.
    }
  }

  void _safeNotifyListeners() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _connectivitySub?.cancel();
    super.dispose();
  }

  /// Gets current queue status counts.
  Future<QueueStatus> getStatus() async {
    final active = await database.getActiveUploadsCount();
    final failed = await database.getFailedUploadsCount();
    return QueueStatus(activeCount: active, failedCount: failed);
  }

  /// Immediately moves captured photo to private app directory, enqueues
  /// upload record in SQLite, and wakes the upload worker in the background.
  ///
  /// CRITICAL REQUIREMENT: This method returns immediately without waiting
  /// for Google Drive so the camera is ready for the next capture instantly.
  Future<UploadItem> enqueuePhoto({
    required Patient patient,
    required String capturedTempPath,
  }) async {
    final now = DateTime.now();
    final shortUuid = _uuid.v4().substring(0, 4);
    final dateStr = DateFormat('yyyy-MM-dd_HH-mm-ss').format(now);
    final fileName = '${patient.id}_${dateStr}_$shortUuid.jpg';

    // Store in private app documents directory (photo_queue/)
    final String basePath = customDocsDirectory ??
        (await getApplicationDocumentsDirectory()).path;
    final queueDir = Directory(p.join(basePath, AppConfig.photoQueueDirName));
    if (!queueDir.existsSync()) {
      queueDir.createSync(recursive: true);
    }

    final localPath = p.join(queueDir.path, fileName);
    final tempFile = File(capturedTempPath);

    // Move or copy image file to private storage
    if (tempFile.existsSync()) {
      await tempFile.copy(localPath);
      try {
        await tempFile.delete();
      } catch (_) {}
    }

    final item = UploadItem(
      id: _uuid.v4(),
      patientId: patient.id,
      driveFolderId: patient.driveFolderId,
      localPath: localPath,
      fileName: fileName,
      status: UploadStatus.waiting,
      retryCount: 0,
      createdAt: now,
    );

    await database.insertUpload(item);
    _safeNotifyListeners();

    // Trigger queue processing asynchronously (unawaited)
    unawaited(processQueue());

    return item;
  }

  /// Main background upload loop.
  Future<void> processQueue() async {
    if (_disposed || _isProcessing) return;
    _isProcessing = true;

    try {
      while (!_disposed) {
        final item = await database.getNextPendingUpload();
        if (item == null) break;

        final localFile = File(item.localPath);
        if (!localFile.existsSync()) {
          // File was deleted or missing; mark failed and stop retrying
          await database.updateUpload(item.copyWith(
            status: UploadStatus.failed,
            lastError: 'Local photo file not found at ${item.localPath}',
          ));
          _safeNotifyListeners();
          continue;
        }

        // Mark item as uploading
        await database.updateUpload(item.copyWith(status: UploadStatus.uploading));
        _safeNotifyListeners();

        // Obtain authenticated client
        final client = await authService.getAuthenticatedClient();
        if (client == null) {
          // Authentication currently unavailable
          await _handleFailure(
            item,
            'Google account authorization not available. Please sign in.',
          );
          break; // Stop loop until auth/connectivity restores
        }

        try {
          final driveFileId = await driveService.uploadPhoto(
            client: client,
            file: localFile,
            folderId: item.driveFolderId,
            fileName: item.fileName,
          );

          // DRIVE CONFIRMED:
          // 1. Delete local file from private storage
          if (localFile.existsSync()) {
            try {
              localFile.deleteSync();
            } catch (e) {
              debugPrint('Warning: unable to delete local file: $e');
            }
          }

          // 2. Delete row from SQLite database
          await database.deleteUpload(item.id);
          debugPrint('Upload finalized and record removed for: ${item.fileName} ($driveFileId)');
          _safeNotifyListeners();
        } catch (e) {
          debugPrint('Upload attempt failed for ${item.fileName}: $e');
          await _handleFailure(item, e.toString());
        }
      }
    } finally {
      _isProcessing = false;
      _safeNotifyListeners();
    }
  }

  /// Handles upload failure with bounded gentle retries.
  /// Delays: 5s, 15s, 30s, 60s -> stop automatic retries and mark failed.
  Future<void> _handleFailure(UploadItem item, String errorMessage) async {
    final nextRetryCount = item.retryCount + 1;

    if (nextRetryCount <= _retryDelaysSeconds.length) {
      final delaySeconds = _retryDelaysSeconds[nextRetryCount - 1];
      debugPrint(
        'Upload failed for ${item.fileName}. Will retry attempt $nextRetryCount in ${delaySeconds}s. Error: $errorMessage',
      );

      // Keep status as waiting so it gets picked up again after backoff
      await database.updateUpload(item.copyWith(
        status: UploadStatus.waiting,
        retryCount: nextRetryCount,
        lastError: errorMessage,
      ));
      _safeNotifyListeners();

      // Schedule delayed retry
      Future.delayed(Duration(seconds: delaySeconds), () {
        if (!_disposed) {
          processQueue();
        }
      });
    } else {
      debugPrint(
        'Upload exceeded max retries for ${item.fileName}. Marking failed. Error: $errorMessage',
      );
      await database.updateUpload(item.copyWith(
        status: UploadStatus.failed,
        retryCount: nextRetryCount,
        lastError: errorMessage,
      ));
      _safeNotifyListeners();
    }
  }

  /// Manual retry for all failed uploads.
  Future<void> retryFailedUploads() async {
    await database.resetFailedToWaiting();
    _safeNotifyListeners();
    await processQueue();
  }
}
