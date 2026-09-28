import 'package:shared_preferences/shared_preferences.dart';
import '../models/clinic_config.dart';

class ConfigService {
  static const String _keyHasCompletedSetup = 'hasCompletedSetup';
  static const String _keySpreadsheetId = 'spreadsheetId';
  static const String _keySpreadsheetUrl = 'spreadsheetUrl';
  static const String _keySheetTabName = 'sheetTabName';
  static const String _keyLastPatientSync = 'lastPatientSync';
  static const String _keyLastSyncedRow = 'lastSyncedRow';
  static const String _keyLastFullSync = 'lastFullSync';

  final SharedPreferences _prefs;

  ConfigService(this._prefs);

  static Future<ConfigService> init() async {
    final prefs = await SharedPreferences.getInstance();
    return ConfigService(prefs);
  }

  ClinicConfig loadConfig() {
    return ClinicConfig(
      hasCompletedSetup: _prefs.getBool(_keyHasCompletedSetup) ?? false,
      spreadsheetId: _prefs.getString(_keySpreadsheetId) ?? '',
      spreadsheetUrl: _prefs.getString(_keySpreadsheetUrl) ?? '',
      sheetTabName: _prefs.getString(_keySheetTabName) ?? '',
      lastPatientSync: _prefs.getString(_keyLastPatientSync),
      lastSyncedRow: _prefs.getInt(_keyLastSyncedRow) ?? 1,
      lastFullSync: _prefs.getString(_keyLastFullSync),
    );
  }

  Future<void> saveConfig(ClinicConfig config) async {
    await _prefs.setBool(_keyHasCompletedSetup, config.hasCompletedSetup);
    await _prefs.setString(_keySpreadsheetId, config.spreadsheetId);
    await _prefs.setString(_keySpreadsheetUrl, config.spreadsheetUrl);
    await _prefs.setString(_keySheetTabName, config.sheetTabName);
    await _prefs.setInt(_keyLastSyncedRow, config.lastSyncedRow);
    if (config.lastPatientSync != null) {
      await _prefs.setString(_keyLastPatientSync, config.lastPatientSync!);
    }
    if (config.lastFullSync != null) {
      await _prefs.setString(_keyLastFullSync, config.lastFullSync!);
    }
  }

  Future<void> updateLastSync(DateTime syncTime, {int? lastSyncedRow, bool isFullSync = false}) async {
    final iso = syncTime.toIso8601String();
    await _prefs.setString(_keyLastPatientSync, iso);
    if (lastSyncedRow != null) {
      await _prefs.setInt(_keyLastSyncedRow, lastSyncedRow);
    }
    if (isFullSync) {
      await _prefs.setString(_keyLastFullSync, iso);
    }
  }

  Future<void> clearConfig() async {
    await _prefs.remove(_keyHasCompletedSetup);
    await _prefs.remove(_keySpreadsheetId);
    await _prefs.remove(_keySpreadsheetUrl);
    await _prefs.remove(_keySheetTabName);
    await _prefs.remove(_keyLastPatientSync);
    await _prefs.remove(_keyLastSyncedRow);
    await _prefs.remove(_keyLastFullSync);
  }
}
