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

  /// Formats deterministic photo filename in authoritative Indian Standard Time (UTC+05:30):
  /// `YYYYMMDD_HHMMSS_SSS_<sequence>.jpg`
  static String formatPhotoFileName(DateTime timestamp, int sequenceNumber) {
    final ist = timestamp.isUtc
        ? timestamp.add(const Duration(hours: 5, minutes: 30))
        : timestamp.toUtc().add(const Duration(hours: 5, minutes: 30));
    final dateStr = DateFormat('yyyyMMdd_HHmmss').format(ist);
    final msStr = ist.millisecond.toString().padLeft(3, '0');
    final seqStr = sequenceNumber.toString().padLeft(3, '0');
    return '${dateStr}_${msStr}_$seqStr.jpg';
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
    final seq = sequenceNumber ?? 1;
    final fileName = formatPhotoFileName(now, seq);

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

    tempFile.copySync(localPath);
    final savedFile = File(localPath);
    if (!savedFile.existsSync()) {
      throw FileSystemException('Failed to verify saved photo in private storage', localPath);
    }

    try {
      tempFile.deleteSync();
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
      sequenceNumber: seq,
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
    final seq = sequenceNumber ?? 1;
    final fileName = formatPhotoFileName(now, seq);

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

    tempFile.copySync(localPath);
    final savedFile = File(localPath);
    if (!savedFile.existsSync()) {
      throw FileSystemException('Failed to verify saved photo in private storage', localPath);
    }

    try {
      tempFile.deleteSync();
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
      sequenceNumber: seq,
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
  /// Validates that patient has an available Drive folder.
  /// For photos already on Google Drive, moves them server-side into the patient's Drive folder.
  /// For local photos, renames/moves files to the patient directory structure, transitions to 'waiting',
  /// and wakes the background upload worker.
  /// Once all photos succeed, verifies the Drive session folder is empty, deletes the empty Drive folder,
  /// and removes the session from SQLite.
  Future<void> assignSession({
    required String sessionId,
    required Patient patient,
  }) async {
    if (!patient.isUploadable) {
      throw ArgumentError(
        'Cannot assign session: Patient ${patient.id} folder status is ${patient.folderStatus.name}.',
      );
    }

    final session = await database.getSession(sessionId);
    final uploads = await database.getUploadsForSession(sessionId);
    final basePath = await _getBasePath();
    final patientSessionDir = Directory(
      p.join(basePath, AppConfig.photoQueueDirName, 'patients', patient.id, sessionId),
    );
    if (!patientSessionDir.existsSync()) {
      patientSessionDir.createSync(recursive: true);
    }

    final renamedPhotos = <String, ({String fileName, String localPath})>{};
    final failedPhotoIds = <String>[];
    String? lastError;

    for (var i = 0; i < uploads.length; i++) {
      final item = uploads[i];

      // If photo already exists on Google Drive, move it server-side
      if (item.driveFileId != null && item.driveFileId!.isNotEmpty) {
        try {
          final client = await authService.getAuthenticatedClient();
          if (client == null) throw StateError('Google account authorization not available.');
          final sourceFolder = item.driveFolderId ?? session?.driveFolderId;
          if (sourceFolder != null &&
              sourceFolder.isNotEmpty &&
              sourceFolder != patient.driveFolderId) {
            await driveService.moveFile(
              client: client,
              fileId: item.driveFileId!,
              sourceFolderId: sourceFolder,
              targetFolderId: patient.driveFolderId!,
            );
          }
          await database.updateUpload(item.copyWith(
            patientId: patient.id,
            driveFolderId: patient.driveFolderId,
            driveParentFolderId: patient.driveFolderId,
            status: UploadStatus.uploaded,
          ));
        } catch (e) {
          failedPhotoIds.add(item.id);
          lastError = e.toString();
          debugPrint('Failed to move photo ${item.id} to patient on Drive: $e');
        }
      } else {
        // Local file not yet uploaded
        final originalFile = File(item.localPath);
        final newFileName = item.fileName.startsWith('unassigned_')
            ? item.fileName.substring('unassigned_'.length)
            : item.fileName;
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
    }

    // Clean up empty local unassigned directory if empty
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

    // If all photos succeeded, verify Drive session folder is empty and delete it
    if (failedPhotoIds.isEmpty) {
      final driveSessionFolderId = session?.driveFolderId;
      if (driveSessionFolderId != null && driveSessionFolderId.isNotEmpty) {
        try {
          final client = await authService.getAuthenticatedClient();
          if (client != null) {
            final remainingInDrive = await driveService.listPatientPhotos(
              client: client,
              folderId: driveSessionFolderId,
            );
            if (remainingInDrive.isEmpty) {
              await driveService.deleteFile(client: client, fileId: driveSessionFolderId);
              debugPrint('Deleted empty unassigned Drive session folder: $driveSessionFolderId');
            } else {
              debugPrint(
                'Drive session folder $driveSessionFolderId still contains ${remainingInDrive.length} files. Not deleting.',
              );
            }
          }
        } catch (e) {
          debugPrint('Warning: unable to verify/delete Drive session folder: $e');
        }
      }

      // If no local or unassigned uploads remain for this session, remove session record
      final remaining = await database.getUploadsForSession(sessionId);
      final unassignedRemaining = remaining.where((u) => u.patientId == null).toList();
      if (unassignedRemaining.isEmpty) {
        await database.deleteSession(sessionId);
      }
    }

    _safeNotifyListeners();

    if (renamedPhotos.isNotEmpty) {
      unawaited(processQueue());
    }

    if (failedPhotoIds.isNotEmpty) {
      throw StateError(
        'Failed to move ${failedPhotoIds.length} of ${uploads.length} photos: $lastError',
      );
    }
  }

  /// Deletes an entire unassigned session:
  /// - Deletes all contained Drive photos.
  /// - Removes local DB records only after successful Drive deletion.
  /// - Once all photos are deleted, verifies the Drive session folder is empty and deletes it.
  /// - Removes the local session record.
  /// - Retains failed photos and session if partial deletion occurs.
  Future<void> deleteUnassignedSession(String sessionId) async {
    final session = await database.getSession(sessionId);
    final uploads = await database.getUploadsForSession(sessionId);

    final failedPhotoIds = <String>[];
    String? lastError;

    for (final item in uploads) {
      if (item.driveFileId != null && item.driveFileId!.isNotEmpty) {
        try {
          final client = await authService.getAuthenticatedClient();
          if (client == null) throw StateError('Google account authorization not available.');
          await driveService.deleteFile(client: client, fileId: item.driveFileId!);
          await database.deleteUpload(item.id);
        } catch (e) {
          failedPhotoIds.add(item.id);
          lastError = e.toString();
          debugPrint('Failed to delete Drive photo ${item.id}: $e');
        }
      } else {
        // Local photo
        final file = File(item.localPath);
        if (file.existsSync()) {
          try {
            file.deleteSync();
          } catch (_) {}
        }
        await database.deleteUpload(item.id);
      }
    }

    // If all photos deleted successfully, clean up empty Drive session folder and local session
    if (failedPhotoIds.isEmpty) {
      final driveSessionFolderId = session?.driveFolderId;
      if (driveSessionFolderId != null && driveSessionFolderId.isNotEmpty) {
        try {
          final client = await authService.getAuthenticatedClient();
          if (client != null) {
            final remainingInDrive = await driveService.listPatientPhotos(
              client: client,
              folderId: driveSessionFolderId,
            );
            if (remainingInDrive.isEmpty) {
              await driveService.deleteFile(client: client, fileId: driveSessionFolderId);
              debugPrint('Deleted empty unassigned Drive session folder: $driveSessionFolderId');
            }
          }
        } catch (e) {
          debugPrint('Warning: unable to verify/delete Drive session folder: $e');
        }
      }

      await database.deleteSession(sessionId);

      final basePath = await _getBasePath();
      final sessionDir = Directory(
        p.join(basePath, AppConfig.photoQueueDirName, AppConfig.unassignedDirName, sessionId),
      );
      if (sessionDir.existsSync()) {
        try {
          sessionDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }

    _safeNotifyListeners();

    if (failedPhotoIds.isNotEmpty) {
      throw StateError(
        'Failed to delete ${failedPhotoIds.length} of ${uploads.length} photos: $lastError',
      );
    }
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
