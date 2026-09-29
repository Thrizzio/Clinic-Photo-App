import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../models/capture_session.dart';
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
    recoverOrphanedUnassignedPhotos();
  }

  void _initConnectivityListener() {
    try {
      _connectivitySub = connectivity.onConnectivityChanged.listen((results) {
        final isDisconnected =
            results.contains(ConnectivityResult.none) && results.length == 1;
        if (!isDisconnected) {
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

  Future<String> _getBasePath() async {
    return customDocsDirectory ??
        (await getApplicationDocumentsDirectory()).path;
  }

  /// Workflow A: Immediately moves captured photo to private app directory,
  /// enqueues upload record in SQLite, and wakes the upload worker in the background.
  Future<UploadItem> enqueuePhoto({
    required Patient patient,
    required String capturedTempPath,
    String? sessionId,
    DateTime? capturedAt,
    int? sequenceNumber,
  }) async {
    if (!patient.isUploadable) {
      throw ArgumentError(
        'Cannot enqueue photo: Patient ${patient.id} does not have an available Drive folder.',
      );
    }

    final now = capturedAt ?? DateTime.now();
    final seq = sequenceNumber;
    final String fileName;
    if (seq != null) {
      final dateStr = DateFormat('yyyyMMdd_HHmmss').format(now);
      final seqStr = seq.toString().padLeft(3, '0');
      fileName = '${patient.id}_${dateStr}_$seqStr.jpg';
    } else {
      final shortUuid = _uuid.v4().substring(0, 4);
      final dateStr = DateFormat('yyyy-MM-dd_HH-mm-ss').format(now);
      fileName = '${patient.id}_${dateStr}_$shortUuid.jpg';
    }

    final basePath = await _getBasePath();
    final Directory queueDir;
    if (sessionId != null && sessionId.isNotEmpty) {
      queueDir = Directory(
        p.join(basePath, AppConfig.photoQueueDirName, 'patients', patient.id, sessionId),
      );
    } else {
      queueDir = Directory(p.join(basePath, AppConfig.photoQueueDirName));
    }
    if (!queueDir.existsSync()) {
      queueDir.createSync(recursive: true);
    }

    final localPath = p.join(queueDir.path, fileName);
    final tempFile = File(capturedTempPath);

    if (!tempFile.existsSync()) {
      throw FileSystemException('Captured camera temp file does not exist', capturedTempPath);
    }

    await tempFile.copy(localPath);
    final savedFile = File(localPath);
    if (!savedFile.existsSync()) {
      throw FileSystemException('Failed to verify saved photo in private storage', localPath);
    }

    try {
      await tempFile.delete();
    } catch (_) {}

    final item = UploadItem(
      id: _uuid.v4(),
      sessionId: sessionId,
      patientId: patient.id,
      driveFolderId: patient.driveFolderId,
      localPath: localPath,
      fileName: fileName,
      status: UploadStatus.waiting,
      retryCount: 0,
      createdAt: now,
      capturedAt: now,
      sequenceNumber: seq ?? 1,
    );

    await database.insertUpload(item);
    _safeNotifyListeners();

    unawaited(processQueue());

    return item;
  }

  /// Workflow B: Creates a new unassigned capture session.
  Future<CaptureSession> createUnassignedSession() async {
    final session = CaptureSession(
      id: _uuid.v4(),
      patientId: null,
      createdAt: DateTime.now(),
      status: 'unassigned',
      photoCount: 0,
    );
    await database.insertSession(session);
    _safeNotifyListeners();
    return session;
  }

  /// Workflow B: Saves a photo captured during an unassigned session.
  /// Photos remain in 'unassigned' state and do NOT wake the upload queue.
  Future<UploadItem> enqueueUnassignedPhoto({
    required String sessionId,
    required String capturedTempPath,
    DateTime? capturedAt,
    int? sequenceNumber,
  }) async {
    final now = capturedAt ?? DateTime.now();
    final seq = sequenceNumber;
    final String fileName;
    if (seq != null) {
      final dateStr = DateFormat('yyyyMMdd_HHmmss').format(now);
      final seqStr = seq.toString().padLeft(3, '0');
      fileName = 'unassigned_${dateStr}_$seqStr.jpg';
    } else {
      final shortUuid = _uuid.v4().substring(0, 4);
      final dateStr = DateFormat('yyyy-MM-dd_HH-mm-ss').format(now);
      fileName = 'unassigned_${dateStr}_$shortUuid.jpg';
    }

    final basePath = await _getBasePath();
    final sessionDir = Directory(
      p.join(basePath, AppConfig.photoQueueDirName, AppConfig.unassignedDirName, sessionId),
    );
    if (!sessionDir.existsSync()) {
      sessionDir.createSync(recursive: true);
    }

    final localPath = p.join(sessionDir.path, fileName);
    final tempFile = File(capturedTempPath);

    if (!tempFile.existsSync()) {
      throw FileSystemException('Captured camera temp file does not exist', capturedTempPath);
    }

    await tempFile.copy(localPath);
    final savedFile = File(localPath);
    if (!savedFile.existsSync()) {
      throw FileSystemException('Failed to verify saved photo in private storage', localPath);
    }

    try {
      await tempFile.delete();
    } catch (_) {}

    final item = UploadItem(
      id: _uuid.v4(),
      sessionId: sessionId,
      patientId: null,
      driveFolderId: null,
      localPath: localPath,
      fileName: fileName,
      status: UploadStatus.unassigned,
      retryCount: 0,
      createdAt: now,
      capturedAt: now,
      sequenceNumber: seq ?? 1,
    );

    await database.insertUpload(item);
    _safeNotifyListeners();

    return item;
  }

  /// Recovers any physical photo files in photo_queue/unassigned/ that were
  /// saved to disk but missing from the SQLite uploads table.
  Future<void> recoverOrphanedUnassignedPhotos() async {
    try {
      final basePath = await _getBasePath();
      final unassignedDir = Directory(
        p.join(basePath, AppConfig.photoQueueDirName, AppConfig.unassignedDirName),
      );
      if (!unassignedDir.existsSync()) return;

      final sessionDirs = unassignedDir.listSync().whereType<Directory>();
      for (final sDir in sessionDirs) {
        final sessionId = p.basename(sDir.path);
        var session = await database.getSession(sessionId);
        if (session == null) {
          session = CaptureSession(
            id: sessionId,
            patientId: null,
            createdAt: sDir.statSync().changed,
            status: 'unassigned',
            photoCount: 0,
          );
          await database.insertSession(session);
        }

        final photoFiles = sDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.jpg'));
        final existingUploads = await database.getUploadsForSession(sessionId);
        final existingPaths = existingUploads.map((u) => u.localPath).toSet();

        for (final file in photoFiles) {
          if (!existingPaths.contains(file.path)) {
            final fileName = p.basename(file.path);
            await database.insertUpload(
              UploadItem(
                id: _uuid.v4(),
                sessionId: sessionId,
                patientId: null,
                driveFolderId: null,
                localPath: file.path,
                fileName: fileName,
                status: UploadStatus.unassigned,
                retryCount: 0,
                createdAt: file.statSync().changed,
              ),
            );
            debugPrint('RECOVERED unassigned photo: $fileName for session $sessionId');
          }
        }
      }
      _safeNotifyListeners();
    } catch (e) {
      debugPrint('Error recovering orphaned unassigned photos: $e');
    }
  }

  /// Workflow B: Assigns an unassigned session to a verified patient.
  /// Validates that patient has an available Drive folder, renames files to the
  /// patient directory structure, transitions all photos to 'waiting', and wakes the
  /// background upload worker.
  Future<void> assignSession({
    required String sessionId,
    required Patient patient,
  }) async {
    if (!patient.isUploadable) {
      throw ArgumentError(
        'Cannot assign session: Patient ${patient.id} folder status is ${patient.folderStatus.name}.',
      );
    }

    final uploads = await database.getUploadsForSession(sessionId);
    final basePath = await _getBasePath();
    final patientSessionDir = Directory(
      p.join(basePath, AppConfig.photoQueueDirName, 'patients', patient.id, sessionId),
    );
    if (!patientSessionDir.existsSync()) {
      patientSessionDir.createSync(recursive: true);
    }

    final renamedPhotos = <String, ({String fileName, String localPath})>{};

    for (var i = 0; i < uploads.length; i++) {
      final item = uploads[i];
      final originalFile = File(item.localPath);
      final capturedAt = item.capturedAt;
      final seq = item.sequenceNumber;
      final dateStr = DateFormat('yyyyMMdd_HHmmss').format(capturedAt);
      final seqStr = seq.toString().padLeft(3, '0');
      final newFileName = '${patient.id}_${dateStr}_$seqStr.jpg';
      final newLocalPath = p.join(patientSessionDir.path, newFileName);

      if (originalFile.existsSync()) {
        try {
          originalFile.renameSync(newLocalPath);
        } catch (_) {
          originalFile.copySync(newLocalPath);
          try {
            originalFile.deleteSync();
          } catch (_) {}
        }
      }

      renamedPhotos[item.id] = (fileName: newFileName, localPath: newLocalPath);
    }

    // Clean up empty unassigned directory if empty
    try {
      final unassignedSessionDir = Directory(
        p.join(basePath, AppConfig.photoQueueDirName, AppConfig.unassignedDirName, sessionId),
      );
      if (unassignedSessionDir.existsSync() && unassignedSessionDir.listSync().isEmpty) {
        unassignedSessionDir.deleteSync(recursive: true);
      }
    } catch (_) {}

    await database.assignSessionToPatient(
      sessionId: sessionId,
      patientId: patient.id,
      driveFolderId: patient.driveFolderId!,
      renamedPhotos: renamedPhotos,
    );

    _safeNotifyListeners();

    unawaited(processQueue());
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
          await database.updateUpload(item.copyWith(
            status: UploadStatus.failed,
            lastError: 'Local photo file not found at ${item.localPath}',
          ));
          _safeNotifyListeners();
          continue;
        }

        if (item.driveFolderId == null || item.driveFolderId!.isEmpty) {
          await database.updateUpload(item.copyWith(
            status: UploadStatus.failed,
            lastError: 'Missing Drive folder ID for upload',
          ));
          _safeNotifyListeners();
          continue;
        }

        await database.updateUpload(item.copyWith(status: UploadStatus.uploading));
        _safeNotifyListeners();

        final client = await authService.getAuthenticatedClient();
        if (client == null) {
          await _handleFailure(
            item,
            'Google account authorization not available. Please sign in.',
          );
          break;
        }

        try {
          final driveFileId = await driveService.uploadPhoto(
            client: client,
            file: localFile,
            folderId: item.driveFolderId!,
            fileName: item.fileName,
          );

          // DRIVE CONFIRMED:
          // 1. Delete local file
          if (localFile.existsSync()) {
            try {
              localFile.deleteSync();
            } catch (e) {
              debugPrint('Warning: unable to delete local file: $e');
            }
          }

          // 2. Delete row from uploads
          await database.deleteUpload(item.id);

          // 3. If item belonged to an unassigned session, check if session is completed
          if (item.sessionId != null) {
            final remaining = await database.getUploadsForSession(item.sessionId!);
            if (remaining.isEmpty) {
              await database.deleteSession(item.sessionId!);
              try {
                final sessionDir = Directory(p.dirname(item.localPath));
                if (sessionDir.existsSync()) {
                  sessionDir.deleteSync(recursive: true);
                }
              } catch (_) {}
            }
          }

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

  /// Handles upload failure with bounded gentle retries: 5s, 15s, 30s, 60s.
  Future<void> _handleFailure(UploadItem item, String errorMessage) async {
    final nextRetryCount = item.retryCount + 1;

    if (nextRetryCount <= _retryDelaysSeconds.length) {
      final delaySeconds = _retryDelaysSeconds[nextRetryCount - 1];
      debugPrint(
        'Upload failed for ${item.fileName}. Will retry attempt $nextRetryCount in ${delaySeconds}s. Error: $errorMessage',
      );

      await database.updateUpload(item.copyWith(
        status: UploadStatus.waiting,
        retryCount: nextRetryCount,
        lastError: errorMessage,
      ));
      _safeNotifyListeners();

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
