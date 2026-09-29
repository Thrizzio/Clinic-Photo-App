import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:intl/intl.dart';
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

  void _openFullScreenViewer(int initialIndex) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FullScreenPatientPhotoGallery(
          photos: _photos,
          initialIndex: initialIndex,
          patient: _currentPatient,
          fetchImageBytes: _fetchThumbnailBytes,
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
            Text(_currentPatient.name, style: const TextStyle(fontSize: 18)),
            Text(
              'ID: ${_currentPatient.id} • ${_photos.length} ${_photos.length == 1 ? 'photo' : 'photos'}',
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
        final dateStr = photo.createdTime != null
            ? DateFormat('MMM d, HH:mm').format(photo.createdTime!)
            : '';

        return InkWell(
          onTap: () => _openFullScreenViewer(index),
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
                            return Container(
                              color: Colors.grey.shade200,
                              child: const Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            );
                          }
                          final bytes = snapshot.data ?? _thumbnailCache[fileId];
                          if (bytes != null) {
                            return Image.memory(bytes, fit: BoxFit.cover);
                          }
                          return Container(
                            color: Colors.grey.shade300,
                            child: const Icon(Icons.image, color: Colors.grey),
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

  const _FullScreenPatientPhotoGallery({
    required this.photos,
    required this.initialIndex,
    required this.patient,
    required this.fetchImageBytes,
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
    final dateStr = currentPhoto.createdTime != null
        ? DateFormat('yyyy-MM-dd HH:mm:ss').format(currentPhoto.createdTime!)
        : '';

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
