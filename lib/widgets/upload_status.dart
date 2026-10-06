import 'package:flutter/material.dart';
import '../services/upload_queue.dart';

class UploadStatusPill extends StatelessWidget {
  final UploadQueueService queueService;
  final bool isDarkBackground;
  final String? patientId;

  const UploadStatusPill({
    super.key,
    required this.queueService,
    this.isDarkBackground = false,
    this.patientId,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: queueService,
      builder: (context, _) {
        return FutureBuilder<QueueStatus>(
          future: queueService.getStatus(patientId: patientId),
          builder: (context, snapshot) {
            final status = snapshot.data;
            if (status == null) {
              return const SizedBox.shrink();
            }

            if (status.hasFailures) {
              return InkWell(
                onTap: () => queueService.retryFailedUploads(),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.redAccent.shade100, width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 16, color: Colors.white),
                      const SizedBox(width: 6),
                      Text(
                        '! ${status.failedCount} failed · Tap to Retry',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            if (status.activeCount > 0) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isDarkBackground
                      ? Colors.black54
                      : Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                  border: isDarkBackground
                      ? Border.all(color: Colors.white30, width: 0.5)
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: isDarkBackground
                            ? Colors.white
                            : Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '↑ ${status.activeCount} uploading',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: isDarkBackground
                            ? Colors.white
                            : Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              );
            }

            // All photos uploaded: ONLY when photos exist and every photo is confirmed uploaded
            if (status.allPhotosUploaded) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isDarkBackground
                      ? Colors.black38
                      : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 14,
                      color: isDarkBackground ? Colors.greenAccent : Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'All photos uploaded',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDarkBackground
                            ? Colors.white70
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            }

            // Zero photos or idle with no confirmed uploads: show nothing
            return const SizedBox.shrink();
          },
        );
      },
    );
  }
}
