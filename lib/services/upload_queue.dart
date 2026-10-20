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
import 'patient_folder_service.dart';
import 'remote_photo_cache.dart';

class QueueStatus {
  final int activeCount;
  final int failedCount;
  final int uploadedCount;
  final int totalCount;

  const QueueStatus({
    required this.activeCount,
    required this.failedCount,
    this.uploadedCount = 0,
    this.totalCount = 0,
  });

  bool get hasFailures => failedCount > 0;
  bool get hasWork => activeCount > 0 || failedCount > 0;
  bool get isIdle => activeCount == 0 && failedCount == 0;
  bool get allPhotosUploaded =>
      totalCount > 0 && activeCount == 0 && failedCount == 0 && uploadedCount == totalCount;
}

class PhotoDeletionResult {
  final bool remoteDeletionConfirmed;
  final bool remoteDeletionPending;

  const PhotoDeletionResult({
    required this.remoteDeletionConfirmed,
    required this.remoteDeletionPending,
  });
}

class UploadQueueService extends ChangeNotifier {
  final AppDatabase database;
  final GoogleAuthService authService;
  final DriveService driveService;
  final Connectivity connectivity;
  final String? customDocsDirectory;
  final String? customCacheDirectory;
  final Future<void> Function()? scheduleBackgroundWork;
  PatientFolderService? patientFolderService;

  RemotePhotoCacheService? _remotePhotoCacheService;
  RemotePhotoCacheService get remotePhotoCacheService =>
      _remotePhotoCacheService ??= RemotePhotoCacheService(
        database: database,
        driveService: driveService,
        customBaseDirectory: customCacheDirectory,
      );

  bool _isProcessing = false;
  bool _disposed = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  final Map<String, Timer> _retryTimers = {};
  static const _uuid = Uuid();

  // Retry backoff delays in seconds: 5s, 15s, 30s, 60s
  static const List<int> _retryDelaysSeconds = [5, 15, 30, 60];

  UploadQueueService({
    required this.database,
    required this.authService,
    required this.driveService,
    this.patientFolderService,
    Connectivity? connectivity,
    this.customDocsDirectory,
    this.customCacheDirectory,
    RemotePhotoCacheService? remotePhotoCacheService,
    this.scheduleBackgroundWork,
  }) : connectivity = connectivity ?? Connectivity() {
    _remotePhotoCacheService = remotePhotoCacheService;
    _initConnectivityListener();
    unawaited(recoverOrphanedPhotos());
    _bindFolderServiceListener();
  }

  void _bindFolderServiceListener() {
    if (patientFolderService != null) {
      patientFolderService!.onFolderCreated = (patient) {
        _safeNotifyListeners();
      };
    }
  }

  void setPatientFolderService(PatientFolderService service) {
    patientFolderService = service;
    _bindFolderServiceListener();
    unawaited(processQueue());
  }

