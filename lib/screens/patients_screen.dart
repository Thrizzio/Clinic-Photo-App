import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/patient.dart';
import '../services/config_service.dart';
import '../services/database.dart';
import '../services/drive.dart';
import '../services/google_auth.dart';
import '../services/patient_folder_service.dart';
import '../services/sheets.dart';
import '../services/upload_queue.dart';
import '../widgets/patient_tile.dart';
import '../widgets/upload_status.dart';
import 'camera_screen.dart';
import 'patient_photos_screen.dart';
import 'settings_screen.dart';
import 'unassigned_photos_screen.dart';

class PatientsScreen extends StatefulWidget {
  final GoogleAuthService authService;
  final ConfigService configService;
  final SheetsService sheetsService;
  final AppDatabase database;
  final UploadQueueService queueService;
  final DriveService? driveService;

  const PatientsScreen({
    super.key,
    required this.authService,
    required this.configService,
    required this.sheetsService,
    required this.database,
    required this.queueService,
    this.driveService,
  });

  @override
  State<PatientsScreen> createState() => _PatientsScreenState();
}

class _PatientsScreenState extends State<PatientsScreen> {
  final _searchController = TextEditingController();
  SearchFilterMode _selectedSearchMode = SearchFilterMode.all;
  List<Patient> _patients = [];
  int _unassignedSessionsCount = 0;
  bool _isLoadingCache = true;
  bool _isSyncing = false;
  String? _syncStatusMessage;
  bool _isOffline = false;
  late final PatientFolderService _patientFolderService = PatientFolderService(
    driveService: widget.driveService ?? DriveService(),
    sheetsService: widget.sheetsService,
    authService: widget.authService,
    configService: widget.configService,
    database: widget.database,
  );

