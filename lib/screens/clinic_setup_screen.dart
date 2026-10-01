import 'package:flutter/material.dart';
import '../models/clinic_config.dart';
import '../models/patient.dart';
import '../services/config_service.dart';
import '../services/database.dart';
import '../services/drive.dart';
import '../services/google_auth.dart';
import '../services/sheets.dart';
import '../services/upload_queue.dart';
import '../services/patient_sync_service.dart';
import '../services/supabase_patient_service.dart';
import 'patients_screen.dart';

class ClinicSetupScreen extends StatefulWidget {
  final GoogleAuthService authService;
  final ConfigService configService;
  final SheetsService sheetsService;
  final AppDatabase database;
  final UploadQueueService queueService;
  final DriveService? driveService;
  final SupabasePatientService? supabaseService;
  final bool isReconfiguration;

  const ClinicSetupScreen({
    super.key,
    required this.authService,
    required this.configService,
    required this.sheetsService,
    required this.database,
    required this.queueService,
    this.driveService,
    this.supabaseService,
    this.isReconfiguration = false,
  });

  @override
  State<ClinicSetupScreen> createState() => _ClinicSetupScreenState();
}

enum _SetupStep { enterUrl, selectTab, configureDriveFolder, validateSummary }

class _ClinicSetupScreenState extends State<ClinicSetupScreen> {
  _SetupStep _currentStep = _SetupStep.enterUrl;
  final _urlController = TextEditingController();
  final _driveFolderController = TextEditingController();
  late final DriveService _driveService = widget.driveService ?? DriveService();

  bool _isLoading = false;
  String? _errorMessage;

  String? _extractedSpreadsheetId;
  List<String> _availableTabs = [];
  String? _selectedTab;
  String? _parentDriveFolderId;
  List<Patient> _validatedPatients = [];
  int _totalRowCount = 0;

