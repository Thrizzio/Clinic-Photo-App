import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import '../models/patient.dart';
import '../services/config_service.dart';
import '../services/database.dart';
import '../services/drive.dart';
import '../services/google_auth.dart';
import '../services/patient_folder_service.dart';
import '../services/sheets.dart';
import '../services/upload_queue.dart';
import '../widgets/patient_tile.dart';
import 'camera_screen.dart';
import 'patient_photos_screen.dart';
import 'settings_screen.dart';
import 'unassigned_photos_screen.dart';
import '../widgets/new_patient_dialog.dart';
import '../services/patient_sync_service.dart';
import '../services/supabase_patient_service.dart';
import '../services/sync_diagnostics.dart';

class PatientsScreen extends StatefulWidget {
  final GoogleAuthService authService;
  final ConfigService configService;
  final SheetsService sheetsService;
  final AppDatabase database;
  final UploadQueueService queueService;
  final DriveService? driveService;
  final SupabasePatientService? supabaseService;
  final Connectivity? connectivity;

  const PatientsScreen({
    super.key,
    required this.authService,
    required this.configService,
    required this.sheetsService,
    required this.database,
    required this.queueService,
    this.driveService,
    this.supabaseService,
    this.connectivity,
  });

  @override
  State<PatientsScreen> createState() => _PatientsScreenState();
}

