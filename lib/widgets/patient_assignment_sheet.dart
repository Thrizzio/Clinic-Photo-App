import 'package:flutter/material.dart';
import '../models/patient.dart';
import '../services/database.dart';
import '../services/patient_folder_service.dart';
import '../services/upload_queue.dart';

class PatientAssignmentSheet extends StatefulWidget {
  final String sessionId;
  final AppDatabase database;
  final UploadQueueService queueService;
  final PatientFolderService? folderService;

  const PatientAssignmentSheet({
    super.key,
    required this.sessionId,
    required this.database,
    required this.queueService,
    this.folderService,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String sessionId,
    required AppDatabase database,
    required UploadQueueService queueService,
    PatientFolderService? folderService,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => PatientAssignmentSheet(
        sessionId: sessionId,
        database: database,
        queueService: queueService,
        folderService: folderService,
      ),
    );
  }

  @override
  State<PatientAssignmentSheet> createState() => _PatientAssignmentSheetState();
}

class _PatientAssignmentSheetState extends State<PatientAssignmentSheet> {
  final TextEditingController _searchController = TextEditingController();
  List<Patient> _patients = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadPatients('');
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPatients(String query) async {
    final results = await widget.database.searchPatients(query);
    if (mounted) {
      setState(() {
        _patients = results;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleSelectPatient(Patient patient) async {
    setState(() {
      _errorMessage = null;
    });

    Patient targetPatient = patient;

    if (patient.folderStatus == FolderStatus.missing) {
      if (widget.folderService != null) {
        setState(() {
          _isLoading = true;
        });
        try {
          final resolved = await widget.folderService!.getOrCreatePatientFolder(patient);
          if (resolved.patient.isUploadable) {
            await widget.database.updatePatient(resolved.patient);
            targetPatient = resolved.patient;
          } else {
            setState(() {
              _isLoading = false;
              _errorMessage =
                  'Could not resolve Drive folder for ${patient.name} (${patient.id}). Status: ${resolved.patient.folderStatus.name}';
            });
            return;
          }
        } catch (e) {
          setState(() {
            _isLoading = false;
            _errorMessage = 'Failed to create Drive folder: $e';
          });
          return;
        }
      } else {
        setState(() {
          _errorMessage =
              'Cannot assign to ${patient.name} (${patient.id}): This patient does not have a Google Drive folder in the Visits sheet. Photos remain safely saved.';
        });
        return;
      }
    }

    if (targetPatient.folderStatus == FolderStatus.conflict) {
      setState(() {
        _isLoading = false;
        _errorMessage =
            'Cannot assign to ${patient.name} (${patient.id}): This patient has conflicting Google Drive folders across different visits. Please resolve in the Visits sheet first.';
      });
      return;
    }

    try {
      await widget.queueService.assignSession(
        sessionId: widget.sessionId,
        patient: targetPatient,
      );

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Session assigned to ${targetPatient.name}. Photos queued for upload.',
            ),
            backgroundColor: Colors.green.shade800,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Assignment failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);

    return Container(
      height: mediaQuery.size.height * 0.8,
      padding: EdgeInsets.only(
        top: 16,
        left: 16,
        right: 16,
        bottom: mediaQuery.viewInsets.bottom + 16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Assign Photos to Patient',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Search for the patient in your clinic database:',
            style: TextStyle(
              fontSize: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            onChanged: _loadPatients,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Search by Patient ID or Name...',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
          if (_errorMessage != null)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.red.shade900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _patients.isEmpty
                    ? Center(
                        child: Text(
                          'No matching patients found.',
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _patients.length,
                        itemBuilder: (context, index) {
                          final patient = _patients[index];
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            leading: CircleAvatar(
                              backgroundColor: patient.isUploadable
                                  ? theme.colorScheme.primaryContainer
                                  : (patient.folderStatus == FolderStatus.conflict
                                      ? Colors.red.shade100
                                      : Colors.amber.shade100),
                              child: Text(
                                patient.id.length > 3
                                    ? patient.id.substring(patient.id.length - 3)
                                    : patient.id,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: patient.isUploadable
                                      ? theme.colorScheme.onPrimaryContainer
                                      : (patient.folderStatus == FolderStatus.conflict
                                          ? Colors.red.shade900
                                          : Colors.amber.shade900),
                                ),
                              ),
                            ),
                            title: Text(
                              patient.name,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            subtitle: Text('ID: ${patient.id}'),
                            trailing: patient.isUploadable
                                ? const Icon(Icons.check_circle_outline, color: Colors.green)
                                : (patient.folderStatus == FolderStatus.conflict
                                    ? const Icon(Icons.warning_amber_rounded, color: Colors.red)
                                    : const Icon(Icons.folder_off_outlined, color: Colors.amber)),
                            onTap: () => _handleSelectPatient(patient),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
