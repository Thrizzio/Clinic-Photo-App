import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/upload_item.dart';

/// A reusable thumbnail widget for photos in a session, supporting
/// selection state, status badges, and tap gestures.
class SelectionThumbnail extends StatelessWidget {
  final UploadItem photo;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Future<Uint8List?> Function(String fileId)? fetchImageBytes;

  const SelectionThumbnail({
    super.key,
    required this.photo,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onTap,
    this.onLongPress,
    this.fetchImageBytes,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = File(photo.localPath);
    final fileExists = photo.localPath.isNotEmpty && file.existsSync();

    final timeStr = DateFormat('HH:mm:ss').format(photo.capturedAt);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Background photo or placeholder
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: fileExists
                ? Image.file(
                    file,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
                  )
                : (photo.driveFileId != null && fetchImageBytes != null
                    ? FutureBuilder<Uint8List?>(
                        future: fetchImageBytes!(photo.driveFileId!),
                        builder: (ctx, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            final isDark = theme.brightness == Brightness.dark;
                            return Container(
                              color: isDark ? Colors.grey.shade900 : Colors.grey.shade200,
                              child: const Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            );
                          }
                          final bytes = snapshot.data;
                          if (bytes != null) {
                            return Image.memory(bytes, fit: BoxFit.cover);
                          }
                          return _buildPlaceholder();
                        },
                      )
                    : _buildPlaceholder()),
          ),

          // Dark gradient overlay at bottom for timestamp readability
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: 28,
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
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              alignment: Alignment.bottomLeft,
              child: Text(
                '#${photo.sequenceNumber.toString().padLeft(3, '0')} • $timeStr',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),

          // Selection overlay / checkbox in selection mode
          if (isSelectionMode)
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

          // Status indicator (e.g. if failed or uploaded)
          if (!isSelectionMode && photo.status != UploadStatus.unassigned)
            Positioned(
              top: 6,
              right: 6,
              child: _buildStatusBadge(context),
            ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: Colors.grey.shade300,
      child: const Center(
        child: Icon(Icons.broken_image, color: Colors.grey, size: 28),
      ),
    );
  }

  Widget _buildStatusBadge(BuildContext context) {
    final color = switch (photo.status) {
      UploadStatus.pending => Colors.amber.shade800,
      UploadStatus.uploading => Colors.blue,
      UploadStatus.failed => Colors.red,
      UploadStatus.waiting => Colors.orange,
      UploadStatus.unassigned => Colors.grey,
      UploadStatus.uploaded => Colors.green,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        photo.status.name.toUpperCase(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 8,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

