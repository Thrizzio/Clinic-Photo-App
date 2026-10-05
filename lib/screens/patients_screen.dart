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
import '../widgets/new_patient_dialog.dart';
import '../services/patient_sync_service.dart';
import '../services/supabase_patient_service.dart';

class PatientsScreen extends StatefulWidget {
  final GoogleAuthService authService;
  final ConfigService configService;
  final SheetsService sheetsService;
  final AppDatabase database;
  final UploadQueueService queueService;
  final DriveService? driveService;
  final SupabasePatientService? supabaseService;

  const PatientsScreen({
    super.key,
    required this.authService,
    required this.configService,
    required this.sheetsService,
    required this.database,
    required this.queueService,
    this.driveService,
    this.supabaseService,
  });

  @override
  State<PatientsScreen> createState() => _PatientsScreenState();
}

class _PatientsScreenState extends State<PatientsScreen> {
  final _searchController = TextEditingController();
  SearchFilterMode _selectedSearchMode = SearchFilterMode.all;
  List<Patient> _patients = [];
  int _unassignedSessionsCount = 0;
  int _activeUploadsCount = 0;
  int _failedUploadsCount = 0;
  bool _isLoadingCache = true;
  bool _isSyncing = false;
  String? _syncStatusMessage;
  bool _isOffline = false;
  bool _isOpeningCamera = false;
  late final PatientFolderService _patientFolderService = PatientFolderService(
    driveService: widget.driveService ?? DriveService(),
    sheetsService: widget.sheetsService,
    authService: widget.authService,
    configService: widget.configService,
    database: widget.database,
    supabaseService: widget.supabaseService,
  );
  late final PatientSyncService _patientSyncService = PatientSyncService(
    database: widget.database,
    supabaseService: widget.supabaseService,
    sheetsService: widget.sheetsService,
  );

  @override
  void initState() {
    super.initState();
    widget.queueService.addListener(_onQueueUpdated);
    _loadCachedPatients();
    _updateQueueStatus();
    _syncPatientDatabaseInBackground();
  }

  @override
  void dispose() {
    widget.queueService.removeListener(_onQueueUpdated);
    _searchController.dispose();
    super.dispose();
  }

  void _onQueueUpdated() {
    _updateQueueStatus();
  }

  Future<void> _updateQueueStatus() async {
    try {
      final status = await widget.queueService.getStatus();
      if (mounted) {
        setState(() {
          _activeUploadsCount = status.activeCount;
          _failedUploadsCount = status.failedCount;
        });
      }
    } catch (_) {}
  }

