import 'package:flutter/material.dart';
import '../models/clinic_config.dart';
import '../models/patient.dart';
import '../services/config_service.dart';
import '../services/database.dart';
import '../services/google_auth.dart';
import '../services/sheets.dart';
import '../services/upload_queue.dart';
import 'patients_screen.dart';

class ClinicSetupScreen extends StatefulWidget {
  final GoogleAuthService authService;
  final ConfigService configService;
  final SheetsService sheetsService;
  final AppDatabase database;
  final UploadQueueService queueService;
  final bool isReconfiguration;

  const ClinicSetupScreen({
    super.key,
    required this.authService,
    required this.configService,
    required this.sheetsService,
    required this.database,
    required this.queueService,
    this.isReconfiguration = false,
  });

  @override
  State<ClinicSetupScreen> createState() => _ClinicSetupScreenState();
}

enum _SetupStep { enterUrl, selectTab, validateSummary }

class _ClinicSetupScreenState extends State<ClinicSetupScreen> {
  _SetupStep _currentStep = _SetupStep.enterUrl;
  final _urlController = TextEditingController();

  bool _isLoading = false;
  String? _errorMessage;

  String? _extractedSpreadsheetId;
  List<String> _availableTabs = [];
  String? _selectedTab;
  List<Patient> _validatedPatients = [];
  int _skippedRowCount = 0;

  @override
  void initState() {
    super.initState();
    if (widget.isReconfiguration) {
      final config = widget.configService.loadConfig();
      _urlController.text = config.spreadsheetUrl;
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
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
        _skippedRowCount = result.skippedRows;
        _currentStep = _SetupStep.validateSummary;
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

  Future<void> _handleFinishSetup() async {
    final spreadsheetId = _extractedSpreadsheetId;
    final tab = _selectedTab;
    if (spreadsheetId == null || tab == null) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 1. Replace local SQLite patient cache
      await widget.database.replacePatients(_validatedPatients);

      // 2. Persist configuration to SharedPreferences
      final now = DateTime.now();
      final newConfig = ClinicConfig(
        spreadsheetId: spreadsheetId,
        spreadsheetUrl: _urlController.text.trim(),
        sheetTabName: tab,
        hasCompletedSetup: true,
        lastPatientSync: now.toIso8601String(),
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
        const Text(
          'Paste your Google Sheet link to connect the clinic patient list.',
          style: TextStyle(color: Colors.black54, fontSize: 15),
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
        const Text(
          'Select the tab that contains your patient information.',
          style: TextStyle(color: Colors.black54, fontSize: 15),
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

  Widget _buildValidateSummaryStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Patient Database Ready',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 0,
          color: Colors.grey.shade100,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '${_validatedPatients.length} patients ready',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.folder, color: Colors.blue, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '${_validatedPatients.length} Drive folders verified',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ],
                ),
                if (_skippedRowCount > 0) ...[
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '$_skippedRowCount rows skipped (missing Drive Folder ID or incomplete)',
                          style: const TextStyle(color: Colors.black87, fontSize: 13),
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
        SizedBox(
          height: 50,
          child: FilledButton(
            onPressed: _isLoading ? null : _handleFinishSetup,
            child: _isLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Save & Start', style: TextStyle(fontSize: 16)),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Text(
        message,
        style: TextStyle(color: Colors.red.shade900, fontSize: 13),
      ),
    );
  }
}
