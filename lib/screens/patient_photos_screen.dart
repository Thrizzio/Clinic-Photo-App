import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../config.dart';
import '../models/capture_session.dart';
import '../models/patient.dart';
import '../models/upload_item.dart';
import '../services/drive.dart';
import '../services/google_auth.dart';
import '../services/patient_folder_service.dart';
import '../services/upload_queue.dart';
import 'camera_screen.dart';

class PatientPhotosScreen extends StatefulWidget {
  final Patient patient;
  final GoogleAuthService authService;
  final DriveService driveService;
  final PatientFolderService? folderService;
  final UploadQueueService queueService;

  const PatientPhotosScreen({
    super.key,
    required this.patient,
    required this.authService,
    required this.driveService,
    this.folderService,
    required this.queueService,
  });

  /// Authoritative IST timestamp parser from filename (e.g. YYYYMMDD_HHMMSS_SSS) or Drive createdTime.
  static DateTime parsePhotoTimestamp(drive.File file) {
    final name = file.name ?? '';
    final match = RegExp(r'(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})(?:_(\d{3}))?').firstMatch(name);
    if (match != null) {
      final year = int.parse(match.group(1)!);
      final month = int.parse(match.group(2)!);
      final day = int.parse(match.group(3)!);
      final hour = int.parse(match.group(4)!);
      final minute = int.parse(match.group(5)!);
      final second = int.parse(match.group(6)!);
      final millis = match.group(7) != null ? int.parse(match.group(7)!) : 0;
      return DateTime(year, month, day, hour, minute, second, millis);
    }
    if (file.createdTime != null) {
      final istUtc = file.createdTime!.toUtc().add(const Duration(hours: 5, minutes: 30));
      return DateTime(istUtc.year, istUtc.month, istUtc.day, istUtc.hour, istUtc.minute, istUtc.second, istUtc.millisecond);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// Compact IST format for photo grid tile (e.g. "24 Mar, 03:45 PM")
  static String formatPhotoGridTimestamp(drive.File file) {
    final dt = parsePhotoTimestamp(file);
    if (dt.millisecondsSinceEpoch == 0) return '';
    return DateFormat('d MMM, hh:mm a').format(dt);
  }

  /// Detailed IST format for full-screen viewer (e.g. "24 Mar 2026, 03:45:12 PM IST")
  static String formatPhotoFullTimestamp(drive.File file) {
    final dt = parsePhotoTimestamp(file);
    if (dt.millisecondsSinceEpoch == 0) return '';
    return '${DateFormat('d MMM yyyy, hh:mm:ss a').format(dt)} IST';
  }

  @override
  State<PatientPhotosScreen> createState() => _PatientPhotosScreenState();
}

class _PatientPhotosScreenState extends State<PatientPhotosScreen> {
  late Patient _currentPatient;
  List<drive.File> _photos = [];
  bool _isLoading = true;
  String? _errorMessage;
  final Map<String, Uint8List> _thumbnailCache = {};
  final Map<String, UploadItem> _localUploadsByFileId = {};
  final Map<String, UploadItem> _localUploadsByFileName = {};

  // Multi-selection state
  bool _isSelectionMode = false;
  final Set<String> _selectedPhotoIds = {};

  @override
  void initState() {
    super.initState();
    _currentPatient = widget.patient;
    widget.queueService.addListener(_onQueueUpdated);
    _loadPhotos();
  }

  @override
  void dispose() {
    widget.queueService.removeListener(_onQueueUpdated);
    super.dispose();
  }

  void _onQueueUpdated() {
    if (mounted) {
      _refreshLocalUploads();
    }
  }

  Future<void> _refreshLocalUploads() async {
    final localUploads = await widget.queueService.database.getUploadsForPatient(_currentPatient.id);
    if (!mounted) return;
    setState(() {
      for (final u in localUploads) {
        _localUploadsByFileId[u.id] = u;
        if (u.driveFileId != null && u.driveFileId!.isNotEmpty) {
          _localUploadsByFileId[u.driveFileId!] = u;
        }
        _localUploadsByFileName[u.fileName] = u;
      }
    });
  }

  void _toggleSelection(String photoId) {
    setState(() {
      if (_selectedPhotoIds.contains(photoId)) {
        _selectedPhotoIds.remove(photoId);
        if (_selectedPhotoIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedPhotoIds.add(photoId);
      }
    });
  }

  void _enterSelectionMode([String? initialPhotoId]) {
    setState(() {
      _isSelectionMode = true;
      if (initialPhotoId != null) {
        _selectedPhotoIds.add(initialPhotoId);
      }
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedPhotoIds.clear();
    });
  }

  void _toggleSelectAll() {
    setState(() {
      final allValidIds = _photos.map((p) => p.id).whereType<String>().toSet();
      if (_selectedPhotoIds.length == allValidIds.length) {
        _selectedPhotoIds.clear();
        _isSelectionMode = false;
      } else {
        _selectedPhotoIds.addAll(allValidIds);
      }
    });
  }

  void _sortPhotos(List<drive.File> list) {
    list.sort((a, b) {
      final timeA = PatientPhotosScreen.parsePhotoTimestamp(a);
      final timeB = PatientPhotosScreen.parsePhotoTimestamp(b);
      final cmp = timeB.compareTo(timeA);
      if (cmp != 0) return cmp;
      return (b.name ?? '').compareTo(a.name ?? '');
    });
  }

  Future<void> _loadPhotos() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // 1. Immediately load local uploads from SQLite cache
    final localUploads = await widget.queueService.database.getUploadsForPatient(_currentPatient.id);
    for (final u in localUploads) {
      _localUploadsByFileId[u.id] = u;
      if (u.driveFileId != null && u.driveFileId!.isNotEmpty) {
        _localUploadsByFileId[u.driveFileId!] = u;
      }
      _localUploadsByFileName[u.fileName] = u;
    }

    final localPhotos = localUploads.map((u) => drive.File(
      id: u.driveFileId ?? u.id,
      name: u.fileName,
      createdTime: u.capturedAt,
    )).toList();

    _sortPhotos(localPhotos);

    if (mounted) {
      setState(() {
        _photos = localPhotos;
        if (localPhotos.isNotEmpty) {
          _isLoading = false;
        }
      });
    }

    if (_currentPatient.folderStatus == FolderStatus.conflict) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage =
              'Multiple Google Drive folders found across visits for this patient. '
              'Please resolve conflicting folders in Google Sheets before viewing photos.';
        });
      }
      return;
    }

    if (_currentPatient.driveFolderId == null || _currentPatient.driveFolderId!.isEmpty) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      return;
    }

    // 2. Fetch remote photos from Google Drive in background and reconcile
    try {
      final client = await widget.authService.getAuthenticatedClient();
      if (client == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            if (_photos.isEmpty) {
              _errorMessage = 'Google authorization required. Please sign in to view Drive photos.';
            }
          });
        }
        return;
      }

      final remotePhotos = await widget.driveService.listPatientPhotos(
        client: client,
        folderId: _currentPatient.driveFolderId!,
      );

      final mergedMap = <String, drive.File>{};
      for (final p in localPhotos) {
        final key = p.name ?? p.id ?? '';
        if (key.isNotEmpty) mergedMap[key] = p;
      }
      for (final p in remotePhotos) {
        final key = p.name ?? p.id ?? '';
        if (key.isNotEmpty) {
          mergedMap[key] = p;
          if (p.id != null) {
            final local = _localUploadsByFileName[p.name];
            if (local != null) {
              _localUploadsByFileId[p.id!] = local;
            }
          }
        }
      }

      final combined = mergedMap.values.toList();
      _sortPhotos(combined);

      if (mounted) {
        setState(() {
          _photos = combined;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Background Drive photo sync failed: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          if (_photos.isEmpty) {
            _errorMessage = 'Failed to load photos from Google Drive: $e';
          }
        });
      }
    }
  }

  Future<void> _handleTakePhotos() async {
    Patient patientToCapture = _currentPatient;

    if (patientToCapture.folderStatus == FolderStatus.conflict) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot capture photos: conflicting Drive folders in Visits sheet.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (patientToCapture.folderStatus == FolderStatus.missing && widget.folderService != null) {
      try {
        final res = await widget.folderService!.getOrCreatePatientFolder(patientToCapture);
        if (res.patient.isUploadable) {
          patientToCapture = res.patient;
          if (mounted) {
            setState(() {
              _currentPatient = patientToCapture;
            });
          }
        }
      } catch (e) {
        debugPrint('Drive folder setup deferred while offline: $e');
      }
    }

    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CameraScreen(
          patient: patientToCapture,
          queueService: widget.queueService,
        ),
      ),
    );

    _loadPhotos();
  }

  Future<Uint8List?> _fetchThumbnailBytes(String fileId, [String? fileName]) async {
    if (_thumbnailCache.containsKey(fileId)) {
      return _thumbnailCache[fileId];
    }

    // Check local disk cache first
    final upload = _localUploadsByFileId[fileId] ??
        (fileName != null ? _localUploadsByFileName[fileName] : null);
    if (upload != null) {
      final localFile = File(upload.localPath);
      if (localFile.existsSync()) {
        try {
          final bytes = await localFile.readAsBytes();
          _thumbnailCache[fileId] = bytes;
          return bytes;
        } catch (_) {}
      }
    }

    try {
      final client = await widget.authService.getAuthenticatedClient();
      if (client == null) return null;

      final bytes = await widget.driveService.getFileBytes(client: client, fileId: fileId);
      _thumbnailCache[fileId] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Multi-select move to Unassigned.
  /// Moves all selected photos into ONE new unassigned session folder on Drive.
  /// Inserts/updates local records in the `uploads` table with status 'uploaded'.
  /// Removes successfully moved photos from the patient gallery.
  Future<void> _handleMoveSelectedToUnassigned([List<drive.File>? specificPhotos]) async {
    final photosToMove = specificPhotos ??
        _photos.where((p) => p.id != null && _selectedPhotoIds.contains(p.id!)).toList();

    if (photosToMove.isEmpty) return;

    final count = photosToMove.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Move $count ${count == 1 ? 'photo' : 'photos'} to Unassigned?'),
        content: Text(
          'Move $count selected ${count == 1 ? 'photo' : 'photos'} to Unassigned Photos?\n\n'
          'They will be moved into a new unassigned session folder on Google Drive and detached from ${_currentPatient.displayName}. You can later assign them to any patient.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.inbox_outlined),
            label: Text('Move $count ${count == 1 ? 'Photo' : 'Photos'}'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text('Moving $count ${count == 1 ? 'photo' : 'photos'} on Google Drive...'),
              ],
            ),
          ),
        ),
      ),
    );

    final successfullyMovedIds = <String>{};
    String? lastError;

    try {
      final client = await widget.authService.getAuthenticatedClient();
      if (client == null) throw StateError('Not signed in to Google account');

      final parentFolderId = widget.folderService?.configService.loadConfig().parentDriveFolderId ?? '';
      if (parentFolderId.isEmpty) throw StateError('Parent Drive folder not configured');

      final unassignedRootId = await widget.driveService.getOrCreateUnassignedRootFolder(
        client: client,
        parentFolderId: parentFolderId,
      );

      // Create ONE unassigned session folder on Drive for this batch
      final sessionTs = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final sessionFolderId = await widget.driveService.getOrCreateUnassignedSessionFolder(
        client: client,
        unassignedRootId: unassignedRootId,
        sessionFolderTimestamp: sessionTs,
      );

      // Create ONE unassigned session in local SQLite database
      final sessionId = const Uuid().v4();
      final now = DateTime.now();
      final session = CaptureSession(
        id: sessionId,
        patientId: null,
        createdAt: now,
        status: 'unassigned',
        photoCount: count,
        driveFolderId: sessionFolderId,
      );
      await widget.queueService.database.insertSession(session);

      int seq = 1;
      for (final photo in photosToMove) {
        final fileId = photo.id;
        if (fileId == null) continue;

        try {
          // 1. Move file server-side on Google Drive
          await widget.driveService.moveFile(
            client: client,
            fileId: fileId,
            sourceFolderId: _currentPatient.driveFolderId!,
            targetFolderId: sessionFolderId,
          );

          // 2. Only after Drive succeeds, insert/update local photo record in uploads table
          final photoTs = PatientPhotosScreen.parsePhotoTimestamp(photo);
          final existingUpload = await widget.queueService.database.getUploadByDriveFileId(fileId) ??
              await widget.queueService.database.getUploadByFileName(photo.name ?? '');

          String localPath = existingUpload?.localPath ?? '';
          if (localPath.isNotEmpty && File(localPath).existsSync()) {
            try {
              final basePath = await widget.queueService.getBasePath();
              final unassignedSessionDir = Directory(
                p.join(basePath, AppConfig.photoQueueDirName, AppConfig.unassignedDirName, sessionId),
              );
              if (!unassignedSessionDir.existsSync()) {
                unassignedSessionDir.createSync(recursive: true);
              }
              final newLocalPath = p.join(unassignedSessionDir.path, p.basename(localPath));
              File(localPath).renameSync(newLocalPath);
              localPath = newLocalPath;
            } catch (_) {}
          }

          if (existingUpload != null) {
            await widget.queueService.database.updateUpload(existingUpload.copyWith(
              sessionId: sessionId,
              patientId: null,
              driveFolderId: sessionFolderId,
              driveParentFolderId: sessionFolderId,
              driveFileId: fileId,
              localPath: localPath,
              status: UploadStatus.uploaded,
            ));
          } else {
            await widget.queueService.database.insertUpload(UploadItem(
              id: const Uuid().v4(),
              sessionId: sessionId,
              patientId: null,
              driveFolderId: sessionFolderId,
              driveParentFolderId: sessionFolderId,
              driveFileId: fileId,
              localPath: localPath,
              fileName: photo.name ?? 'photo.jpg',
              status: UploadStatus.uploaded,
              createdAt: photoTs,
              capturedAt: photoTs,
              sequenceNumber: seq++,
            ));
          }

          successfullyMovedIds.add(fileId);
        } catch (e) {
          lastError = e.toString();
          debugPrint('Failed to move photo $fileId: $e');
        }
      }

      // If no photos succeeded, clean up the empty session
      if (successfullyMovedIds.isEmpty) {
        await widget.queueService.database.deleteSession(sessionId);
        try {
          await widget.driveService.deleteFile(client: client, fileId: sessionFolderId);
        } catch (_) {}
      }
    } catch (e) {
      lastError = e.toString();
    } finally {
      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading dialog

        if (successfullyMovedIds.isNotEmpty) {
          setState(() {
            _photos.removeWhere((p) => successfullyMovedIds.contains(p.id));
            _exitSelectionMode();
          });

          if (successfullyMovedIds.length == count) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Moved $count ${count == 1 ? 'photo' : 'photos'} to Unassigned Photos',
                ),
                backgroundColor: Colors.green.shade800,
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Moved ${successfullyMovedIds.length} photos. '
                  'Failed to move ${count - successfullyMovedIds.length} photos: $lastError',
                ),
                backgroundColor: Colors.orange.shade900,
              ),
            );
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to move photos: $lastError'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  /// Multi-select delete.
  /// Deletes selected photos from Google Drive first.
  /// Only updates/removes local DB records after Drive confirms deletion.
  /// Removes successfully deleted photos from the gallery; preserves failed ones.
  Future<void> _handleDeleteSelected([List<drive.File>? specificPhotos]) async {
    final photosToDelete = specificPhotos ??
        _photos.where((p) => p.id != null && _selectedPhotoIds.contains(p.id!)).toList();

    if (photosToDelete.isEmpty) return;

    final count = photosToDelete.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $count ${count == 1 ? 'Photo' : 'Photos'}?'),
        content: Text(
          'Permanently delete $count selected ${count == 1 ? 'photo' : 'photos'} from Google Drive?\n\n'
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete Permanently'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text('Deleting $count ${count == 1 ? 'photo' : 'photos'} from Google Drive...'),
              ],
            ),
          ),
        ),
      ),
    );

    final successfullyDeletedIds = <String>{};
    String? lastError;

    try {
      final client = await widget.authService.getAuthenticatedClient();
      if (client == null) throw StateError('Not signed in to Google account');

      for (final photo in photosToDelete) {
        final fileId = photo.id;
        if (fileId == null) continue;

        try {
          // 1. Delete on Google Drive first
          await widget.driveService.deleteFile(client: client, fileId: fileId);

          // 2. Only remove local database record after Drive confirmed deletion
          final existingUpload = await widget.queueService.database.getUploadByDriveFileId(fileId) ??
              await widget.queueService.database.getUploadByFileName(photo.name ?? '');
          if (existingUpload != null) {
            await widget.queueService.database.deleteUpload(existingUpload.id);
          }

          // Clear thumbnail cache
          _thumbnailCache.remove(fileId);
          successfullyDeletedIds.add(fileId);
        } catch (e) {
          lastError = e.toString();
          debugPrint('Failed to delete photo $fileId from Drive: $e');
        }
      }
    } catch (e) {
      lastError = e.toString();
    } finally {
      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading dialog

        if (successfullyDeletedIds.isNotEmpty) {
          setState(() {
            _photos.removeWhere((p) => successfullyDeletedIds.contains(p.id));
            _exitSelectionMode();
          });

          if (successfullyDeletedIds.length == count) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Deleted $count ${count == 1 ? 'photo' : 'photos'} permanently',
                ),
                backgroundColor: Colors.green.shade800,
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Deleted ${successfullyDeletedIds.length} photos. '
                  'Failed to delete ${count - successfullyDeletedIds.length} photos: $lastError',
                ),
                backgroundColor: Colors.orange.shade900,
              ),
            );
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete photos: $lastError'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }


  void _openFullScreenViewer(int initialIndex) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FullScreenPatientPhotoGallery(
          photos: _photos,
          initialIndex: initialIndex,
          patient: _currentPatient,
          fetchImageBytes: _fetchThumbnailBytes,
          onMoveToUnassigned: (photo) async {
            Navigator.of(context).pop();
            await _handleMoveSelectedToUnassigned([photo]);
          },
          onDeletePhoto: (photo) async {
            Navigator.of(context).pop();
            await _handleDeleteSelected([photo]);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: _isSelectionMode
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Cancel Selection',
                onPressed: _exitSelectionMode,
              ),
              title: Text(
                '${_selectedPhotoIds.length} selected',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              actions: [
                TextButton(
                  onPressed: _toggleSelectAll,
                  child: Text(
                    _selectedPhotoIds.length == _photos.length ? 'Deselect All' : 'Select All',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.inbox_outlined),
                  tooltip: 'Move to Unassigned',
                  onPressed: _selectedPhotoIds.isEmpty
                      ? null
                      : () => _handleMoveSelectedToUnassigned(),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  tooltip: 'Delete Selected',
                  onPressed: _selectedPhotoIds.isEmpty
                      ? null
                      : () => _handleDeleteSelected(),
                ),
              ],
            )
          : AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_currentPatient.displayName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  Text(
                    '${_currentPatient.phoneDisplay ?? ''}${_currentPatient.phoneDisplay != null ? ' • ' : ''}${_photos.length} ${_photos.length == 1 ? 'photo' : 'photos'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              actions: [
                if (_photos.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.checklist),
                    tooltip: 'Select Photos',
                    onPressed: () => _enterSelectionMode(),
                  ),
                IconButton(
                  icon: const Icon(Icons.camera_alt_outlined),
                  tooltip: 'Take Photos',
                  onPressed: _handleTakePhotos,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                  onPressed: _loadPhotos,
                ),
              ],
            ),
      body: RefreshIndicator(
        onRefresh: _loadPhotos,
        child: _buildBody(theme),
      ),
      floatingActionButton: _isSelectionMode
          ? null
          : FloatingActionButton.extended(
              onPressed: _handleTakePhotos,
              icon: const Icon(Icons.camera_alt),
              label: const Text('Take Photos'),
            ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null && _photos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _loadPhotos,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_photos.isEmpty) {
      final isMissingFolder = _currentPatient.folderStatus == FolderStatus.missing ||
          _currentPatient.driveFolderId == null ||
          _currentPatient.driveFolderId!.isEmpty;
      if (isMissingFolder) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.folder_open_outlined, size: 56, color: Colors.blueGrey.shade300),
                const SizedBox(height: 16),
                const Text(
                  'No photos yet',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Google Drive folder will be automatically created when the first photo is taken.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _handleTakePhotos,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Take First Photo'),
                ),
              ],
            ),
          ),
        );
      } else {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.photo_library_outlined, size: 56, color: Colors.grey.shade400),
                const SizedBox(height: 16),
                const Text(
                  'No photos found in patient folder',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Photos captured for this patient will appear here once uploaded.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _handleTakePhotos,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Take Photos'),
                ),
              ],
            ),
          ),
        );
      }
    }

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _photos.length,
      itemBuilder: (context, index) {
        final photo = _photos[index];
        final fileId = photo.id;
        final dateStr = PatientPhotosScreen.formatPhotoGridTimestamp(photo);
        final isSelected = fileId != null && _selectedPhotoIds.contains(fileId);
        final upload = (fileId != null ? _localUploadsByFileId[fileId] : null) ??
            _localUploadsByFileName[photo.name ?? ''];

        return InkWell(
          onTap: () {
            if (_isSelectionMode) {
              if (fileId != null) _toggleSelection(fileId);
            } else {
              _openFullScreenViewer(index);
            }
          },
          onLongPress: () {
            if (_isSelectionMode) {
              if (fileId != null) _toggleSelection(fileId);
            } else {
              if (fileId != null) {
                _enterSelectionMode(fileId);
              }
            }
          },
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: _isSelectionMode
                      ? Border.all(
                          color: isSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                          width: isSelected ? 3.0 : 1.0,
                        )
                      : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      fileId == null
                          ? Container(color: Colors.grey.shade300)
                          : FutureBuilder<Uint8List?>(
                              future: _fetchThumbnailBytes(fileId, photo.name),
                              builder: (ctx, snapshot) {
                                if (snapshot.connectionState == ConnectionState.waiting &&
                                    !_thumbnailCache.containsKey(fileId)) {
                                  return const _ShimmerSkeletonTile();
                                }
                                final bytes = snapshot.data ?? _thumbnailCache[fileId];
                                if (bytes != null) {
                                  return Image.memory(bytes, fit: BoxFit.cover);
                                }
                                final isDark = theme.brightness == Brightness.dark;
                                return Container(
                                  color: isDark ? Colors.grey.shade900 : Colors.grey.shade300,
                                  child: const Center(
                                    child: Icon(Icons.broken_image_outlined, size: 28, color: Colors.grey),
                                  ),
                                );
                              },
                            ),
                      if (isSelected)
                        Container(
                          color: theme.colorScheme.primary.withValues(alpha: 0.25),
                        ),
                    ],
                  ),
                ),
              ),
              if (upload != null)
                Positioned(
                  top: 6,
                  left: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: switch (upload.status) {
                        UploadStatus.pending => Colors.amber.shade800,
                        UploadStatus.uploading => Colors.blue.shade700,
                        UploadStatus.failed => Colors.red.shade700,
                        UploadStatus.uploaded => Colors.green.shade700,
                        _ => Colors.orange.shade700,
                      }.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      upload.status.name.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              if (dateStr.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.75),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    child: Text(
                      dateStr,
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              if (_isSelectionMode)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isSelected ? theme.colorScheme.primary : Colors.black45,
                      border: Border.all(
                        color: Colors.white,
                        width: 1.5,
                      ),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      isSelected ? Icons.check : null,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _FullScreenPatientPhotoGallery extends StatefulWidget {
  final List<drive.File> photos;
  final int initialIndex;
  final Patient patient;
  final Future<Uint8List?> Function(String fileId) fetchImageBytes;
  final Future<void> Function(drive.File photo)? onMoveToUnassigned;
  final Future<void> Function(drive.File photo)? onDeletePhoto;

  const _FullScreenPatientPhotoGallery({
    required this.photos,
    required this.initialIndex,
    required this.patient,
    required this.fetchImageBytes,
    this.onMoveToUnassigned,
    this.onDeletePhoto,
  });

  @override
  State<_FullScreenPatientPhotoGallery> createState() => _FullScreenPatientPhotoGalleryState();
}

class _FullScreenPatientPhotoGalleryState extends State<_FullScreenPatientPhotoGallery> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentPhoto = widget.photos[_currentIndex];
    final dateStr = PatientPhotosScreen.formatPhotoFullTimestamp(currentPhoto);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              currentPhoto.name ?? 'Patient Photo',
              style: const TextStyle(color: Colors.white, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
            if (dateStr.isNotEmpty)
              Text(
                dateStr,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
          ],
        ),
        actions: [
          if (widget.onMoveToUnassigned != null)
            IconButton(
              icon: const Icon(Icons.inbox_outlined),
              tooltip: 'Move to Unassigned',
              onPressed: () => widget.onMoveToUnassigned!(currentPhoto),
            ),
          if (widget.onDeletePhoto != null)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              tooltip: 'Delete Photo',
              onPressed: () => widget.onDeletePhoto!(currentPhoto),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: Text(
                '${_currentIndex + 1} / ${widget.photos.length}',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.photos.length,
        onPageChanged: (idx) {
          setState(() {
            _currentIndex = idx;
          });
        },
        itemBuilder: (context, index) {
          final photo = widget.photos[index];
          final fileId = photo.id;
          if (fileId == null) {
            return const Center(
              child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
            );
          }

          return FutureBuilder<Uint8List?>(
            future: widget.fetchImageBytes(fileId),
            builder: (ctx, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                );
              }
              final bytes = snapshot.data;
              if (bytes == null) {
                return const Center(
                  child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
                );
              }

              return InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Center(
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ShimmerSkeletonTile extends StatefulWidget {
  const _ShimmerSkeletonTile();

  @override
  State<_ShimmerSkeletonTile> createState() => _ShimmerSkeletonTileState();
}

class _ShimmerSkeletonTileState extends State<_ShimmerSkeletonTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark ? Colors.grey.shade800 : Colors.grey.shade300;
    final highlightColor = isDark ? Colors.grey.shade700 : Colors.grey.shade100;

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          color: Color.lerp(baseColor, highlightColor, _animation.value),
          child: Center(
            child: Icon(
              Icons.image_outlined,
              size: 28,
              color: isDark ? Colors.white24 : Colors.black12,
            ),
          ),
        );
      },
    );
  }
}
