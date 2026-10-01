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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.5),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 1. Patient Avatar (initial letter)
            CircleAvatar(
              radius: 20,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                patient.displayName.isNotEmpty
                    ? patient.displayName[0].toUpperCase()
                    : '?',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 12),

            // 2. Constrained content area (Patient Name & Phone)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    patient.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      fontStyle: patient.hasValidName ? FontStyle.normal : FontStyle.italic,
                      color: patient.hasValidName
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if ((patient.phoneDisplay ?? patient.phoneNumber) != null &&
                      (patient.phoneDisplay ?? patient.phoneNumber)!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      patient.phoneDisplay ?? patient.phoneNumber!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (patient.folderStatus == FolderStatus.missing) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.auto_awesome, size: 12, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            'Folder auto-creates on photo capture',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ] else if (patient.folderStatus == FolderStatus.conflict) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, size: 13, color: theme.colorScheme.error),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            'Conflicting Drive folders in Visits',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.error,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),

            // 3. Fixed-width action buttons area
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onViewPhotos != null)
                  IconButton(
                    icon: const Icon(Icons.photo_library_outlined, size: 20),
                    tooltip: 'View Photos',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    padding: const EdgeInsets.all(6),
                    onPressed: onViewPhotos,
                  ),
                if (onTakePhotos != null)
                  IconButton(
                    icon: const Icon(Icons.camera_alt_outlined, size: 20),
                    tooltip: 'Take Photos',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    padding: const EdgeInsets.all(6),
                    onPressed: onTakePhotos,
                  )
                else
                  Padding(
                    padding: const EdgeInsets.all(6.0),
                    child: Icon(
                      patient.isUploadable ? Icons.chevron_right : Icons.info_outline,
                      color: patient.isUploadable
                          ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
                          : (patient.folderStatus == FolderStatus.conflict
                              ? theme.colorScheme.error
                              : Colors.amber.shade700),
                      size: 20,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
