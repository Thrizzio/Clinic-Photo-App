import 'package:flutter/material.dart';
import '../models/patient.dart';

class PatientTile extends StatelessWidget {
  final Patient patient;
  final VoidCallback onTap;

  const PatientTile({
    super.key,
    required this.patient,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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
            const SizedBox(width: 16),
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
                          Icon(Icons.folder_off_outlined, size: 13, color: Colors.amber.shade800),
                          const SizedBox(width: 4),
                          Text(
                            'Missing Drive folder in Visits',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.amber.shade900,
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
            Icon(
              patient.isUploadable
                  ? Icons.chevron_right
                  : Icons.info_outline,
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
