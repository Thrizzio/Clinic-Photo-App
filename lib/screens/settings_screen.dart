import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/clinic_config.dart';
import '../services/config_service.dart';
import '../services/database.dart';
import '../services/google_auth.dart';
import '../services/sheets.dart';
import '../services/upload_queue.dart';
import 'clinic_setup_screen.dart';
import 'welcome_screen.dart';

class SettingsScreen extends StatefulWidget {
  final GoogleAuthService authService;
  final ConfigService configService;
  final SheetsService sheetsService;
  final AppDatabase database;
  final UploadQueueService queueService;

  const SettingsScreen({
    super.key,
    required this.authService,
    required this.configService,
    required this.sheetsService,
    required this.database,
    required this.queueService,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ClinicConfig _config;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _config = widget.configService.loadConfig();
  }

  String _formatLastSync(String? isoString) {
    if (isoString == null || isoString.isEmpty) return 'Never';
    try {
      final dt = DateTime.parse(isoString).toLocal();
      return DateFormat('MMM d, y · h:mm a').format(dt);
    } catch (_) {
      return isoString;
    }
  }

  Future<void> _handleSyncNow() async {
    setState(() {
      _isSyncing = true;
    });

    try {
      final client = await widget.authService.getAuthenticatedClient();
      if (client == null) {
        throw Exception('Google sign-in session expired.');
      }

      final result = await widget.sheetsService.validateAndFetchPatients(
        client: client,
        spreadsheetId: _config.spreadsheetId,
        sheetName: _config.sheetTabName,
      );

      await widget.database.replacePatients(result.patients);
      final now = DateTime.now();
      await widget.configService.updateLastSync(now);

      setState(() {
        _config = widget.configService.loadConfig();
        _isSyncing = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ Synced ${result.patients.length} patients'),
            backgroundColor: Colors.green.shade800,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isSyncing = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Couldn't sync: $e"),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }

  Future<void> _handleChangeDatabase() async {
    final updated = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ClinicSetupScreen(
          authService: widget.authService,
          configService: widget.configService,
          sheetsService: widget.sheetsService,
          database: widget.database,
          queueService: widget.queueService,
          isReconfiguration: true,
        ),
      ),
    );

    if (updated == true && mounted) {
      setState(() {
        _config = widget.configService.loadConfig();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✓ Patient database updated successfully')),
      );
    }
  }

  Future<void> _handleSignOut() async {
    await widget.authService.signOut();
    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => WelcomeScreen(
          authService: widget.authService,
          configService: widget.configService,
          sheetsService: widget.sheetsService,
          database: widget.database,
          queueService: widget.queueService,
        ),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.authService.currentAccount?.email ?? 'Connected';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildSectionHeader('Google Account'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text(email, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Authorized for Sheets & Drive'),
          ),
          const Divider(height: 32),

          _buildSectionHeader('Patient Database'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Spreadsheet ID', style: TextStyle(fontSize: 13, color: Colors.black54)),
            subtitle: Text(_config.spreadsheetId, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sheet Tab', style: TextStyle(fontSize: 13, color: Colors.black54)),
            subtitle: Text(_config.sheetTabName, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Last Synced', style: TextStyle(fontSize: 13, color: Colors.black54)),
            subtitle: Text(_formatLastSync(_config.lastPatientSync)),
          ),
          const SizedBox(height: 16),

          OutlinedButton.icon(
            icon: _isSyncing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            label: const Text('Sync Now'),
            onPressed: _isSyncing ? null : _handleSyncNow,
          ),
          const SizedBox(height: 8),

          OutlinedButton.icon(
            icon: const Icon(Icons.edit_note),
            label: const Text('Change Patient Database'),
            onPressed: _handleChangeDatabase,
          ),
          const Divider(height: 48),

          TextButton.icon(
            icon: const Icon(Icons.logout, color: Colors.red),
            label: const Text('Sign Out', style: TextStyle(color: Colors.red)),
            onPressed: _handleSignOut,
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Colors.black54,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
