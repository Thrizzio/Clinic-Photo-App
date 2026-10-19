import 'dart:io';
import 'package:flutter/material.dart';
import '../models/patient.dart';
import '../services/collage_service.dart';
import '../services/photo_export_service.dart';

class CollagePreviewScreen extends StatefulWidget {
  final Patient patient;
  final CollageResult collageResult;
  final PhotoExportService? exportService;

  const CollagePreviewScreen({
    super.key,
    required this.patient,
    required this.collageResult,
    this.exportService,
  });

  @override
  State<CollagePreviewScreen> createState() => _CollagePreviewScreenState();
}

class _CollagePreviewScreenState extends State<CollagePreviewScreen> {
  late final PhotoExportService _exportService;
  bool _isSaving = false;
  bool _isSharing = false;

  @override
  void initState() {
    super.initState();
    _exportService = widget.exportService ?? PhotoExportService();
  }

  Future<void> _handleSaveToGallery() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

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
                Text('Collage saved to device gallery'),
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
            content: Text('Failed to save collage: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
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

  @override
  Widget build(BuildContext context) {
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
            icon: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.file_download_outlined),
            tooltip: 'Save to Gallery',
            onPressed: _isSaving ? null : _handleSaveToGallery,
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
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: Image.file(
            File(widget.collageResult.filePath),
            fit: BoxFit.contain,
          ),
        ),
      ),
      bottomNavigationBar: Container(
        color: Colors.black87,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white38),
              ),
              onPressed: _isSaving ? null : _handleSaveToGallery,
              icon: const Icon(Icons.file_download_outlined),
              label: const Text('Save to Gallery'),
            ),
            FilledButton.icon(
              onPressed: _isSharing ? null : _handleShare,
              icon: const Icon(Icons.share),
              label: const Text('Share Collage'),
            ),
          ],
        ),
      ),
    );
  }
}
