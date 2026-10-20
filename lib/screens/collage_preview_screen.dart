import 'dart:io';
import 'package:flutter/material.dart';
import '../models/patient.dart';
import '../models/upload_item.dart';
import '../services/collage_service.dart';
import '../services/photo_export_service.dart';
import '../services/upload_queue.dart';

class CollagePreviewScreen extends StatefulWidget {
  final Patient patient;
  final CollageResult collageResult;
  final PhotoExportService? exportService;
  final UploadQueueService? queueService;

  const CollagePreviewScreen({
    super.key,
    required this.patient,
    required this.collageResult,
    this.exportService,
    this.queueService,
  });

  @override
  State<CollagePreviewScreen> createState() => _CollagePreviewScreenState();
}

class _CollagePreviewScreenState extends State<CollagePreviewScreen> {
  late final PhotoExportService _exportService;
  bool _isSavingToGallery = false;
  bool _isSavingToPatient = false;
  bool _isSharing = false;
  UploadItem? _savedCollageItem;

  @override
  void initState() {
    super.initState();
    _exportService = widget.exportService ?? PhotoExportService();
    widget.queueService?.addListener(_onQueueUpdated);
  }

  @override
  void dispose() {
    widget.queueService?.removeListener(_onQueueUpdated);
    super.dispose();
  }

  void _onQueueUpdated() {
    if (_savedCollageItem != null && widget.queueService != null && mounted) {
      widget.queueService!.database.getUpload(_savedCollageItem!.id).then((updated) {
        if (updated != null && mounted) {
          setState(() {
            _savedCollageItem = updated;
          });
        }
      });
    }
  }

  Future<void> _handleSaveToPatient() async {
    if (_isSavingToPatient) return;
    if (_savedCollageItem != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Collage is already saved to this patient.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final queue = widget.queueService;
    if (queue == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Upload queue service not available.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSavingToPatient = true);

    try {
      final savedItem = await queue.enqueueCollage(
        patient: widget.patient,
        sourceCollagePath: widget.collageResult.filePath,
      );

      if (mounted) {
        setState(() {
          _savedCollageItem = savedItem;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Collage saved to ${widget.patient.displayName}\'s gallery',
                  ),
                ),
              ],
            ),
            action: SnackBarAction(
              label: 'View',
              textColor: Colors.amberAccent,
              onPressed: () {
                Navigator.of(context).pop(true);
              },
            ),
            backgroundColor: Colors.green.shade800,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save collage: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingToPatient = false);
    }
  }

  Future<void> _handleSaveToGallery() async {
    if (_isSavingToGallery) return;
    setState(() => _isSavingToGallery = true);

    try {
      await _exportService.saveToGallery(
        filePath: widget.collageResult.filePath,
        fileName: 'collage_${widget.patient.displayName.replaceAll(' ', '_')}.jpg',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 8),
                Text('Collage saved to device Photos / Gallery'),
              ],
            ),
            backgroundColor: Colors.green.shade800,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save to device gallery: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingToGallery = false);
    }
  }

  Future<void> _handleShare() async {
    if (_isSharing) return;
    setState(() => _isSharing = true);

    try {
      final fileName = 'collage_${widget.patient.displayName.replaceAll(' ', '_')}.jpg';
      await _exportService.shareSinglePhoto(
        filePath: widget.collageResult.filePath,
        fileName: fileName,
        text: 'Clinical collage for ${widget.patient.displayName}',
        subject: 'Clinical Photo Collage - ${widget.patient.displayName}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to share collage: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  Widget _buildStatusBanner() {
    if (_savedCollageItem == null) return const SizedBox.shrink();

    final status = _savedCollageItem!.status;
    final IconData icon;
    final String label;
    final Color color;

    switch (status) {
      case UploadStatus.uploaded:
        icon = Icons.cloud_done;
        label = 'Saved to patient & uploaded to Google Drive';
        color = Colors.greenAccent.shade400;
        break;
      case UploadStatus.uploading:
        icon = Icons.cloud_upload;
        label = 'Saved to patient · Uploading to Drive...';
        color = Colors.lightBlueAccent;
        break;
      case UploadStatus.failed:
        icon = Icons.cloud_off;
        label = 'Saved to patient locally · Upload pending retry';
        color = Colors.orangeAccent;
        break;
      case UploadStatus.waiting:
      case UploadStatus.pending:
      default:
        icon = Icons.cloud_queue;
        label = 'Saved to patient locally · Drive sync queued';
        color = Colors.lightBlueAccent;
        break;
    }

    return Container(
      width: double.infinity,
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSaved = _savedCollageItem != null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Clinical Collage',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              '${widget.patient.displayName} • ${widget.collageResult.width}×${widget.collageResult.height}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: _isSavingToGallery
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.file_download_outlined),
            tooltip: 'Save to device Photos',
            onPressed: _isSavingToGallery ? null : _handleSaveToGallery,
          ),
          IconButton(
            icon: _isSharing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.share_outlined),
            tooltip: 'Share Collage',
            onPressed: _isSharing ? null : _handleShare,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusBanner(),
          Expanded(
            child: Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.file(
                  File(widget.collageResult.filePath),
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        bottom: true,
        child: Container(
          color: Colors.black87,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // Primary action: Save to Patient (or View if already saved)
              Expanded(
                flex: 3,
                child: isSaved
                    ? FilledButton.icon(
                        key: const Key('view_in_patient_gallery_button'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.teal.shade700,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).pop(true),
                        icon: const Icon(Icons.photo_library),
                        label: const Text('View in Gallery'),
                      )
                    : FilledButton.icon(
                        key: const Key('save_to_patient_button'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: _isSavingToPatient ? null : _handleSaveToPatient,
                        icon: _isSavingToPatient
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.person_add_alt_1),
                        label: const Text('Save to Patient'),
                      ),
              ),
              const SizedBox(width: 8),

              // Secondary action: Save to device Photos
              Expanded(
                flex: 2,
                child: OutlinedButton.icon(
                  key: const Key('save_to_device_button'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: _isSavingToGallery ? null : _handleSaveToGallery,
                  icon: const Icon(Icons.file_download_outlined, size: 18),
                  label: const Text('To Device', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),

              // Secondary action: Share
              IconButton(
                key: const Key('share_collage_button'),
                style: IconButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Colors.white12,
                ),
                onPressed: _isSharing ? null : _handleShare,
                icon: const Icon(Icons.share, size: 20),
                tooltip: 'Share',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