  void _initConnectivityListener() {
    try {
      _connectivitySub = connectivity.onConnectivityChanged.listen((results) {
        final isDisconnected =
            results.contains(ConnectivityResult.none) && results.length == 1;
        if (!isDisconnected) {
          unawaited(processQueue());
          unawaited(processPendingPhotoDeletions());
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
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    super.dispose();
  }

  /// Wakes the durable worker without attempting interactive authentication.
  /// Call this after startup, app resume, connectivity restoration, or a
  /// successful UI sign-in.
  Future<void> wake() async {
    if (_disposed) return;
    await processQueue();
    await processPendingPhotoDeletions();
  }

  /// Gets current queue status counts (optionally filtered by patientId).
  Future<QueueStatus> getStatus({String? patientId}) async {
    if (patientId != null && patientId.isNotEmpty) {
      final uploads = await database.getUploadsForPatient(patientId);
      final active = uploads.where((u) =>
        u.status == UploadStatus.waiting ||
        u.status == UploadStatus.uploading ||
        u.status == UploadStatus.pending,
      ).length;
      final failed = uploads.where((u) => u.status == UploadStatus.failed).length;
      final uploaded = uploads.where((u) => u.status == UploadStatus.uploaded).length;
      return QueueStatus(
        activeCount: active,
        failedCount: failed,
        uploadedCount: uploaded,
        totalCount: uploads.length,
      );
    }
    final active = await database.getActiveUploadsCount();
    final failed = await database.getFailedUploadsCount();
    final uploaded = await database.getUploadedPhotosCount();
    return QueueStatus(
      activeCount: active,
      failedCount: failed,
      uploadedCount: uploaded,
      totalCount: active + failed + uploaded,
    );
  }

  Future<String> _getBasePath() async {
    return customDocsDirectory ??
        (await getApplicationDocumentsDirectory()).path;
  }

  /// Returns the base directory for photo storage.
  Future<String> getBasePath() async => _getBasePath();

  ({String fileName, String localPath}) _allocatePhotoPath(
    Directory directory,
    String requestedFileName,
  ) {
    var fileName = requestedFileName;
    var localPath = p.join(directory.path, fileName);
    var suffix = 0;
    while (File(localPath).existsSync()) {
      suffix++;
      final dot = requestedFileName.lastIndexOf('.');
      final stem = dot > 0 ? requestedFileName.substring(0, dot) : requestedFileName;
      final extension = dot > 0 ? requestedFileName.substring(dot) : '';
      fileName = '${stem}_$suffix$extension';
      localPath = p.join(directory.path, fileName);
    }
    return (fileName: fileName, localPath: localPath);
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
    final now = capturedAt ?? DateTime.now();
    final seq = sequenceNumber ?? 1;
    final requestedFileName = formatPhotoFileName(now, seq);

    final basePath = await _getBasePath();
    final Directory queueDir;
    if (sessionId != null && sessionId.isNotEmpty) {
      queueDir = Directory(
        p.join(basePath, AppConfig.photoQueueDirName, 'patients', patient.id, sessionId),
      );
    } else {
      queueDir = Directory(p.join(basePath, AppConfig.photoQueueDirName, 'patients', patient.id));
    }
    if (!queueDir.existsSync()) {
      queueDir.createSync(recursive: true);
    }

    final allocated = _allocatePhotoPath(queueDir, requestedFileName);
    final fileName = allocated.fileName;
    final localPath = allocated.localPath;
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

    final hasDriveFolder = patient.driveFolderId != null && patient.driveFolderId!.isNotEmpty;
    final item = UploadItem(
      id: _uuid.v4(),
      sessionId: sessionId,
      patientId: patient.id,
      driveFolderId: patient.driveFolderId,
      localPath: localPath,
      fileName: fileName,
      status: hasDriveFolder ? UploadStatus.waiting : UploadStatus.pending,
      retryCount: 0,
      createdAt: now,
      capturedAt: now,
      sequenceNumber: seq,
    );

    await database.insertUpload(item);
    _safeNotifyListeners();

    if (scheduleBackgroundWork != null) {
      unawaited(scheduleBackgroundWork!());
    }
    unawaited(processQueue());

    return item;
  }

  /// Formats deterministic collage filename in Indian Standard Time (UTC+05:30):
  /// `Collage_YYYY-MM-DD_HHmmss.jpg`
  static String formatCollageFileName(DateTime timestamp) {
    final ist = timestamp.isUtc
        ? timestamp.add(const Duration(hours: 5, minutes: 30))
        : timestamp.toUtc().add(const Duration(hours: 5, minutes: 30));
    final dateStr = DateFormat('yyyy-MM-dd_HHmmss').format(ist);
    return 'Collage_$dateStr.jpg';
  }

  /// Persists a generated clinical collage into durable app storage for [patient],
  /// registers an UploadItem record in SQLite, and wakes the Drive upload queue.
  Future<UploadItem> enqueueCollage({
    required Patient patient,
    required String sourceCollagePath,
    DateTime? createdAt,
  }) async {
    final sourceFile = File(sourceCollagePath);
    if (!sourceFile.existsSync() || sourceFile.lengthSync() == 0) {
      throw FileSystemException('Generated collage source file is missing or empty', sourceCollagePath);
    }

    final now = createdAt ?? DateTime.now();
    final requestedFileName = formatCollageFileName(now);

    final basePath = await _getBasePath();
    final patientDir = Directory(
      p.join(basePath, AppConfig.photoQueueDirName, 'patients', patient.id),
    );
    if (!patientDir.existsSync()) {
      patientDir.createSync(recursive: true);
    }

    final allocated = _allocatePhotoPath(patientDir, requestedFileName);
    final fileName = allocated.fileName;
    final durableLocalPath = allocated.localPath;

    sourceFile.copySync(durableLocalPath);
    final savedFile = File(durableLocalPath);
    if (!savedFile.existsSync()) {
      throw FileSystemException('Failed to verify saved collage in durable storage', durableLocalPath);
    }

    final hasDriveFolder = patient.driveFolderId != null && patient.driveFolderId!.isNotEmpty;
    final item = UploadItem(
      id: _uuid.v4(),
      sessionId: 'collage',
      patientId: patient.id,
      driveFolderId: patient.driveFolderId,
      localPath: durableLocalPath,
      fileName: fileName,
      status: hasDriveFolder ? UploadStatus.waiting : UploadStatus.pending,
      retryCount: 0,
      createdAt: now,
      capturedAt: now,
      sequenceNumber: 1,
    );

    await database.insertUpload(item);
    _safeNotifyListeners();

    if (scheduleBackgroundWork != null) {
      unawaited(scheduleBackgroundWork!());
    }
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
    final requestedFileName = formatPhotoFileName(now, seq);

    final basePath = await _getBasePath();
    final sessionDir = Directory(
      p.join(basePath, AppConfig.photoQueueDirName, AppConfig.unassignedDirName, sessionId),
    );
    if (!sessionDir.existsSync()) {
      sessionDir.createSync(recursive: true);
    }

    final allocated = _allocatePhotoPath(sessionDir, requestedFileName);
    final fileName = allocated.fileName;
    final localPath = allocated.localPath;
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

  /// Recovers both unassigned and patient-bound photos that reached private
  /// storage before the SQLite insert completed. Recovery is intentionally
  /// conservative: unknown patient directories are left untouched rather than
  /// inventing a route for clinical data.
  Future<void> recoverOrphanedPhotos() async {
    await recoverOrphanedUnassignedPhotos();
    await _recoverOrphanedPatientPhotos();
    await _recoverInterruptedPatientMoves();
    _safeNotifyListeners();
  }

  Future<void> _recoverOrphanedPatientPhotos() async {
    try {
      final basePath = await _getBasePath();
      final patientsDir = Directory(
        p.join(basePath, AppConfig.photoQueueDirName, 'patients'),
      );
      if (!patientsDir.existsSync()) return;

      final knownUploads = await database.getAllUploads();
      final knownPaths = knownUploads.map((u) => p.normalize(u.localPath)).toSet();
      for (final entity in patientsDir.listSync(recursive: true).whereType<File>()) {
        if (!entity.path.toLowerCase().endsWith('.jpg')) continue;
        final normalizedPath = p.normalize(entity.path);
        if (knownPaths.contains(normalizedPath)) continue;

        final relative = p.relative(entity.path, from: patientsDir.path);
        final parts = p.split(relative);
        if (parts.isEmpty) continue;
        final patientId = parts.first;
        final patient = await database.getPatient(patientId);
        if (patient == null) continue;

        final fileName = p.basename(entity.path);
        final sequenceMatch = RegExp(r'_(\d+)(?:_[0-9]+)?\.jpg$', caseSensitive: false).firstMatch(fileName);
        final sequence = int.tryParse(sequenceMatch?.group(1) ?? '') ?? 1;
        final capturedAt = entity.statSync().modified;
        final hasFolder = patient.driveFolderId != null && patient.driveFolderId!.isNotEmpty;
        await database.insertUpload(
          UploadItem(
            id: _uuid.v4(),
            sessionId: parts.length > 2 ? parts[1] : null,
            patientId: patient.id,
            driveFolderId: patient.driveFolderId,
            localPath: entity.path,
            fileName: fileName,
            status: hasFolder ? UploadStatus.waiting : UploadStatus.pending,
            retryCount: 0,
            createdAt: capturedAt,
            capturedAt: capturedAt,
            sequenceNumber: sequence,
          ),
        );
        knownPaths.add(normalizedPath);
        debugPrint('RECOVERED patient photo: $fileName for ${patient.id}');
      }
    } catch (e) {
      debugPrint('Error recovering orphaned patient photos: $e');
    }
  }

  /// Repairs a crash that happened after a local assignment rename but before
  /// the SQLite row update. The file name/session directory are deterministic,
  /// so the missing path can be repaired without touching Drive.
  Future<void> _recoverInterruptedPatientMoves() async {
    try {
      final basePath = await _getBasePath();
      final uploads = await database.getAllUploads();
      for (final item in uploads) {
        if (item.patientId == null || File(item.localPath).existsSync()) continue;
        final patientDir = Directory(
          p.join(basePath, AppConfig.photoQueueDirName, 'patients', item.patientId!),
        );
        if (!patientDir.existsSync()) continue;
        File? recovered;
        for (final entity in patientDir.listSync(recursive: true).whereType<File>()) {
          if (p.basename(entity.path) == item.fileName) {
            recovered = entity;
            break;
          }
        }
        if (recovered != null) {
          await database.updateUpload(item.copyWith(localPath: recovered.path));
        }
      }
    } catch (e) {
      debugPrint('Error recovering interrupted patient photo moves: $e');
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
    if (patient.folderStatus == FolderStatus.conflict) {
      throw ArgumentError(
        'Cannot assign session: Patient ${patient.id} folder status is ${patient.folderStatus.name}.',
      );
    }

    String? targetFolderId = patient.driveFolderId;
    if ((targetFolderId == null || targetFolderId.isEmpty) && patientFolderService != null) {
      try {
        final res = await patientFolderService!.getOrCreatePatientFolder(patient);
        targetFolderId = res.driveFolderId.isNotEmpty ? res.driveFolderId : res.patient.driveFolderId;
      } catch (e) {
        debugPrint('assignSession: Could not obtain folder for patient ${patient.id}: $e');
      }
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
        if (targetFolderId == null || targetFolderId.isEmpty) {
          failedPhotoIds.add(item.id);
          lastError = 'Target patient does not have a Google Drive folder yet.';
          debugPrint('Cannot move photo ${item.id} to patient on Drive: missing target folder');
          continue;
        }

        try {
          final client = await authService.getAuthenticatedClient();
          if (client == null) throw StateError('Google account authorization not available.');
          final sourceFolder = item.driveFolderId ?? session?.driveFolderId;
          if (sourceFolder != null &&
              sourceFolder.isNotEmpty &&
              sourceFolder != targetFolderId) {
            await driveService.moveFile(
              client: client,
              fileId: item.driveFileId!,
              sourceFolderId: sourceFolder,
              targetFolderId: targetFolderId,
            );
          }
          await database.updateUpload(item.copyWith(
            patientId: patient.id,
            driveFolderId: targetFolderId,
            driveParentFolderId: targetFolderId,
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
      driveFolderId: targetFolderId,
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
      final latestSession = await database.getSession(sessionId);
      if (latestSession != null) {
        await database.updateSession(latestSession.copyWith(status: 'assignment_failed'));
      }
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
        final pendingItem = await database.getNextPendingUpload();
        if (pendingItem == null) break;
        var currentItem = pendingItem;

        final localFile = File(currentItem.localPath);
        if (!localFile.existsSync()) {
          await database.updateUpload(currentItem.copyWith(
            status: UploadStatus.failed,
            lastError: 'Local photo file not found at ${currentItem.localPath}',
            clearNextAttemptAt: true,
          ));
          _safeNotifyListeners();
          continue;
        }

        // For an existing Drive file, driveFolderId is the source folder
        // until the move is confirmed; the patient record supplies the target.
        String? targetFolderId = currentItem.driveFileId != null &&
                currentItem.driveFileId!.isNotEmpty
            ? null
            : currentItem.driveFolderId;
        Patient? patient;
        if (currentItem.patientId != null) {
          patient = await database.getPatient(currentItem.patientId!);
          if (patient?.driveFolderId != null && patient!.driveFolderId!.isNotEmpty) {
            targetFolderId = patient.driveFolderId;
          }
        }

        if (targetFolderId == null || targetFolderId.isEmpty) {
          // If patient has an ID, try to resolve Drive folder
          if (currentItem.patientId != null) {
            if (patient != null) {
              if (patientFolderService != null) {
                try {
                  final client = await authService.getAuthenticatedClientSilently();
                  if (client != null) {
                    final res = await patientFolderService!.getOrCreatePatientFolder(
                      patient,
                      clientOverride: client,
                    );
                    if (res.patient.driveFolderId != null && res.patient.driveFolderId!.isNotEmpty) {
                      targetFolderId = res.patient.driveFolderId;
                      if (currentItem.driveFileId == null || currentItem.driveFileId!.isEmpty) {
                        currentItem = currentItem.copyWith(
                          driveFolderId: targetFolderId,
                          status: UploadStatus.waiting,
                          clearNextAttemptAt: true,
                        );
                        await database.updateUpload(currentItem);
                      }
                      _safeNotifyListeners();
                    } else {
                      await _handleFailure(
                        currentItem,
                        'Patient Drive folder could not be resolved yet.',
                      );
                      break;
                    }
                  } else {
                    await _handleFailure(
                      currentItem,
                      'Google authorization is not available for background upload.',
                    );
                    break;
                  }
                } catch (e) {
                  debugPrint('Folder creation for patient upload deferred: $e');
                  await _handleFailure(currentItem, 'Drive folder resolution failed: $e');
                  break;
                }
              } else {
                await _handleFailure(
                  currentItem,
                  'Patient folder service is not configured.',
                );
                break;
              }
            } else {
              await _handleFailure(currentItem, 'Patient record is not available locally.');
              break;
            }
          } else {
            await _handleFailure(currentItem, 'Upload has no patient route.');
            break;
          }

          if (targetFolderId == null || targetFolderId.isEmpty) {
            debugPrint('Pending upload ${currentItem.id} waiting for Drive folder creation.');
            break;
          }
        }

        // Claim only after local validation and folder resolution. The
        // conditional SQLite update still serializes overlapping foreground
        // and WorkManager workers without exposing an uploading badge during
        // the pending/offline phase.
        final claimedItem = await database.claimUpload(currentItem.id);
        if (claimedItem == null) continue;
        currentItem = claimedItem;
        _safeNotifyListeners();

        final client = await authService.getAuthenticatedClientSilently();
        if (client == null) {
          await _handleFailure(
            currentItem,
            'Google account authorization not available for background upload.',
          );
          break;
        }

        try {
          String driveFileId;
          if (currentItem.driveFileId != null && currentItem.driveFileId!.isNotEmpty) {
            // An item already created on Drive (for example an unassigned
            // photo) must be moved, not uploaded a second time.
            final sourceFolder = currentItem.driveFolderId;
            if (sourceFolder == null || sourceFolder.isEmpty) {
              throw StateError('Existing Drive photo has no source folder.');
            }
            if (sourceFolder != targetFolderId) {
              await driveService.moveFile(
                client: client,
                fileId: currentItem.driveFileId!,
                sourceFolderId: sourceFolder,
                targetFolderId: targetFolderId,
              );
            }
            driveFileId = currentItem.driveFileId!;
          } else {
            // Reconcile the deterministic filename before every create. The
            // lookup is best-effort for a first attempt, but mandatory after
            // a retry/recovered crash so an accepted Drive request cannot be
            // duplicated after process death.
            String? existingDriveFileId;
            try {
              final existing = await driveService.findPhotoByName(
                client: client,
                folderId: targetFolderId,
                fileName: currentItem.fileName,
              );
              existingDriveFileId = existing?.id;
            } catch (lookupError) {
              if (currentItem.retryCount > 0) rethrow;
              debugPrint('Initial Drive idempotency lookup deferred: $lookupError');
            }

            if (existingDriveFileId != null && existingDriveFileId.isNotEmpty) {
              driveFileId = existingDriveFileId;
            } else {
              driveFileId = await driveService.uploadPhoto(
                client: client,
                file: localFile,
                folderId: targetFolderId,
                fileName: currentItem.fileName,
              );
            }
          }

          // DRIVE CONFIRMED:
          // In V5, local file is retained as an offline cache for instant viewing.
          // Update SQLite record with status uploaded and drive_file_id:
          await database.updateUpload(currentItem.copyWith(
            status: UploadStatus.uploaded,
            driveFileId: driveFileId,
            driveFolderId: targetFolderId,
            driveParentFolderId: targetFolderId,
            lastError: null,
            clearNextAttemptAt: true,
          ));

          // If item belonged to an unassigned session, check if session is completed
          if (currentItem.sessionId != null) {
            final remaining = await database.getUploadsForSession(currentItem.sessionId!);
            final pendingInSession = remaining.where(
              (u) => u.status != UploadStatus.uploaded,
            ).toList();
            if (pendingInSession.isEmpty) {
              await database.deleteSession(currentItem.sessionId!);
            }
          }

          debugPrint('Upload finalized and marked uploaded for: ${currentItem.fileName} ($driveFileId)');
          _safeNotifyListeners();
        } catch (e) {
          debugPrint('Upload attempt failed for ${currentItem.fileName}: $e');
          // A timeout can happen after Drive has accepted the file. Reconcile
          // by deterministic folder/name before scheduling another create.
          var reconciled = false;
          try {
            final existing = await driveService.findPhotoByName(
              client: client,
              folderId: targetFolderId,
              fileName: currentItem.fileName,
            );
            if (existing?.id != null && existing!.id!.isNotEmpty) {
              await database.updateUpload(currentItem.copyWith(
                status: UploadStatus.uploaded,
                driveFileId: existing.id,
                driveFolderId: targetFolderId,
                driveParentFolderId: targetFolderId,
                clearLastError: true,
                clearNextAttemptAt: true,
              ));

              if (currentItem.sessionId != null) {
                final remaining = await database.getUploadsForSession(currentItem.sessionId!);
                if (remaining.every((u) => u.status == UploadStatus.uploaded)) {
                  await database.deleteSession(currentItem.sessionId!);
                }
              }
              reconciled = true;
              _safeNotifyListeners();
            }
          } catch (reconcileError) {
            debugPrint('Could not reconcile ambiguous Drive upload: $reconcileError');
          }
          if (!reconciled) {
            await _handleFailure(currentItem, e.toString());
          }
        }
      }
    } finally {
      _isProcessing = false;
      _safeNotifyListeners();
      await processPendingPhotoDeletions();
    }
  }

  /// Processes any offline photo deletions that were pending network/Drive sync.
  Future<void> processPendingPhotoDeletions() async {
    final pendingDeletions = await database.getPendingPhotoDeletions();
    if (pendingDeletions.isEmpty) return;

    final client = await authService.getAuthenticatedClientSilently();
    if (client == null) return;

    for (final deletion in pendingDeletions) {
      final id = deletion['id'] as String;
      final fileId = deletion['drive_file_id'] as String?;
      final folderId = deletion['drive_folder_id'] as String?;

      if (fileId != null && fileId.isNotEmpty) {
        try {
          await driveService.deleteFile(
            client: client,
            fileId: fileId,
            parentFolderId: folderId,
          );
          await database.removePendingPhotoDeletion(id);
          debugPrint('Processed pending photo deletion on Drive for $fileId');
        } catch (e) {
          debugPrint('Retry pending photo deletion deferred: $e');
        }
      } else {
        await database.removePendingPhotoDeletion(id);
      }
    }
  }

  /// Deletes one local photo without violating the Drive-first safety rule.
  ///
  /// If Drive cannot be reached, a durable pending deletion is written before
  /// the local cache/row is removed. Explicit Drive API failures leave the
  /// photo visible and retryable instead of silently losing it.
  Future<PhotoDeletionResult> deletePhotoSafely(
    UploadItem item, {
    String? patientId,
  }) async {
    final fileId = item.driveFileId;
    var remoteDeletionConfirmed = fileId == null || fileId.isEmpty;
    var pendingRemoteDeletion = false;

    if (!remoteDeletionConfirmed) {
      final client = await authService.getAuthenticatedClientSilently();
      if (client != null) {
        try {
          await driveService.deleteFile(
            client: client,
            fileId: fileId,
            parentFolderId: item.driveFolderId,
          );
          remoteDeletionConfirmed = true;
        } catch (e) {
          final message = e.toString().toLowerCase();
          final offline = e is SocketException ||
              message.contains('socketexception') ||
              message.contains('timeout') ||
              message.contains('network') ||
              message.contains('connection');
          if (!offline) rethrow;
          pendingRemoteDeletion = true;
        }
      } else {
        pendingRemoteDeletion = true;
      }
    }

    if (pendingRemoteDeletion && fileId != null && fileId.isNotEmpty) {
      // Persist the remote operation before touching local state.
      await database.addPendingPhotoDeletion(
        id: _uuid.v4(),
        driveFileId: fileId,
        fileName: item.fileName,
        patientId: patientId ?? item.patientId,
        driveFolderId: item.driveFolderId,
      );
    }

    final localFile = item.localPath.isNotEmpty ? File(item.localPath) : null;
    if (localFile != null && localFile.existsSync()) {
      await localFile.delete();
    }
    await database.deleteUpload(item.id);
    await database.recordDeletedPhotoTombstone(
      driveFileId: item.driveFileId,
      fileName: item.fileName,
      patientId: patientId ?? item.patientId,
    );
    _safeNotifyListeners();
    return PhotoDeletionResult(
      remoteDeletionConfirmed: remoteDeletionConfirmed,
      remoteDeletionPending: pendingRemoteDeletion,
    );
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
        nextAttemptAt: DateTime.now().add(Duration(seconds: delaySeconds)),
      ));
      _safeNotifyListeners();

      _retryTimers[item.id]?.cancel();
      _retryTimers[item.id] = Timer(Duration(seconds: delaySeconds), () {
        _retryTimers.remove(item.id);
        if (!_disposed) unawaited(processQueue());
      });
    } else {
      debugPrint(
        'Upload exceeded max retries for ${item.fileName}. Marking failed. Error: $errorMessage',
      );
      await database.updateUpload(item.copyWith(
        status: UploadStatus.failed,
        retryCount: nextRetryCount,
        lastError: errorMessage,
        clearNextAttemptAt: true,
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

  /// Safely cleans up local disk files for verified uploads older than [maxAge] (30 days).
  ///
  /// INVARIANTS:
  /// - Only items with status == UploadStatus.uploaded are eligible.
  /// - Must have a valid non-empty driveFileId.
  /// - Must not be part of an unassigned session or active session.
  /// - Never deletes pending, waiting, uploading, failed, or ambiguous uploads.
  /// - Sets localPath to empty string in SQLite so the record remains a valid remote reference pointer.
  Future<int> cleanupOldVerifiedUploads({Duration maxAge = const Duration(days: 30)}) async {
    final cutoff = DateTime.now().subtract(maxAge);
    final all = await database.getAllUploads();
    var cleanedCount = 0;

    for (final item in all) {
      if (item.status != UploadStatus.uploaded) continue;
      if (item.driveFileId == null || item.driveFileId!.isEmpty) continue;
      if (item.capturedAt.isAfter(cutoff)) continue;
      if (item.sessionId != null) {
        final session = await database.getSession(item.sessionId!);
        if (session != null && session.status == 'unassigned') continue;
      }

      if (item.localPath.isNotEmpty) {
        final file = File(item.localPath);
        if (file.existsSync()) {
          try {
            file.deleteSync();
            cleanedCount++;
          } catch (e) {
            debugPrint('Error deleting old verified local capture ${item.localPath}: $e');
          }
        }
        await database.updateUpload(item.copyWith(localPath: ''));
      }
    }
    return cleanedCount;
  }
}