class _PatientsScreenState extends State<PatientsScreen> with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  List<Patient> _patients = [];
  int _unassignedSessionsCount = 0;
  bool _isLoadingCache = true;
  bool _isDeviceDisconnected = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _isOpeningCamera = false;
  Future<void>? _activeSheetSyncFuture;
  late final PatientFolderService _patientFolderService =
      widget.queueService.patientFolderService ??
          PatientFolderService(
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

  void Function(Patient patient)? _previousOnFolderCreated;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Every app construction path must give the durable queue the same folder
    // resolver instance used by the patient UI.
    widget.queueService.setPatientFolderService(_patientFolderService);
    _previousOnFolderCreated = _patientFolderService.onFolderCreated;
    _patientFolderService.onFolderCreated = (patient) {
      _previousOnFolderCreated?.call(patient);
      if (mounted) {
        _loadCachedPatients();
      }
    };
    widget.queueService.addListener(_onQueueUpdated);
    _loadCachedPatients();
    _initConnectivityListener();
    // Background-first synchronization: SQLite loads immediately above;
    // remote reconciliation runs silently without blocking UI.
    unawaited(_syncPatientDatabaseInBackground());
    unawaited(_syncSheetInBackground(forceFullSync: false));
  }

  void _initConnectivityListener() {
    try {
      final effectiveConnectivity = widget.connectivity ?? widget.queueService.connectivity;
      effectiveConnectivity.checkConnectivity().then((results) {
        if (mounted) {
          final isDisconnected =
              results.contains(ConnectivityResult.none) && results.length == 1;
          setState(() {
            _isDeviceDisconnected = isDisconnected;
          });
        }
      });
      _connectivitySub = effectiveConnectivity.onConnectivityChanged.listen((results) {
        final isDisconnected =
            results.contains(ConnectivityResult.none) && results.length == 1;
        if (mounted) {
          setState(() {
            _isDeviceDisconnected = isDisconnected;
          });
        }
        if (!isDisconnected) {
          unawaited(widget.queueService.wake());
          unawaited(_syncPatientDatabaseInBackground());
          unawaited(_syncSheetInBackground(forceFullSync: false));
        }
      });
    } catch (_) {
      // In test environments, connectivity stream may not be available.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySub?.cancel();
    _patientFolderService.onFolderCreated = _previousOnFolderCreated;
    widget.queueService.removeListener(_onQueueUpdated);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.queueService.wake());
      unawaited(_syncPatientDatabaseInBackground());
      unawaited(_syncSheetInBackground(forceFullSync: false));
    }
  }

  void _onQueueUpdated() {
    _loadCachedPatients();
  }

  /// Loads cached patients and unassigned sessions count immediately from SQLite.
  /// Preserves the active search query if present.
  Future<void> _loadCachedPatients() async {
    final query = _searchController.text.trim();
    final cached = query.isNotEmpty
        ? await widget.database.searchPatients(query, mode: SearchFilterMode.all)
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
      mode: SearchFilterMode.all,
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
    if (_activeSheetSyncFuture != null) return;
    final trace = SyncDiagnostics.start(
      'patient_database_sync',
      trigger: 'patients_startup',
    );
    await SyncDiagnostics.run(trace, () async {
      try {
        // Supabase is supplementary cloud synchronization. A stale/expired
        // session or an unavailable DNS route must not keep the app in a
        // permanent "syncing" state while the SQLite patient cache is usable.
        final cloudSyncCompleted = await trace.stage(
          'supabase_reconciliation',
          () => _patientSyncService.syncLocalWithSupabase().timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw TimeoutException('Supabase patient sync timed out'),
          ),
        );
        if (cloudSyncCompleted) {
          await trace.stage('local_list_refresh', _refreshAll);
        } else {
          // The initial SQLite load already populated the visible list. When
          // cloud sync is skipped because there is no active session, another
          // identical SQLite query only adds contention with the upload queue.
          trace.addCount('localListRefreshSkipped');
        }

        trace.finish(
          outcome: cloudSyncCompleted ? 'success' : 'skipped',
          fields: <String, Object?>{
            'cloudSync': cloudSyncCompleted,
            'visiblePatientCount': _patients.length,
          },
        );
      } catch (e) {
        trace.finish(
          outcome: 'error',
          fields: <String, Object?>{'errorType': e.runtimeType.toString()},
        );
        debugPrint('Background database sync notice: $e');
      }
    });
  }

  /// Background sync with Google Sheet.
  ///
  /// Drive metadata is the cheap change detector. When the workbook has not
  /// changed, we leave the cached patient list alone. When it has changed (or
  /// the caller explicitly requests a refresh), we fetch and reconcile the
  /// complete master view. We deliberately do not infer row-level deltas from
  /// row numbers because sorting and inserted rows make that unsafe.
  Future<void> _syncSheetInBackground({bool forceFullSync = false}) {
    final active = _activeSheetSyncFuture;
    if (active != null) return active;

    final trace = SyncDiagnostics.start(
      'sheet_sync',
      trigger: forceFullSync ? 'manual_refresh' : 'background_refresh',
    );
    final future = SyncDiagnostics.run(
      trace,
      () => _syncSheetInBackgroundImpl(
        forceFullSync: forceFullSync,
        trace: trace,
      ),
    );
    _activeSheetSyncFuture = future;
    future.whenComplete(() {
      if (identical(_activeSheetSyncFuture, future)) {
        _activeSheetSyncFuture = null;
      }
    });
    return future;
  }

  Future<void> _syncSheetInBackgroundImpl({
    required bool forceFullSync,
    required SyncTrace trace,
  }) async {
    final config = widget.configService.loadConfig();
    if (!config.hasCompletedSetup || config.spreadsheetId.isEmpty) {
      trace.finish(
        outcome: 'skipped',
        fields: <String, Object?>{'reason': 'sheet_not_configured'},
      );
      return;
    }

    try {
      final client = await trace.stage(
        'google_auth',
        forceFullSync
            ? widget.authService.getAuthenticatedClient
            : widget.authService.getAuthenticatedClientSilently,
      );
      if (client == null) {
        trace.finish(
          outcome: 'skipped',
          fields: <String, Object?>{'reason': 'auth_unavailable'},
        );
        return;
      }

      final now = DateTime.now();
      final driveService = widget.driveService ?? DriveService();
      final fingerprint = await trace.stage(
        'drive_sheet_fingerprint',
        () => driveService.getFileChangeFingerprint(
          client: client,
          fileId: config.spreadsheetId,
        ),
      );
      var unchanged = false;
      if (!forceFullSync) {
        final sameModifiedTime = fingerprint.modifiedTime != null &&
            config.lastSheetModifiedTime != null &&
            fingerprint.modifiedTime == config.lastSheetModifiedTime;
        final sameVersion = fingerprint.version != null &&
            config.lastSheetVersion != null &&
            fingerprint.version == config.lastSheetVersion;
        unchanged = sameModifiedTime
            ? (config.lastSheetVersion == null || fingerprint.version == null || sameVersion)
            : (fingerprint.modifiedTime == null && sameVersion);
      }

      if (!unchanged) {
        var incrementalApplied = false;
        if (!forceFullSync && config.lastSyncedRow > 1) {
          trace.addCount('incrementalFetches');
          final incremental = await trace.stage(
            'sheets_incremental_fetch',
            () => widget.sheetsService.fetchIncrementalPatients(
              client: client,
              spreadsheetId: config.spreadsheetId,
              sheetName: config.sheetTabName,
              lastSyncedRow: config.lastSyncedRow,
            ),
          );

          // A non-empty tail is safe to reconcile incrementally. If the
          // workbook changed without adding rows, fall back to the complete
          // master view so edits/reordering cannot leave stale patients.
          if (incremental != null && incremental.newRowsCount > 0) {
            trace.addCount('rowsFetched', incremental.newRowsCount);
            await trace.stage(
              'sheet_reconciliation_incremental',
              () => _patientSyncService.reconcileSheetPatients(
                incremental.updatedPatients,
              ),
            );
            await trace.stage(
              'checkpoint_update_incremental',
              () => widget.configService.updateLastSync(
                now,
                lastSyncedRow: incremental.newLastSyncedRow,
                sheetModifiedTime: fingerprint.modifiedTime,
                sheetVersion: fingerprint.version,
              ),
            );
            incrementalApplied = true;
          }
        }

        if (!incrementalApplied) {
          trace.addCount('fullFetches');
          final fullResult = await trace.stage(
            'sheets_full_fetch',
            () => widget.sheetsService.validateAndFetchPatients(
              client: client,
              spreadsheetId: config.spreadsheetId,
              sheetName: config.sheetTabName,
            ),
          );
          trace.addCount('recordsFetched', fullResult.patients.length);
          debugPrint('FULL RECONCILIATION RESULT PATIENTS: ${fullResult.patients.length}');
          await trace.stage(
            'sheet_reconciliation_full',
            () => _patientSyncService.reconcileSheetPatients(fullResult.patients),
          );
          await trace.stage(
            'checkpoint_save_full',
            () => widget.configService.saveConfig(
              config.copyWith(
                sheetTabName: fullResult.effectiveSheetName ?? config.sheetTabName,
              ),
            ),
          );
          await trace.stage(
            'checkpoint_update_full',
            () => widget.configService.updateLastSync(
              now,
              lastSyncedRow: fullResult.totalRows,
              isFullSync: true,
              sheetModifiedTime: fingerprint.modifiedTime,
              sheetVersion: fingerprint.version,
              patientFingerprint: SheetsService.fingerprintPatients(fullResult.patients),
            ),
          );
        }
      } else {
        trace.addCount('noOpChecks');
      }

      await trace.stage('local_list_refresh', _refreshAll);

      trace.finish(
        outcome: 'success',
        fields: <String, Object?>{
          'branch': unchanged ? 'unchanged' : 'changed',
          'visiblePatientCount': _patients.length,
        },
      );
    } catch (e) {
      trace.finish(
        outcome: 'error',
        fields: <String, Object?>{'errorType': e.runtimeType.toString()},
      );
      debugPrint('Sheet sync notice: $e');
    }
  }

  Future<void> _handleSearch(String query) async {
    final filtered = await widget.database.searchPatients(
      query,
      mode: SearchFilterMode.all,
    );
    if (mounted) {
      setState(() {
        _patients = filtered;
      });
    }
  }

  Future<void> _openPatientPhotos(Patient patient) async {
    unawaited(widget.database.recordPatientViewed(patient.id));
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
    if (mounted) {
      await _loadCachedPatients();
      if (deleted == true) {
        await _refreshAll();
      }
    }
  }

  Future<void> _handleTakePhotosForPatient(Patient patient) async {
    if (_isOpeningCamera) return;
    _isOpeningCamera = true;
    unawaited(widget.database.recordPatientViewed(patient.id));

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

      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CameraScreen(
            patient: patient,
            queueService: widget.queueService,
          ),
        ),
      );
    } finally {
      _isOpeningCamera = false;
    }

    if (mounted) {
      await _loadCachedPatients();
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
               const SizedBox.shrink(),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Search Input
            Padding(
              padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 8.0),
              child: TextField(
                controller: _searchController,
                onChanged: _handleSearch,
                decoration: InputDecoration(
                  hintText: 'Search patients by name or phone...',
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

            // Offline Notice Banner (unobtrusive, genuine disconnect only)
            if (_isDeviceDisconnected)
              Container(
                key: const Key('offline_notice_banner'),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                color: isDark
                    ? Colors.amber.shade900.withValues(alpha: 0.25)
                    : Colors.amber.shade50,
                child: Row(
                  children: [
                    Icon(
                      Icons.wifi_off,
                      size: 14,
                      color: isDark ? Colors.amber.shade200 : Colors.amber.shade800,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Offline · Using local records',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.amber.shade200 : Colors.amber.shade900,
                          fontWeight: FontWeight.w500,
                        ),
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
                      ? RefreshIndicator(
                          onRefresh: () async {
                            widget.authService.resetRecoveryAttempt();
                            unawaited(_syncSheetInBackground(forceFullSync: true));
                            await Future.delayed(const Duration(milliseconds: 250));
                          },
                          child: SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(32, 32, 32, 88),
                            child: Center(
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
                                      'No patients found.\nSwipe down to refresh or check configuration in Settings.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                                    ),
                            ),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: () async {
                            widget.authService.resetRecoveryAttempt();
                            unawaited(_syncSheetInBackground(forceFullSync: true));
                            await Future.delayed(const Duration(milliseconds: 250));
                          },
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
