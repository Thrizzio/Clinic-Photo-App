import 'package:flutter/material.dart';
import '../models/patient.dart';

class PatientTile extends StatelessWidget {
  final Patient patient;
  final VoidCallback onTap;
  final VoidCallback? onViewPhotos;
  final VoidCallback? onTakePhotos;

  const PatientTile({
    super.key,
    required this.patient,
    required this.onTap,
    this.onViewPhotos,
    this.onTakePhotos,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.5),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                patient.id,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: theme.colorScheme.onPrimaryContainer,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    patient.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (patient.folderStatus == FolderStatus.missing)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(Icons.auto_awesome, size: 12, color: theme.colorScheme.primary),
                          const SizedBox(width: 4),
                          Text(
                            'Folder auto-creates on photo capture',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (patient.folderStatus == FolderStatus.conflict)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, size: 13, color: Colors.red.shade700),
                          const SizedBox(width: 4),
                          Text(
                            'Conflicting Drive folders in Visits',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.red.shade800,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (onViewPhotos != null)
              IconButton(
                icon: const Icon(Icons.photo_library_outlined, size: 20),
                tooltip: 'View Photos',
                onPressed: onViewPhotos,
              ),
            if (onTakePhotos != null)
              IconButton(
                icon: const Icon(Icons.camera_alt_outlined, size: 20),
                tooltip: 'Take Photos',
                onPressed: onTakePhotos,
              )
            else
              Icon(
                patient.isUploadable ? Icons.chevron_right : Icons.info_outline,
                color: patient.isUploadable
                    ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
                    : (patient.folderStatus == FolderStatus.conflict
                        ? Colors.red.shade400
                        : Colors.amber.shade700),
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}
