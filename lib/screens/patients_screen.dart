import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/patient.dart';
import '../services/config_service.dart';
import '../services/database.dart';
import '../services/google_auth.dart';
import '../services/sheets.dart';
import '../services/upload_queue.dart';
import '../widgets/patient_tile.dart';
import '../widgets/upload_status.dart';
import 'camera_screen.dart';
import 'settings_screen.dart';
import 'unassigned_photos_screen.dart';

class PatientsScreen extends StatefulWidget {
  final GoogleAuthService authService;
  final ConfigService configService;
  final SheetsService sheetsService;
  final AppDatabase database;
  final UploadQueueService queueService;

  const PatientsScreen({
    super.key,
    required this.authService,
    required this.configService,
    required this.sheetsService,
    required this.database,
    required this.queueService,
  });

  @override
  State<PatientsScreen> createState() => _PatientsScreenState();
}

class _PatientsScreenState extends State<PatientsScreen> {
  final _searchController = TextEditingController();
  List<Patient> _patients = [];
  int _unassignedSessionsCount = 0;
  bool _isLoadingCache = true;
  bool _isSyncing = false;
  String? _syncStatusMessage;
  bool _isOffline = false;

  @override
  void initState() {
    super.initState();
    _loadCachedPatients();
    _syncSheetInBackground();
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
    final freshPatients = await widget.database.searchPatients(_searchController.text);
    final unassignedCount = await widget.database.getUnassignedSessionsCount();
    if (mounted) {
      setState(() {
        _patients = freshPatients;
        _unassignedSessionsCount = unassignedCount;
      });
    }
  }

  /// Background sync with Google Sheet.
  /// Uses incremental sync if lastSyncedRow > 1, or falls back to full sync.
  Future<void> _syncSheetInBackground() async {
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

      if (config.lastSyncedRow > 1) {
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
        // Full initial / fallback sync
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
    final filtered = await widget.database.searchPatients(query);
    if (mounted) {
      setState(() {
        _patients = filtered;
      });
    }
  }

  void _onPatientTapped(Patient patient) {
    if (!patient.isUploadable) {
      final isMissing = patient.folderStatus == FolderStatus.missing;
      final title = isMissing ? 'Missing Drive Folder' : 'Conflicting Drive Folders';
      final message = isMissing
          ? 'Cannot capture photos for ${patient.name} (${patient.id}).\n\nNo Google Drive folder URL is specified in the Visits sheet for this patient. Please add a valid Drive folder URL to the sheet and refresh.'
          : 'Cannot capture photos for ${patient.name} (${patient.id}).\n\nMultiple distinct Google Drive folders were found across visits for this patient. Please ensure only one consistent Drive folder is assigned in the Visits sheet and refresh.';

      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Row(
            children: [
              Icon(
                isMissing ? Icons.folder_off_outlined : Icons.warning_amber_rounded,
                color: isMissing ? Colors.amber.shade800 : Colors.red.shade700,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: const TextStyle(fontSize: 18))),
            ],
          ),
          content: Text(message),
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

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CameraScreen(
          patient: patient,
          queueService: widget.queueService,
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
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: TextField(
                controller: _searchController,
                onChanged: _handleSearch,
                decoration: InputDecoration(
                  hintText: 'Search patient ID or name...',
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
                      onTap: _syncSheetInBackground,
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
                          onRefresh: _syncSheetInBackground,
                          child: ListView.builder(
                            itemCount: _patients.length,
                            itemBuilder: (context, index) {
                              final patient = _patients[index];
                              return PatientTile(
                                patient: patient,
                                onTap: () => _onPatientTapped(patient),
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