  @override
  void initState() {
    super.initState();
    if (widget.isReconfiguration) {
      final config = widget.configService.loadConfig();
      _urlController.text = config.spreadsheetUrl;
      _driveFolderController.text = config.parentDriveFolderId;
      if (config.parentDriveFolderId.isNotEmpty) {
        _parentDriveFolderId = config.parentDriveFolderId;
      }
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _driveFolderController.dispose();
    super.dispose();
  }

  Future<void> _handleUrlSubmitted() async {
    final input = _urlController.text.trim();
    final spreadsheetId = SheetsService.extractSpreadsheetId(input);

    if (spreadsheetId == null) {
      setState(() {
        _errorMessage = 'Please enter a valid Google Sheets URL.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _extractedSpreadsheetId = spreadsheetId;
    });

    try {
      final client = await widget.authService.getAuthenticatedClient();
      if (client == null) {
        throw Exception('Google authorization expired. Please sign in again.');
      }

      final tabs = await widget.sheetsService.fetchSheetTabs(
        client: client,
        spreadsheetId: spreadsheetId,
      );

      if (tabs.isEmpty) {
        throw Exception('No sheets found in this spreadsheet.');
      }

      setState(() {
        _availableTabs = tabs;
        _selectedTab = tabs.first;
        _currentStep = _SetupStep.selectTab;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage =
            "Couldn't access this spreadsheet.\nMake sure you signed in with the Google account that has access and the sheet exists.";
      });
    }
  }

  Future<void> _handleTabSelected() async {
    final tab = _selectedTab;
    final spreadsheetId = _extractedSpreadsheetId;
    if (tab == null || spreadsheetId == null) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final client = await widget.authService.getAuthenticatedClient();
      if (client == null) {
        throw Exception('Google authorization expired. Please sign in again.');
      }

      final result = await widget.sheetsService.validateAndFetchPatients(
        client: client,
        spreadsheetId: spreadsheetId,
        sheetName: tab,
      );

      if (result.patients.isEmpty && result.totalRows == 0) {
        throw Exception('The selected sheet is empty.');
      }

      setState(() {
        _validatedPatients = result.patients;
        _totalRowCount = result.totalRows;
        _currentStep = _SetupStep.configureDriveFolder;
        _isLoading = false;
      });
    } on MissingColumnException catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Validation failed: ${e.toString()}';
      });
    }
  }

  Future<void> _handleDriveFolderSubmitted() async {
    final input = _driveFolderController.text.trim();
    final folderId = SheetsService.extractDriveFolderId(input);

    if (folderId == null) {
      setState(() {
        _errorMessage = 'Please enter a valid Google Drive folder link or folder ID.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final client = await widget.authService.getAuthenticatedClient();
      if (client == null) {
        throw Exception('Google authorization expired. Please sign in again.');
      }

      final hasAccess = await _driveService.verifyFolderAccess(
        client: client,
        folderId: folderId,
      );

      if (!hasAccess) {
        throw Exception(
          'Cannot access this Drive folder. Please verify the folder exists and your account has permission to view and create files in it.',
        );
      }

      setState(() {
        _parentDriveFolderId = folderId;
        _currentStep = _SetupStep.validateSummary;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Drive folder verification failed: $e';
      });
    }
  }

  Future<void> _handleFinishSetup() async {
    final spreadsheetId = _extractedSpreadsheetId;
    final tab = _selectedTab;
    final parentFolderId = _parentDriveFolderId;
    if (spreadsheetId == null || tab == null || parentFolderId == null) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 1. Reconcile patients into Supabase and SQLite without deleting doctor-created patients
      final syncService = PatientSyncService(
        database: widget.database,
        supabaseService: widget.supabaseService,
        sheetsService: widget.sheetsService,
      );
      await syncService.reconcileSheetPatients(_validatedPatients);
      try {
        await syncService.syncLocalWithSupabase();
      } catch (e) {
        debugPrint('Offline/error during Supabase sync in setup: $e');
      }

      // 2. Persist configuration to SharedPreferences
      final now = DateTime.now();
      final newConfig = ClinicConfig(
        spreadsheetId: spreadsheetId,
        spreadsheetUrl: _urlController.text.trim(),
        sheetTabName: tab,
        parentDriveFolderId: parentFolderId,
        hasCompletedSetup: true,
        lastPatientSync: now.toIso8601String(),
        lastSyncedRow: _totalRowCount,
        lastFullSync: now.toIso8601String(),
      );
      await widget.configService.saveConfig(newConfig);

      if (!mounted) return;

      if (widget.isReconfiguration) {
        Navigator.of(context).pop(true);
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => PatientsScreen(
              authService: widget.authService,
              configService: widget.configService,
              sheetsService: widget.sheetsService,
              database: widget.database,
              queueService: widget.queueService,
              supabaseService: widget.supabaseService,
            ),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to save setup: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isReconfiguration ? 'Change Patient Database' : 'Clinic Setup'),
        leading: widget.isReconfiguration
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(false),
              )
            : null,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: switch (_currentStep) {
            _SetupStep.enterUrl => _buildEnterUrlStep(),
            _SetupStep.selectTab => _buildSelectTabStep(),
            _SetupStep.configureDriveFolder => _buildConfigureDriveFolderStep(),
            _SetupStep.validateSummary => _buildValidateSummaryStep(),
          },
        ),
      ),
    );
  }

  Widget _buildEnterUrlStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Patient Database',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Paste your Google Sheet link to connect the clinic patient list.',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 15),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _urlController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'https://docs.google.com/spreadsheets/d/...',
            labelText: 'Google Sheet Link',
            prefixIcon: Icon(Icons.link),
          ),
          keyboardType: TextInputType.url,
          autocorrect: false,
        ),
        const SizedBox(height: 16),
        if (_errorMessage != null) _buildErrorBanner(_errorMessage!),
        const Spacer(),
        SizedBox(
          height: 50,
          child: FilledButton(
            onPressed: _isLoading ? null : _handleUrlSubmitted,
            child: _isLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Continue', style: TextStyle(fontSize: 16)),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectTabStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Select Patient Sheet',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Select the tab that contains your patient information.',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 15),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: RadioGroup<String>(
            groupValue: _selectedTab,
            onChanged: (val) {
              setState(() {
                _selectedTab = val;
              });
            },
            child: ListView.builder(
              itemCount: _availableTabs.length,
              itemBuilder: (context, index) {
                final tab = _availableTabs[index];
                return RadioListTile<String>(
                  title: Text(tab, style: const TextStyle(fontWeight: FontWeight.w600)),
                  value: tab,
                );
              },
            ),
          ),
        ),
        if (_errorMessage != null) _buildErrorBanner(_errorMessage!),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  setState(() {
                    _currentStep = _SetupStep.enterUrl;
                    _errorMessage = null;
                  });
                },
                child: const Text('Back'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton(
                onPressed: _isLoading ? null : _handleTabSelected,
                child: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Continue'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildConfigureDriveFolderStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Parent Drive Folder',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Paste the Google Drive folder link where clinical photo folders will be organized.\n\nThe app will create a subfolder for each patient:\n"<Patient Name> - <Phone Number>"',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _driveFolderController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'https://drive.google.com/drive/folders/...',
            labelText: 'Google Drive Folder Link or ID',
            prefixIcon: Icon(Icons.folder_shared_outlined),
          ),
          keyboardType: TextInputType.url,
          autocorrect: false,
        ),
        const SizedBox(height: 16),
        if (_errorMessage != null) _buildErrorBanner(_errorMessage!),
        const Spacer(),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  setState(() {
                    _currentStep = _SetupStep.selectTab;
                    _errorMessage = null;
                  });
                },
                child: const Text('Back'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton(
                onPressed: _isLoading ? null : _handleDriveFolderSubmitted,
                child: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Continue'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildValidateSummaryStep() {
    final availableCount =
        _validatedPatients.where((p) => p.folderStatus == FolderStatus.available).length;
    final missingCount =
        _validatedPatients.where((p) => p.folderStatus == FolderStatus.missing).length;
    final conflictCount =
        _validatedPatients.where((p) => p.folderStatus == FolderStatus.conflict).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Clinic Setup Summary',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 0,
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.table_chart_outlined, color: Colors.indigo, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Sheet: $_selectedTab',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.people, color: Colors.blue, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '${_validatedPatients.length} unique patients ($_totalRowCount rows)',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.folder, color: Colors.teal, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Parent Drive Folder: ${_parentDriveFolderId ?? ""}',
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      '$availableCount existing folders linked',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
                if (missingCount > 0) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline, color: Colors.blueGrey, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '$missingCount unlinked patients: folders will be created automatically in your parent Drive folder upon photo capture.',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ],
                if (conflictCount > 0) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '$conflictCount patients have conflicting Drive folders across visits',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_errorMessage != null) _buildErrorBanner(_errorMessage!),
        const Spacer(),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  setState(() {
                    _currentStep = _SetupStep.configureDriveFolder;
                    _errorMessage = null;
                  });
                },
                child: const Text('Back'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton(
                onPressed: _isLoading ? null : _handleFinishSetup,
                child: _isLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Text(
                        widget.isReconfiguration ? 'Update Configuration' : 'Save & Start',
                        style: const TextStyle(fontSize: 16),
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildErrorBanner(String message) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.4)),
      ),
      child: Text(
        message,
        style: TextStyle(color: theme.colorScheme.onErrorContainer, fontSize: 13),
      ),
    );
  }
}
