import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/clinic_config.dart';

class ConfigService {
  static const String _keyHasCompletedSetup = 'hasCompletedSetup';
  static const String _keySpreadsheetId = 'spreadsheetId';
  static const String _keySpreadsheetUrl = 'spreadsheetUrl';
  static const String _keySheetTabName = 'sheetTabName';
  static const String _keyParentDriveFolderId = 'parentDriveFolderId';
  static const String _keyLastPatientSync = 'lastPatientSync';
  static const String _keyLastSyncedRow = 'lastSyncedRow';
  static const String _keyLastFullSync = 'lastFullSync';
  static const String _keyThemeMode = 'themeMode';

  final SharedPreferences _prefs;
  late final ValueNotifier<ThemeMode> themeModeNotifier;

  ConfigService(this._prefs) {
    themeModeNotifier = ValueNotifier<ThemeMode>(getThemeMode());
  }

  static Future<ConfigService> init() async {
    final prefs = await SharedPreferences.getInstance();
    return ConfigService(prefs);
  }

  ThemeMode getThemeMode() {
    final val = _prefs.getString(_keyThemeMode);
    switch (val) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await _prefs.setString(_keyThemeMode, mode.name);
    themeModeNotifier.value = mode;
  }

  ClinicConfig loadConfig() {
    return ClinicConfig(
      hasCompletedSetup: _prefs.getBool(_keyHasCompletedSetup) ?? false,
      spreadsheetId: _prefs.getString(_keySpreadsheetId) ?? '',
      spreadsheetUrl: _prefs.getString(_keySpreadsheetUrl) ?? '',
      sheetTabName: _prefs.getString(_keySheetTabName) ?? '',
      parentDriveFolderId: _prefs.getString(_keyParentDriveFolderId) ?? '',
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
    await _prefs.setString(_keyParentDriveFolderId, config.parentDriveFolderId);
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

  static const String _keyDoctorEmail = 'doctorEmail';
  static const String _keyDoctorPassword = 'doctorPassword';

  String? getDoctorEmail() => _prefs.getString(_keyDoctorEmail);
  Future<void> setDoctorEmail(String email) => _prefs.setString(_keyDoctorEmail, email);

  String? getDoctorPassword() => _prefs.getString(_keyDoctorPassword);
  Future<void> setDoctorPassword(String password) => _prefs.setString(_keyDoctorPassword, password);

  Future<void> clearConfig() async {
    await _prefs.remove(_keyHasCompletedSetup);
    await _prefs.remove(_keySpreadsheetId);
    await _prefs.remove(_keySpreadsheetUrl);
    await _prefs.remove(_keySheetTabName);
    await _prefs.remove(_keyParentDriveFolderId);
    await _prefs.remove(_keyLastPatientSync);
    await _prefs.remove(_keyLastSyncedRow);
    await _prefs.remove(_keyLastFullSync);
    await _prefs.remove(_keyDoctorEmail);
    await _prefs.remove(_keyDoctorPassword);
  }
}
