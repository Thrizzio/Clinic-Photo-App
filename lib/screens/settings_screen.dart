import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/clinic_config.dart';
import '../services/config_service.dart';
import '../services/database.dart';
import '../services/drive.dart';
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
  final DriveService? driveService;

  const SettingsScreen({
    super.key,
    required this.authService,
    required this.configService,
    required this.sheetsService,
    required this.database,
    required this.queueService,
    this.driveService,
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
      await widget.configService.updateLastSync(
        now,
        lastSyncedRow: result.totalRows,
        isFullSync: true,
      );

      setState(() {
        _config = widget.configService.loadConfig();
        _isSyncing = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ Full reconciliation: ${result.patients.length} patients from ${result.totalRows} rows'),
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
          driveService: widget.driveService,
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
    final theme = Theme.of(context);
    final email = widget.authService.currentAccount?.email ?? 'Connected';
    final currentThemeMode = widget.configService.getThemeMode();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        children: [
          // 1. Appearance Section
          _buildSectionHeader(
            theme,
            icon: Icons.palette_outlined,
            title: 'Appearance',
            subtitle: 'Theme and display settings',
          ),
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Theme',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Choose how the clinic photo app looks:',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment<ThemeMode>(
                          value: ThemeMode.system,
                          icon: Icon(Icons.brightness_auto_outlined),
                          label: Text('System'),
                          tooltip: 'Follow device appearance',
                        ),
                        ButtonSegment<ThemeMode>(
                          value: ThemeMode.light,
                          icon: Icon(Icons.light_mode_outlined),
                          label: Text('Light'),
                          tooltip: 'Always use light theme',
                        ),
                        ButtonSegment<ThemeMode>(
                          value: ThemeMode.dark,
                          icon: Icon(Icons.dark_mode_outlined),
                          label: Text('Dark'),
                          tooltip: 'Always use dark theme',
                        ),
                      ],
                      selected: {currentThemeMode},
                      onSelectionChanged: (Set<ThemeMode> selection) async {
                        final newMode = selection.first;
                        await widget.configService.setThemeMode(newMode);
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    switch (currentThemeMode) {
                      ThemeMode.system => '• System default: Follows your device theme automatically.',
                      ThemeMode.light => '• Light: Classic clinical light theme with crisp white background.',
                      ThemeMode.dark => '• Dark: Midnight slate clinical theme optimized for examination rooms.',
                    },
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 2. Clinic / Storage Section
          _buildSectionHeader(
            theme,
            icon: Icons.cloud_outlined,
            title: 'Clinic / Storage',
            subtitle: 'Google Drive photo storage location',
          ),
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.folder_shared_outlined, color: theme.colorScheme.primary),
                    title: Text(
                      'Parent Drive Folder',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    subtitle: Text(
                      _config.parentDriveFolderId.isNotEmpty
                          ? _config.parentDriveFolderId
                          : 'Not configured',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  const Divider(height: 16),
                  Text(
                    'Clinical photos are uploaded to patient folders ("Name - Phone") inside this folder, or to "_Unassigned Photos".',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 3. Data Section
          _buildSectionHeader(
            theme,
            icon: Icons.table_chart_outlined,
            title: 'Data',
            subtitle: 'Google Sheets read-only patient import',
          ),
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline, size: 16, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Google Sheets is a read-only import stream. New patients and photo folders are managed locally in the app and Google Drive.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  _buildDataRow(theme, 'Spreadsheet ID', _config.spreadsheetId),
                  const SizedBox(height: 10),
                  _buildDataRow(theme, 'Sheet Tab', _config.sheetTabName),
                  const SizedBox(height: 10),
                  _buildDataRow(theme, 'Last Synced', _formatLastSync(_config.lastPatientSync)),
                  const SizedBox(height: 10),
                  _buildDataRow(theme, 'Rows Processed', '${_config.lastSyncedRow} rows'),
                  const SizedBox(height: 10),
                  _buildDataRow(theme, 'Last Reconciliation', _formatLastSync(_config.lastFullSync)),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: _isSyncing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync),
                      label: const Text('Sync Now (Full Reconciliation)'),
                      onPressed: _isSyncing ? null : _handleSyncNow,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.edit_note),
                      label: const Text('Change Patient Database'),
                      onPressed: _handleChangeDatabase,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 4. Account Section
          _buildSectionHeader(
            theme,
            icon: Icons.account_circle_outlined,
            title: 'Account',
            subtitle: 'Connected Google account',
          ),
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: theme.colorScheme.primaryContainer,
                      child: Icon(Icons.person, color: theme.colorScheme.onPrimaryContainer),
                    ),
                    title: Text(
                      email,
                      style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      'Authorized for Google Sheets & Google Drive',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  const Divider(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: Icon(Icons.logout, color: theme.colorScheme.error),
                      label: Text(
                        'Sign Out',
                        style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.bold),
                      ),
                      onPressed: _handleSignOut,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildDataRow(ThemeData theme, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value.isNotEmpty ? value : '—',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 4.0, bottom: 8.0),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                  letterSpacing: 0.5,
                ),
              ),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
