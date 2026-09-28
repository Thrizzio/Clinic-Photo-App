import 'package:shared_preferences/shared_preferences.dart';
import '../models/clinic_config.dart';

class ConfigService {
  static const String _keyHasCompletedSetup = 'hasCompletedSetup';
  static const String _keySpreadsheetId = 'spreadsheetId';
  static const String _keySpreadsheetUrl = 'spreadsheetUrl';
  static const String _keySheetTabName = 'sheetTabName';
  static const String _keyLastPatientSync = 'lastPatientSync';

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
    );
  }

  Future<void> saveConfig(ClinicConfig config) async {
    await _prefs.setBool(_keyHasCompletedSetup, config.hasCompletedSetup);
    await _prefs.setString(_keySpreadsheetId, config.spreadsheetId);
    await _prefs.setString(_keySpreadsheetUrl, config.spreadsheetUrl);
    await _prefs.setString(_keySheetTabName, config.sheetTabName);
    if (config.lastPatientSync != null) {
      await _prefs.setString(_keyLastPatientSync, config.lastPatientSync!);
    }
  }

  Future<void> updateLastSync(DateTime syncTime) async {
    await _prefs.setString(_keyLastPatientSync, syncTime.toIso8601String());
  }

  Future<void> clearConfig() async {
    await _prefs.remove(_keyHasCompletedSetup);
    await _prefs.remove(_keySpreadsheetId);
    await _prefs.remove(_keySpreadsheetUrl);
    await _prefs.remove(_keySheetTabName);
    await _prefs.remove(_keyLastPatientSync);
  }
}
