import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/capture_session.dart';
import '../models/upload_item.dart';
import '../services/database.dart';
import '../services/patient_folder_service.dart';
import '../services/upload_queue.dart';
import '../widgets/patient_assignment_sheet.dart';
import '../widgets/selection_thumbnail.dart';

class SessionDetailScreen extends StatefulWidget {
  final CaptureSession session;
  final AppDatabase database;
  final UploadQueueService queueService;
  final PatientFolderService? folderService;

  const SessionDetailScreen({
    super.key,
    required this.session,
    required this.database,
    required this.queueService,
    this.folderService,
  });

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  List<UploadItem> _photos = [];
  bool _isLoading = true;
  bool _isSelectionMode = false;
  final Set<String> _selectedPhotoIds = {};
  final Map<String, Uint8List> _thumbnailCache = {};

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    final photos = await widget.database.getUploadsForSession(widget.session.id);
    if (mounted) {
      setState(() {
        _photos = photos;
        _isLoading = false;
      });
    }
  }

  Future<Uint8List?> _fetchThumbnailBytes(String fileId) async {
    if (_thumbnailCache.containsKey(fileId)) return _thumbnailCache[fileId];
    try {
      final client = await widget.queueService.authService.getAuthenticatedClient();
      if (client == null) return null;
      final bytes = await widget.queueService.driveService.getFileBytes(client: client, fileId: fileId);
      _thumbnailCache[fileId] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
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

  void _toggleSelectAll() {
    setState(() {
      if (_selectedPhotoIds.length == _photos.length) {
        _selectedPhotoIds.clear();
        _isSelectionMode = false;
      } else {
        _selectedPhotoIds.addAll(_photos.map((p) => p.id));
      }
    });
  }

  Future<void> _confirmDeleteSelected() async {
    final count = _selectedPhotoIds.length;
    if (count == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('Delete $count ${count == 1 ? 'Photo' : 'Photos'}?'),
        content: Text(
          'Are you sure you want to delete $count selected ${count == 1 ? 'photo' : 'photos'}? '
          'This action permanently removes the files from Google Drive and device storage.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _isLoading = true;
    });

    final idsToDelete = _selectedPhotoIds.toList();
    final photosToDelete = _photos.where((p) => idsToDelete.contains(p.id)).toList();
    final successfullyDeletedIds = <String>[];

    for (final photo in photosToDelete) {
      bool deleted = false;
      // 1. If photo is in Drive, delete from Drive first
      if (photo.driveFileId != null && photo.driveFileId!.isNotEmpty) {
        try {
          final client = await widget.queueService.authService.getAuthenticatedClient();
          if (client != null) {
            await widget.queueService.driveService.deleteFile(client: client, fileId: photo.driveFileId!);
            deleted = true;
          }
        } catch (e) {
          debugPrint('Error deleting photo ${photo.driveFileId} from Drive: $e');
        }
      } else {
        deleted = true;
      }

      // 2. Physically delete local files if any
      if (photo.localPath.isNotEmpty) {
        final file = File(photo.localPath);
        if (file.existsSync()) {
          try {
            file.deleteSync();
          } catch (e) {
            debugPrint('Error deleting local photo file: $e');
          }
        }
      }

      // 3. Delete database record only after deletion
      if (deleted) {
        await widget.database.deleteUpload(photo.id);
        if (photo.driveFileId != null) {
          _thumbnailCache.remove(photo.driveFileId!);
        }
        successfullyDeletedIds.add(photo.id);
      }
    }

    // 4. Reload photos
    final remaining = await widget.database.getUploadsForSession(widget.session.id);

    if (remaining.isEmpty) {
      // Clean up Drive session folder if empty
      if (widget.session.driveFolderId != null && widget.session.driveFolderId!.isNotEmpty) {
        try {
          final client = await widget.queueService.authService.getAuthenticatedClient();
          if (client != null) {
            final remainingInDrive = await widget.queueService.driveService.listPatientPhotos(
              client: client,
              folderId: widget.session.driveFolderId!,
            );
            if (remainingInDrive.isEmpty) {
              await widget.queueService.driveService.deleteFile(
                client: client,
                fileId: widget.session.driveFolderId!,
              );
            }
          }
        } catch (_) {}
      }

      // Remove session from database
      await widget.database.deleteSession(widget.session.id);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('All photos deleted. Session removed.'),
            backgroundColor: Colors.orange.shade800,
          ),
        );
        Navigator.of(context).pop(true);
      }
      return;
    }

    if (mounted) {
      setState(() {
        _photos = remaining;
        _selectedPhotoIds.removeAll(successfullyDeletedIds);
        if (_selectedPhotoIds.isEmpty) {
          _isSelectionMode = false;
        }
        _isLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Deleted ${successfullyDeletedIds.length} ${successfullyDeletedIds.length == 1 ? 'photo' : 'photos'}.'),
          backgroundColor: Colors.green.shade800,
        ),
      );
    }
  }

  Future<void> _handleAssign() async {
    final assigned = await PatientAssignmentSheet.show(
      context,
      sessionId: widget.session.id,
      database: widget.database,
      queueService: widget.queueService,
      folderService: widget.folderService,
    );

    if (assigned == true && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  void _showFullScreenPreview(UploadItem photo) {
    final file = File(photo.localPath);
    final hasLocal = photo.localPath.isNotEmpty && file.existsSync();

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
            title: Text(
              photo.fileName,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: hasLocal
                  ? Image.file(file)
                  : (photo.driveFileId != null
                      ? FutureBuilder<Uint8List?>(
                          future: _fetchThumbnailBytes(photo.driveFileId!),
                          builder: (ctx, snapshot) {
                            if (snapshot.connectionState == ConnectionState.waiting) {
                              return const Center(child: CircularProgressIndicator(color: Colors.white));
                            }
                            final bytes = snapshot.data;
                            if (bytes != null) {
                              return Image.memory(bytes);
                            }
                            return const Center(
                              child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
                            );
                          },
                        )
                      : const Center(
                          child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
                        )),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateFormatted = DateFormat('MMM d, yyyy • h:mm a').format(widget.session.createdAt);

    return Scaffold(
      appBar: AppBar(
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    _isSelectionMode = false;
                    _selectedPhotoIds.clear();
                  });
                },
              )
            : null,
        title: Text(_isSelectionMode ? '${_selectedPhotoIds.length} Selected' : 'Session Photos'),
        actions: [
          if (_isSelectionMode)
            TextButton(
              onPressed: _toggleSelectAll,
              child: Text(
                _selectedPhotoIds.length == _photos.length ? 'Deselect All' : 'Select All',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            )
          else ...[
            if (_photos.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.checklist),
                tooltip: 'Select Photos',
                onPressed: () {
                  setState(() {
                    _isSelectionMode = true;
                  });
                },
              ),
            TextButton.icon(
              onPressed: _handleAssign,
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Assign'),
            ),
          ],
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            dateFormatted,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${_photos.length} ${_photos.length == 1 ? 'photo' : 'photos'} captured in this session',
                            style: TextStyle(
                              fontSize: 13,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      if (!_isSelectionMode && _photos.isNotEmpty)
                        OutlinedButton.icon(
                          onPressed: () {
                            setState(() {
                              _isSelectionMode = true;
                            });
                          },
                          icon: const Icon(Icons.check_box_outlined, size: 16),
                          label: const Text('Select'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: _photos.isEmpty
                      ? const Center(child: Text('No photos in this session.'))
                      : GridView.builder(
                          padding: const EdgeInsets.all(12),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                          itemCount: _photos.length,
                          itemBuilder: (context, index) {
                            final photo = _photos[index];
                            final isSelected = _selectedPhotoIds.contains(photo.id);

                            return SelectionThumbnail(
                              photo: photo,
                              isSelectionMode: _isSelectionMode,
                              isSelected: isSelected,
                              fetchImageBytes: _fetchThumbnailBytes,
                              onTap: () {
                                if (_isSelectionMode) {
                                  _toggleSelection(photo.id);
                                } else {
                                  _showFullScreenPreview(photo);
                                }
                              },
                              onLongPress: () {
                                if (!_isSelectionMode) {
                                  setState(() {
                                    _isSelectionMode = true;
                                    _selectedPhotoIds.add(photo.id);
                                  });
                                }
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _isSelectionMode
              ? FilledButton.icon(
                  onPressed: _selectedPhotoIds.isEmpty ? null : _confirmDeleteSelected,
                  icon: const Icon(Icons.delete_outline),
                  label: Text('Delete Selected (${_selectedPhotoIds.length})'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                )
              : FilledButton.icon(
                  onPressed: _photos.isEmpty ? null : _handleAssign,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Assign to Patient'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
        ),
      ),
    );
  }
}