  @override
  void initState() {
    super.initState();
    _loadCachedPatients();
    _syncSheetInBackground(forceFullSync: true);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Loads cached patients and unassigned sessions count immediately from SQLite.
  Future<void> _loadCachedPatients() async {
    final cached = await widget.database.getPatients();
    final unassignedCount = await widget.database.getUnassignedSessionsCount();
    if (mounted) {
      setState(() {
        _patients = cached;
        _unassignedSessionsCount = unassignedCount;
        _isLoadingCache = false;
      });
    }
  }

  Future<void> _refreshAll() async {
    final freshPatients = await widget.database.searchPatients(
      _searchController.text,
      mode: _selectedSearchMode,
    );
    final unassignedCount = await widget.database.getUnassignedSessionsCount();
    if (mounted) {
      setState(() {
        _patients = freshPatients;
        _unassignedSessionsCount = unassignedCount;
      });
    }
  }

  /// Background sync with Google Sheet.
  /// If [forceFullSync] is true, or if no full sync has occurred, or if incremental sync fails:
  /// performs a complete reconciliation using validateAndFetchPatients + replacePatients.
  Future<void> _syncSheetInBackground({bool forceFullSync = false}) async {
    final config = widget.configService.loadConfig();
    if (!config.hasCompletedSetup || config.spreadsheetId.isEmpty) return;

    if (mounted) {
      setState(() {
        _isSyncing = true;
      });
    }

    try {
      final client = await widget.authService.getAuthenticatedClient();
      if (client == null) {
        throw Exception('Not signed in');
      }

      final now = DateTime.now();

      if (!forceFullSync && config.lastSyncedRow > 1) {
        // Incremental sync
        final incResult = await widget.sheetsService.fetchIncrementalPatients(
          client: client,
          spreadsheetId: config.spreadsheetId,
          sheetName: config.sheetTabName,
          lastSyncedRow: config.lastSyncedRow,
        );

        if (incResult != null) {
          if (incResult.updatedPatients.isNotEmpty) {
            await widget.database.upsertPatients(incResult.updatedPatients);
          }
          await widget.configService.updateLastSync(
            now,
            lastSyncedRow: incResult.newLastSyncedRow,
          );
        } else {
          // Range failed or header changed: fallback to full sync
          final fullResult = await widget.sheetsService.validateAndFetchPatients(
            client: client,
            spreadsheetId: config.spreadsheetId,
            sheetName: config.sheetTabName,
          );
          await widget.database.replacePatients(fullResult.patients);
          await widget.configService.updateLastSync(
            now,
            lastSyncedRow: fullResult.totalRows,
            isFullSync: true,
          );
        }
      } else {
        // Full initial / manual refresh sync
        final fullResult = await widget.sheetsService.validateAndFetchPatients(
          client: client,
          spreadsheetId: config.spreadsheetId,
          sheetName: config.sheetTabName,
        );
        debugPrint('FULL RECONCILIATION RESULT PATIENTS: ${fullResult.patients.length}');
        for (final p in fullResult.patients.take(5)) {
          debugPrint('FULL RESULT PATIENT: id=${p.id}, name="${p.name}", displayName="${p.displayName}"');
        }
        await widget.database.replacePatients(fullResult.patients);
        await widget.configService.updateLastSync(
          now,
          lastSyncedRow: fullResult.totalRows,
          isFullSync: true,
        );
      }

      final dbPatients = await widget.database.getPatients();
      debugPrint('DIRECT DB QUERY AFTER SYNC (total ${dbPatients.length}):');
      for (final p in dbPatients.take(5)) {
        debugPrint('DB PATIENT: id=${p.id}, name="${p.name}", displayName="${p.displayName}"');
      }

      await _refreshAll();

      if (mounted) {
        final timeStr = DateFormat('h:mm a').format(now);
        setState(() {
          _isSyncing = false;
          _isOffline = false;
          _syncStatusMessage = '✓ Synced $timeStr';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _isOffline = true;
          _syncStatusMessage = 'Offline · Showing cached list';
        });
      }
    }
  }

  Future<void> _handleSearch(String query) async {
    final filtered = await widget.database.searchPatients(
      query,
      mode: _selectedSearchMode,
    );
    if (mounted) {
      setState(() {
        _patients = filtered;
      });
    }
  }

  void _openPatientPhotos(Patient patient) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PatientPhotosScreen(
          patient: patient,
          authService: widget.authService,
          driveService: widget.driveService ?? DriveService(),
          folderService: _patientFolderService,
          queueService: widget.queueService,
        ),
      ),
    );
  }

  Future<void> _handleTakePhotosForPatient(Patient patient) async {
    if (patient.folderStatus == FolderStatus.conflict) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.red),
              SizedBox(width: 8),
              Expanded(child: Text('Conflicting Drive Folders', style: TextStyle(fontSize: 18))),
            ],
          ),
          content: Text(
            'Cannot capture photos for ${patient.name} (${patient.id}).\n\n'
            'Multiple distinct Google Drive folders were found across visits for this patient. '
            'Please ensure only one consistent Drive folder is assigned in the Visits sheet and refresh.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    Patient targetPatient = patient;

    if (patient.folderStatus == FolderStatus.missing) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text('Setting up Drive folder for ${patient.name}...')),
            ],
          ),
          duration: const Duration(seconds: 4),
        ),
      );

      try {
        final res = await _patientFolderService.getOrCreatePatientFolder(patient);
        if (res.patient.isUploadable) {
          targetPatient = res.patient;
          await widget.database.updatePatient(targetPatient);
          await _loadCachedPatients();
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Could not create folder: ${res.patient.folderStatus.name}'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to create Drive folder: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
    }

    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CameraScreen(
          patient: targetPatient,
          queueService: widget.queueService,
        ),
      ),
    );
  }

  void _onPatientTapped(Patient patient) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: Theme.of(ctx).colorScheme.primaryContainer,
                    child: Text(
                      patient.id.length > 3 ? patient.id.substring(patient.id.length - 3) : patient.id,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(ctx).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          patient.displayName,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            fontStyle: patient.hasValidName ? FontStyle.normal : FontStyle.italic,
                            color: patient.hasValidName ? null : Theme.of(ctx).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          'ID: ${patient.id}${patient.phoneNumber != null && patient.phoneNumber!.isNotEmpty ? ' · ${patient.phoneNumber}' : ''}',
                          style: TextStyle(
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.camera_alt_outlined),
                title: const Text('Take Photos'),
                subtitle: Text(
                  patient.folderStatus == FolderStatus.missing
                      ? 'Creates Drive folder automatically'
                      : 'Capture clinical photos directly for this patient',
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _handleTakePhotosForPatient(patient);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('View Photos'),
                subtitle: const Text('Browse chronological photo gallery from Drive'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _openPatientPhotos(patient);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Starts Workflow B: creates a new unassigned session and opens camera immediately.
  Future<void> _startUnassignedSession() async {
    try {
      final session = await widget.queueService.createUnassignedSession();
      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CameraScreen(
            sessionId: session.id,
            queueService: widget.queueService,
          ),
        ),
      );

      _refreshAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start session: $e')),
        );
      }
    }
  }

  /// Opens the list of unassigned capture sessions.
  Future<void> _openUnassignedPhotos() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UnassignedPhotosScreen(
          database: widget.database,
          queueService: widget.queueService,
          folderService: _patientFolderService,
        ),
      ),
    );
    _refreshAll();
  }

  void _openSettings() {
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          authService: widget.authService,
          configService: widget.configService,
          sheetsService: widget.sheetsService,
          database: widget.database,
          queueService: widget.queueService,
          driveService: widget.driveService,
        ),
      ),
    )
        .then((_) {
      _loadCachedPatients();
      _syncSheetInBackground();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Patient', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: 'Unassigned Sessions',
            onPressed: _openUnassignedPhotos,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startUnassignedSession,
        icon: const Icon(Icons.add_a_photo),
        label: const Text('+ New / Unassigned'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Search Input
            Padding(
              padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 4.0),
              child: TextField(
                controller: _searchController,
                onChanged: _handleSearch,
                decoration: InputDecoration(
                  hintText: switch (_selectedSearchMode) {
                    SearchFilterMode.all => 'Search patient ID, name, or phone...',
                    SearchFilterMode.name => 'Search by patient name...',
                    SearchFilterMode.phone => 'Search by phone number...',
                    SearchFilterMode.patientId => 'Search by patient ID...',
                  },
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: () {
                            _searchController.clear();
                            _handleSearch('');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),

            // Search Filter Mode Selector
            Padding(
              padding: const EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 6.0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: SearchFilterMode.values.map((mode) {
                    final isSelected = _selectedSearchMode == mode;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: ChoiceChip(
                        label: Text(mode.label, style: const TextStyle(fontSize: 12)),
                        selected: isSelected,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onSelected: (selected) {
                          if (selected) {
                            setState(() {
                              _selectedSearchMode = mode;
                            });
                            _handleSearch(_searchController.text);
                          }
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),

            // Sync Status Banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: _isOffline
                  ? Colors.amber.shade50
                  : theme.colorScheme.surfaceContainerLow,
              child: Row(
                children: [
                  if (_isSyncing) ...[
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    const Text('Syncing patient database...', style: TextStyle(fontSize: 12)),
                  ] else ...[
                    Icon(
                      _isOffline ? Icons.cloud_off : Icons.cloud_done,
                      size: 14,
                      color: _isOffline ? Colors.amber.shade900 : Colors.green.shade700,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _syncStatusMessage ?? 'Ready',
                        style: TextStyle(
                          fontSize: 12,
                          color: _isOffline ? Colors.amber.shade900 : Colors.black87,
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: () => _syncSheetInBackground(forceFullSync: true),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        child: Text(
                          'Refresh',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // Unassigned Photos Banner (if any exist)
            if (_unassignedSessionsCount > 0)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amber.shade300),
                ),
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.photo_library, color: Colors.amber.shade900),
                  title: Text(
                    'Unassigned Photos ($_unassignedSessionsCount ${_unassignedSessionsCount == 1 ? "session" : "sessions"})',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Colors.amber.shade900,
                    ),
                  ),
                  subtitle: const Text(
                    'Tap to inspect thumbnails and assign to patients',
                    style: TextStyle(fontSize: 11),
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                  onTap: _openUnassignedPhotos,
                ),
              ),

            // Patients List
            Expanded(
              child: _isLoadingCache
                  ? const Center(child: CircularProgressIndicator())
                  : _patients.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32.0),
                            child: Text(
                              _searchController.text.isNotEmpty
                                  ? 'No patients match "${_searchController.text}"'
                                  : 'No patients found in sheet.\nTap Refresh to sync.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: () => _syncSheetInBackground(forceFullSync: true),
                          child: ListView.builder(
                            itemCount: _patients.length,
                            itemBuilder: (context, index) {
                              final patient = _patients[index];
                              return PatientTile(
                                patient: patient,
                                onTap: () => _onPatientTapped(patient),
                                onViewPhotos: () => _openPatientPhotos(patient),
                                onTakePhotos: () => _handleTakePhotosForPatient(patient),
                              );
                            },
                          ),
                        ),
            ),

            // Bottom Minimal Upload Status Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                border: Border(
                  top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.3)),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${_patients.length} patients',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  UploadStatusPill(queueService: widget.queueService),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
