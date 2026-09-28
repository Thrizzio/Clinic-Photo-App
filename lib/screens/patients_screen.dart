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

  /// Loads cached patients from SQLite immediately on screen display.
  Future<void> _loadCachedPatients() async {
    final cached = await widget.database.getPatients();
    if (mounted) {
      setState(() {
        _patients = cached;
        _isLoadingCache = false;
      });
    }
  }

  /// Background sync with Google Sheet.
  /// Replaces cache if successful; displays offline message if network fails.
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

      final result = await widget.sheetsService.validateAndFetchPatients(
        client: client,
        spreadsheetId: config.spreadsheetId,
        sheetName: config.sheetTabName,
      );

      await widget.database.replacePatients(result.patients);
      final now = DateTime.now();
      await widget.configService.updateLastSync(now);

      final freshList = await widget.database.searchPatients(_searchController.text);

      if (mounted) {
        final timeStr = DateFormat('h:mm a').format(now);
        setState(() {
          _patients = freshList;
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
          _syncStatusMessage = 'Offline · Showing last synced list';
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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CameraScreen(
          patient: patient,
          queueService: widget.queueService,
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
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
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
                      : ListView.builder(
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
