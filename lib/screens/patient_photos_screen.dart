import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../models/capture_session.dart';
import '../models/patient.dart';
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

  @override
  void initState() {
    super.initState();
    _currentPatient = widget.patient;
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    if (_currentPatient.folderStatus == FolderStatus.missing ||
        _currentPatient.driveFolderId == null ||
        _currentPatient.driveFolderId!.isEmpty) {
      if (mounted) {
        setState(() {
          _photos = [];
          _isLoading = false;
        });
      }
      return;
    }

    if (_currentPatient.folderStatus == FolderStatus.conflict) {
      if (mounted) {
        setState(() {
          _photos = [];
          _isLoading = false;
          _errorMessage =
              'Multiple Google Drive folders found across visits for this patient. '
              'Please resolve conflicting folders in Google Sheets before viewing photos.';
        });
      }
      return;
    }

    try {
      final client = await widget.authService.getAuthenticatedClient();
      if (client == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = 'Google authorization required. Please sign in to view Drive photos.';
          });
        }
        return;
      }

      final photos = await widget.driveService.listPatientPhotos(
        client: client,
        folderId: _currentPatient.driveFolderId!,
      );

      // Deterministic descending sort by IST timestamp (newest first)
      photos.sort((a, b) {
        final timeA = PatientPhotosScreen.parsePhotoTimestamp(a);
        final timeB = PatientPhotosScreen.parsePhotoTimestamp(b);
        final cmp = timeB.compareTo(timeA);
        if (cmp != 0) return cmp;
        return (b.name ?? '').compareTo(a.name ?? '');
      });

      if (mounted) {
        setState(() {
          _photos = photos;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load photos from Google Drive: $e';
        });
      }
    }
  }

  Future<void> _handleTakePhotos() async {
    Patient patientToCapture = _currentPatient;

    if (!patientToCapture.isUploadable) {
      if (patientToCapture.folderStatus == FolderStatus.conflict) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot capture photos: conflicting Drive folders in Visits sheet.'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      if (widget.folderService != null) {
        setState(() {
          _isLoading = true;
        });
        try {
          final res = await widget.folderService!.getOrCreatePatientFolder(patientToCapture);
          if (res.patient.isUploadable) {
            patientToCapture = res.patient;
            if (mounted) {
              setState(() {
                _currentPatient = patientToCapture;
                _isLoading = false;
              });
            }
          } else {
            if (mounted) {
              setState(() {
                _isLoading = false;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Could not create folder: ${res.patient.folderStatus.name}'),
                  backgroundColor: Colors.red,
                ),
              );
            }
            return;
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _isLoading = false;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Folder creation failed: $e'), backgroundColor: Colors.red),
            );
          }
          return;
        }
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

  Future<Uint8List?> _fetchThumbnailBytes(String fileId) async {
    if (_thumbnailCache.containsKey(fileId)) {
      return _thumbnailCache[fileId];
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

  Future<void> _handleMoveToUnassigned(drive.File photo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to Unassigned?'),
        content: Text(
          'Move this photo to Unassigned Sessions?\n\n'
          'It will be detached from ${_currentPatient.displayName} and can later be assigned to any patient.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.inbox_outlined),
            label: const Text('Move to Unassigned'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Moving photo on Google Drive...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final client = await widget.authService.getAuthenticatedClient();
      if (client == null) throw StateError('Not signed in to Google account');

      final parentFolderId = widget.folderService?.configService.loadConfig().parentDriveFolderId ?? '';
      if (parentFolderId.isEmpty) throw StateError('Parent Drive folder not configured');

      final unassignedRootId = await widget.driveService.getOrCreateUnassignedRootFolder(
        client: client,
        parentFolderId: parentFolderId,
      );

      final sessionTs = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final sessionFolderId = await widget.driveService.getOrCreateUnassignedSessionFolder(
        client: client,
        unassignedRootId: unassignedRootId,
        sessionFolderTimestamp: sessionTs,
      );

      await widget.driveService.moveFile(
        client: client,
        fileId: photo.id!,
        sourceFolderId: _currentPatient.driveFolderId!,
        targetFolderId: sessionFolderId,
      );

      final sessionId = const Uuid().v4();
      final session = CaptureSession(
        id: sessionId,
        patientId: null,
        createdAt: DateTime.now(),
        status: 'unassigned',
        photoCount: 1,
        driveFolderId: sessionFolderId,
      );
      await widget.queueService.database.insertSession(session);

      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo moved to Unassigned Sessions')),
        );
        _loadPhotos();
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to move photo: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _handleDeletePhoto(drive.File photo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Photo?'),
        content: const Text(
          'Permanently delete this photo from Google Drive?\n\n'
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
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Deleting photo from Google Drive...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final client = await widget.authService.getAuthenticatedClient();
      if (client == null) throw StateError('Not signed in to Google account');

      await widget.driveService.deleteFile(
        client: client,
        fileId: photo.id!,
      );

      final uploads = await widget.queueService.database.getAllUploads();
      for (final u in uploads) {
        if (u.driveFileId == photo.id || u.fileName == photo.name) {
          await widget.queueService.database.deleteUpload(u.id);
        }
      }

      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo deleted successfully')),
        );
        setState(() {
          _photos.removeWhere((p) => p.id == photo.id);
        });
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete photo: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showPhotoOptionsSheet(drive.File photo) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.fullscreen),
              title: const Text('View Full Screen'),
              onTap: () {
                Navigator.of(ctx).pop();
                final idx = _photos.indexOf(photo);
                if (idx != -1) _openFullScreenViewer(idx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('Move to Unassigned'),
              onTap: () {
                Navigator.of(ctx).pop();
                _handleMoveToUnassigned(photo);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete Photo', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.of(ctx).pop();
                _handleDeletePhoto(photo);
              },
            ),
          ],
        ),
      ),
    );
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
            await _handleMoveToUnassigned(photo);
          },
          onDeletePhoto: (photo) async {
            Navigator.of(context).pop();
            await _handleDeletePhoto(photo);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
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
      floatingActionButton: FloatingActionButton.extended(
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

    if (_errorMessage != null) {
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

    if (_currentPatient.folderStatus == FolderStatus.missing ||
        _currentPatient.driveFolderId == null ||
        _currentPatient.driveFolderId!.isEmpty) {
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
    }

    if (_photos.isEmpty) {
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

        return InkWell(
          onTap: () => _openFullScreenViewer(index),
          onLongPress: () => _showPhotoOptionsSheet(photo),
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: fileId == null
                    ? Container(color: Colors.grey.shade300)
                    : FutureBuilder<Uint8List?>(
                        future: _fetchThumbnailBytes(fileId),
                        builder: (ctx, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting &&
                              !_thumbnailCache.containsKey(fileId)) {
                            return const _ShimmerSkeletonTile();
                          }
                          final bytes = snapshot.data ?? _thumbnailCache[fileId];
                          if (bytes != null) {
                            return Image.memory(bytes, fit: BoxFit.cover);
                          }
                          final isDark = Theme.of(context).brightness == Brightness.dark;
                          return Container(
                            color: isDark ? Colors.grey.shade900 : Colors.grey.shade300,
                            child: const Center(
                              child: Icon(Icons.broken_image_outlined, size: 28, color: Colors.grey),
                            ),
                          );
                        },
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
                          Colors.black.withValues(alpha: 0.7),
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