  /// Loads cached patients and unassigned sessions count immediately from SQLite.
  /// Preserves the active search query and filter mode if present.
  Future<void> _loadCachedPatients() async {
    final query = _searchController.text.trim();
    final cached = query.isNotEmpty
        ? await widget.database.searchPatients(query, mode: _selectedSearchMode)
        : await widget.database.getPatients();
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

  /// Fast background patient database sync (SQLite <-> Supabase).
  /// Normal patient-list sync should primarily be SQLite <-> Supabase.
  /// Does NOT query Google Sheets or Google Drive.
  Future<void> _syncPatientDatabaseInBackground() async {
    if (mounted) {
      setState(() {
        _isSyncing = true;
      });
    }

    try {
      await _patientSyncService.syncLocalWithSupabase();
      await _refreshAll();

      if (mounted) {
        final now = DateTime.now();
        final timeStr = DateFormat('h:mm a').format(now);
        setState(() {
          _isSyncing = false;
          _isOffline = false;
          _syncStatusMessage = '✓ Synced $timeStr';
        });
      }
    } catch (e) {
      debugPrint('Background database sync notice: $e');
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _isOffline = true;
          _syncStatusMessage = 'Offline · Showing cached list';
        });
      }
    }
  }

  /// Background sync with Google Sheet.
  /// If [forceFullSync] is true, or if no full sync has occurred, or if incremental sync fails:
  /// performs a complete reconciliation using validateAndFetchPatients + reconcileSheetPatients.
  /// Triggered only when explicitly requested (e.g. manual Refresh or after settings reconfiguration).
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
            await _patientSyncService.reconcileSheetPatients(incResult.updatedPatients);
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
          await _patientSyncService.reconcileSheetPatients(fullResult.patients);
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
        await _patientSyncService.reconcileSheetPatients(fullResult.patients);
        await widget.configService.updateLastSync(
          now,
          lastSyncedRow: fullResult.totalRows,
          isFullSync: true,
        );
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

  Future<void> _openPatientPhotos(Patient patient) async {
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PatientPhotosScreen(
          patient: patient,
          authService: widget.authService,
          driveService: widget.driveService ?? DriveService(),
          folderService: _patientFolderService,
          queueService: widget.queueService,
          patientSyncService: _patientSyncService,
        ),
      ),
    );
    if (deleted == true) {
      await _loadCachedPatients();
      await _refreshAll();
    }
  }

  Future<void> _handleTakePhotosForPatient(Patient patient) async {
    if (_isOpeningCamera) return;
    _isOpeningCamera = true;

    try {
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
              'Cannot capture photos for ${patient.displayName}.\n\n'
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
        try {
          final res = await _patientFolderService.getOrCreatePatientFolder(patient);
          if (res.patient.isUploadable) {
            targetPatient = res.patient;
            await widget.database.updatePatient(targetPatient);
            await _refreshAll();
          }
        } catch (e) {
          debugPrint('Drive folder setup deferred while offline: $e');
        }
      }

      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CameraScreen(
            patient: targetPatient,
            queueService: widget.queueService,
          ),
        ),
      );
    } finally {
      _isOpeningCamera = false;
    }

    if (mounted) {
      await _refreshAll();
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

  /// Starts Workflow B: creates a new unassigned session and opens camera immediately.
  Future<void> _startUnassignedSession() async {
    if (_isOpeningCamera) return;
    _isOpeningCamera = true;
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
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start unassigned capture: $e')),
        );
      }
    } finally {
      _isOpeningCamera = false;
    }

    if (mounted) {
      await _refreshAll();
    }
  }

  /// Displays the Unassigned Photos action menu allowing doctor to take unassigned photos or view inbox.
  void _showUnassignedMenu() {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.dividerColor.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(Icons.inbox_outlined, color: theme.colorScheme.primary, size: 24),
                  const SizedBox(width: 10),
                  Text(
                    'Unassigned Photos',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_unassignedSessionsCount > 0) ...[
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.error,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '$_unassignedSessionsCount',
                        style: TextStyle(
                          color: theme.colorScheme.onError,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Capture clinical photos for a new or unknown patient, or view sessions waiting to be assigned.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(Icons.camera_alt_outlined, color: theme.colorScheme.onPrimaryContainer),
                ),
                title: const Text('Take Unassigned Photos', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Launch camera immediately; assign to a patient later'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _startUnassignedSession();
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  child: Icon(Icons.inbox_outlined, color: theme.colorScheme.onSecondaryContainer),
                ),
                title: const Text('View Unassigned Photos', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  _unassignedSessionsCount > 0
                      ? '$_unassignedSessionsCount ${_unassignedSessionsCount == 1 ? "session" : "sessions"} waiting for assignment'
                      : 'No unassigned sessions pending',
                ),
                trailing: _unassignedSessionsCount > 0
                    ? const Icon(Icons.chevron_right)
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _openUnassignedPhotos();
                },
              ),
            ],
          ),
        ),
      ),
    );
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
          supabaseService: widget.supabaseService,
        ),
      ),
    )
        .then((_) {
      _loadCachedPatients();
      _syncSheetInBackground();
    });
  }

  bool _isQueryPhoneNumber(String query) {
    if (_selectedSearchMode == SearchFilterMode.phone) return true;
    if (_selectedSearchMode == SearchFilterMode.name) return false;
    final cleaned = query.replaceAll(RegExp(r'[\s\-()+]'), '');
    return cleaned.isNotEmpty && RegExp(r'^\d+$').hasMatch(cleaned);
  }

  Future<void> _openNewPatientDialog({String? initialQuery}) async {
    String? initialName;
    String? initialPhone;
    if (initialQuery != null && initialQuery.trim().isNotEmpty) {
      final trimmed = initialQuery.trim();
      if (_isQueryPhoneNumber(trimmed)) {
        initialPhone = trimmed;
      } else {
        initialName = trimmed;
      }
    }

    final patient = await NewPatientDialog.show(
      context,
      database: widget.database,
      supabaseService: widget.supabaseService,
      initialName: initialName,
      initialPhone: initialPhone,
    );
    if (patient != null && mounted) {
      await _loadCachedPatients();
      await _refreshAll();
      _handleTakePhotosForPatient(patient);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Patients', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'unassigned_photos_fab',
        onPressed: _showUnassignedMenu,
        tooltip: 'Unassigned photos',
        child: Badge(
          isLabelVisible: _unassignedSessionsCount > 0,
          label: Text(
            '$_unassignedSessionsCount',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
          ),
          offset: const Offset(6, -6),
          backgroundColor: theme.colorScheme.error,
          textColor: theme.colorScheme.onError,
          child: const Icon(Icons.inbox_outlined, size: 26),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
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
                '${_patients.length} ${_patients.length == 1 ? "patient" : "patients"}',
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
                    SearchFilterMode.all => 'Search patients by name or phone...',
                    SearchFilterMode.name => 'Search by patient name...',
                    SearchFilterMode.phone => 'Search by phone number...',
                    _ => 'Search patients...',
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
                  children: SearchFilterMode.values
                      .where((mode) => mode != SearchFilterMode.patientId)
                      .map((mode) {
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
                  ? (isDark ? Colors.amber.shade900.withValues(alpha: 0.3) : Colors.amber.shade50)
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
                      color: _isOffline
                          ? (isDark ? Colors.amber.shade300 : Colors.amber.shade900)
                          : Colors.green.shade600,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _syncStatusMessage ?? 'Ready',
                        style: TextStyle(
                          fontSize: 12,
                          color: _isOffline
                              ? (isDark ? Colors.amber.shade200 : Colors.amber.shade900)
                              : theme.colorScheme.onSurfaceVariant,
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

            // Real-time Upload Queue Progress Pill
            if (_activeUploadsCount > 0)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5) : theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Uploading $_activeUploadsCount ${_activeUploadsCount == 1 ? "photo" : "photos"} to Drive…',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),

            if (_failedUploadsCount > 0)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark ? theme.colorScheme.errorContainer.withValues(alpha: 0.5) : theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, size: 14, color: theme.colorScheme.onErrorContainer),
                    const SizedBox(width: 6),
                    Text(
                      '$_failedUploadsCount ${_failedUploadsCount == 1 ? "photo" : "photos"} failed (will retry)',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),

            // Patients List
            Expanded(
              child: _isLoadingCache
                  ? const Center(child: CircularProgressIndicator())
                  : _patients.isEmpty
                      ? Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(32, 32, 32, 88),
                            child: _searchController.text.trim().isNotEmpty
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.person_search_outlined,
                                        size: 48,
                                        color: theme.colorScheme.outline,
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        'No patients match "${_searchController.text.trim()}"',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: theme.colorScheme.onSurfaceVariant,
                                          fontSize: 15,
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                      FilledButton.icon(
                                        key: const Key('create_new_patient_button'),
                                        icon: const Icon(Icons.person_add_outlined),
                                        label: const Text('Create New Patient'),
                                        onPressed: () => _openNewPatientDialog(
                                          initialQuery: _searchController.text.trim(),
                                        ),
                                      ),
                                    ],
                                  )
                                : Text(
                                    'No patients found in sheet.\nTap Refresh to sync.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                                  ),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: () => _syncSheetInBackground(forceFullSync: true),
                          child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(0, 0, 0, 88),
                            itemCount: _patients.length,
                            itemBuilder: (context, index) {
                              final patient = _patients[index];
                              return PatientTile(
                                patient: patient,
                                onTap: () => _openPatientPhotos(patient),
                                onViewPhotos: () => _openPatientPhotos(patient),
                                onTakePhotos: () => _handleTakePhotosForPatient(patient),
                              );
                            },
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
