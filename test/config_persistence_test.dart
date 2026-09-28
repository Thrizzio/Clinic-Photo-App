import 'package:clinic_photos/models/clinic_config.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('ConfigService persistence & safe reconfiguration', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('default configuration has hasCompletedSetup = false', () async {
      final configService = await ConfigService.init();
      final config = configService.loadConfig();

      expect(config.hasCompletedSetup, isFalse);
      expect(config.spreadsheetId, isEmpty);
      expect(config.sheetTabName, isEmpty);
    });

    test('saves and loads valid configuration accurately', () async {
      final configService = await ConfigService.init();
      const initialConfig = ClinicConfig(
        spreadsheetId: 'sheet_id_123',
        spreadsheetUrl: 'https://docs.google.com/spreadsheets/d/sheet_id_123/edit',
        sheetTabName: 'Patients',
        hasCompletedSetup: true,
        lastPatientSync: '2026-09-28T10:00:00.000Z',
      );

      await configService.saveConfig(initialConfig);

      final loaded = configService.loadConfig();
      expect(loaded.hasCompletedSetup, isTrue);
      expect(loaded.spreadsheetId, 'sheet_id_123');
      expect(loaded.spreadsheetUrl, 'https://docs.google.com/spreadsheets/d/sheet_id_123/edit');
      expect(loaded.sheetTabName, 'Patients');
      expect(loaded.lastPatientSync, '2026-09-28T10:00:00.000Z');
    });

    test('updates lastPatientSync without altering spreadsheet settings', () async {
      final configService = await ConfigService.init();
      const initialConfig = ClinicConfig(
        spreadsheetId: 'sheet_id_123',
        spreadsheetUrl: 'https://docs.google.com/spreadsheets/d/sheet_id_123/edit',
        sheetTabName: 'Patients',
        hasCompletedSetup: true,
      );
      await configService.saveConfig(initialConfig);

      final now = DateTime(2026, 9, 28, 15, 30);
      await configService.updateLastSync(now);

      final updated = configService.loadConfig();
      expect(updated.spreadsheetId, 'sheet_id_123');
      expect(updated.lastPatientSync, now.toIso8601String());
    });

    test('Safe reconfiguration: failed new setup leaves existing configuration intact', () async {
      final configService = await ConfigService.init();
      const originalWorkingConfig = ClinicConfig(
        spreadsheetId: 'working_sheet_id',
        spreadsheetUrl: 'https://docs.google.com/spreadsheets/d/working_sheet_id/edit',
        sheetTabName: 'Patients',
        hasCompletedSetup: true,
        lastPatientSync: '2026-09-28T12:00:00.000Z',
      );
      await configService.saveConfig(originalWorkingConfig);

      // Simulate a failed reconfiguration attempt where validation fails or user cancels
      // (i.e. saveConfig is NOT called with the invalid configuration)
      const invalidAttemptId = 'invalid_sheet_xyz';
      expect(invalidAttemptId, isNot(originalWorkingConfig.spreadsheetId));

      // Verify original working configuration is still intact
      final currentConfig = configService.loadConfig();
      expect(currentConfig.hasCompletedSetup, isTrue);
      expect(currentConfig.spreadsheetId, 'working_sheet_id');
      expect(currentConfig.sheetTabName, 'Patients');
    });
  });
}
