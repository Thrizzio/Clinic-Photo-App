import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/capture_session.dart';
import '../models/upload_item.dart';

class UnassignedSessionTile extends StatelessWidget {
  final CaptureSession session;
  final List<UploadItem> photos;
  final VoidCallback onViewPhotos;
  final VoidCallback onAssign;
  final VoidCallback? onDelete;
  final Future<Uint8List?> Function(String fileId)? fetchImageBytes;

  const UnassignedSessionTile({
    super.key,
    required this.session,
    this.photos = const [],
    required this.onViewPhotos,
    required this.onAssign,
    this.onDelete,
    this.fetchImageBytes,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateFormatted = DateFormat('dd MMM yyyy, hh:mm a').format(session.createdAt);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Preview thumbnail strip (if photos exist)
            if (photos.isNotEmpty) ...[
              _buildThumbnailStrip(theme),
              const SizedBox(height: 14),
            ],

            // Session metadata & sync state
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.inbox_outlined,
                    size: 24,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${session.photoCount} ${session.photoCount == 1 ? 'photo' : 'photos'}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        dateFormatted,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _buildSyncBadge(theme),
                    ],
                  ),
                ),
                if (onDelete != null)
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert, color: theme.colorScheme.onSurfaceVariant),
                    tooltip: 'Session Options',
                    onSelected: (val) {
                      if (val == 'delete') {
                        onDelete!();
                      }
                    },
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline, color: Colors.red, size: 20),
                            SizedBox(width: 8),
                            Text('Delete Session', style: TextStyle(color: Colors.red)),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),

            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 12),

            // Actions row
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: onViewPhotos,
                  icon: const Icon(Icons.visibility_outlined, size: 16),
                  label: const Text('View Photos'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: onAssign,
                  icon: const Icon(Icons.person_add_alt_1_outlined, size: 16),
                  label: const Text('Assign'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnailStrip(ThemeData theme) {
    const double thumbSize = 56;
    final maxPreviewCount = 4;
    final displayPhotos = photos.take(maxPreviewCount).toList();
    final remainingCount = photos.length - maxPreviewCount;

    return SizedBox(
      height: thumbSize,
      child: Row(
        children: [
          for (final photo in displayPhotos) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: thumbSize,
                height: thumbSize,
                child: _buildSingleThumbnail(photo, theme),
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (remainingCount > 0)
            Container(
              width: thumbSize,
              height: thumbSize,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                '+$remainingCount',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSingleThumbnail(UploadItem photo, ThemeData theme) {
    final file = File(photo.localPath);
    final hasLocal = photo.localPath.isNotEmpty && file.existsSync();

    if (hasLocal) {
      return Image.file(
        file,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholder(theme),
      );
    }

    if (photo.driveFileId != null && fetchImageBytes != null) {
      return FutureBuilder<Uint8List?>(
        future: fetchImageBytes!(photo.driveFileId!),
        builder: (ctx, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            final isDark = theme.brightness == Brightness.dark;
            return Container(
              color: isDark ? Colors.grey.shade900 : Colors.grey.shade200,
              child: const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final bytes = snapshot.data;
          if (bytes != null) {
            return Image.memory(bytes, fit: BoxFit.cover);
          }
          return _buildPlaceholder(theme);
        },
      );
    }

    return _buildPlaceholder(theme);
  }

  Widget _buildPlaceholder(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      color: isDark ? Colors.grey.shade900 : Colors.grey.shade200,
      child: Icon(
        Icons.image_outlined,
        size: 20,
        color: isDark ? Colors.white30 : Colors.black26,
      ),
    );
  }

  Widget _buildSyncBadge(ThemeData theme) {
    if (photos.isEmpty) {
      return const SizedBox.shrink();
    }

    final hasFailed = photos.any((p) => p.status == UploadStatus.failed);
    final hasUploading = photos.any((p) => p.status == UploadStatus.uploading);
    final hasWaiting = photos.any((p) => p.status == UploadStatus.waiting);
    final allUploaded = photos.every((p) =>
        p.status == UploadStatus.uploaded ||
        (p.driveFileId != null && p.driveFileId!.isNotEmpty));
    final isUnassigned = photos.every((p) => p.status == UploadStatus.unassigned);

    final (String label, Color color, IconData icon) = switch (true) {
      _ when hasFailed => ('Failed Upload', Colors.red, Icons.error_outline),
      _ when hasUploading => ('Uploading...', Colors.blue, Icons.sync),
      _ when hasWaiting => ('Pending Upload', Colors.orange, Icons.schedule),
      _ when allUploaded => ('Uploaded', Colors.green, Icons.cloud_done_outlined),
      _ when isUnassigned => ('Local Only', Colors.blueGrey, Icons.phone_android_outlined),
      _ => ('Ready', theme.colorScheme.primary, Icons.check_circle_outline),
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}

