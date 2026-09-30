import 'package:flutter/foundation.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import '../models/patient.dart';
import 'config_service.dart';
import 'database.dart';
import 'drive.dart';
import 'google_auth.dart';
import 'sheets.dart';

class ConflictFolderException implements Exception {
  final String message;
  ConflictFolderException(this.message);

  @override
  String toString() => message;
}

class PatientFolderResult {
  final Patient patient;
  final String driveFolderId;
  final bool createdNew;

  const PatientFolderResult({
    required this.patient,
    required this.driveFolderId,
    this.createdNew = false,
  });
}

/// Owns client-side patient Google Drive folder creation and Sheet link writing (No Apps Script).
class PatientFolderService {
  final DriveService driveService;
  final SheetsService sheetsService;
  final AppDatabase database;
  final ConfigService configService;
  final GoogleAuthService authService;

  PatientFolderService({
    required this.driveService,
    required this.sheetsService,
    required this.database,
    required this.configService,
    required this.authService,
  });

  /// Deterministically gets or creates a patient's Drive folder under the configured parent.
  ///
  /// Implements the 9-step idempotent resolution specified in Section 6:
  /// 1. Use valid cached driveFolderId if available.
  /// 2. Otherwise use a valid existing Photos (Drive) folder link.
  /// 3. Otherwise search the configured parent for exact expected name (`<Patient ID> - <Patient Name>`).
  /// 4. One match -> reuse.
  /// 5. Zero matches -> create.
  /// 6. Persist folder ID locally in SQLite.
  /// 7. Write folder URL to blank Visits rows for that Patient ID.
  /// 8. Mark available.
  /// 9. On failure preserve recoverable state; never pretend success.
  Future<PatientFolderResult> getOrCreatePatientFolder(
    Patient patient, {
    AuthClient? clientOverride,
  }) async {
    // 1. Use valid cached driveFolderId if available
    if (patient.folderStatus == FolderStatus.available &&
        patient.driveFolderId != null &&
        patient.driveFolderId!.isNotEmpty) {
      return PatientFolderResult(
        patient: patient,
        driveFolderId: patient.driveFolderId!,
        createdNew: false,
      );
    }

    if (patient.folderStatus == FolderStatus.conflict) {
      throw ConflictFolderException(
        'Patient ${patient.id} has conflicting Drive folders across visits. Resolve in Visits sheet first.',
      );
    }

    // 2. Check if a valid folder ID is already set on the patient model
    if (patient.driveFolderId != null && patient.driveFolderId!.isNotEmpty) {
      final updatedPatient = patient.copyWith(
        folderStatus: FolderStatus.available,
        updatedAt: DateTime.now(),
      );
      await database.updatePatient(updatedPatient);
      return PatientFolderResult(
        patient: updatedPatient,
        driveFolderId: patient.driveFolderId!,
        createdNew: false,
      );
    }

    final client = clientOverride ?? await authService.getAuthenticatedClient();
    if (client == null) {
      throw StateError('Google account not authorized. Please sign in to create folders.');
    }

    final config = configService.loadConfig();
    final parentFolderId = config.parentDriveFolderId.trim();
    if (parentFolderId.isEmpty) {
      throw StateError(
        'Parent Google Drive folder is not configured. Please set the Parent Drive Folder in Settings or Clinic Setup.',
      );
    }

    final folderSuffix = patient.hasValidName
        ? patient.name.trim()
        : (patient.name.trim().isNotEmpty ? patient.name.trim() : patient.id);
    final expectedFolderName = '${patient.id} - $folderSuffix';
    debugPrint('Resolving patient folder for "$expectedFolderName" under parent: $parentFolderId');

    // 3. Search the configured parent for exact expected name
    final matches = await driveService.findFoldersByName(
      client: client,
      parentFolderId: parentFolderId,
      folderName: expectedFolderName,
    );

    String resolvedFolderId;
    bool createdNew = false;

    if (matches.length > 1) {
      // 4. Multiple exact matches are a conflict. Never guess.
      final conflictPatient = patient.copyWith(
        folderStatus: FolderStatus.conflict,
        driveFolderId: null,
        updatedAt: DateTime.now(),
      );
      await database.updatePatient(conflictPatient);
      throw ConflictFolderException(
        'Multiple Drive folders (${matches.length}) found with name "$expectedFolderName" under parent. Please resolve in Google Drive.',
      );
    } else if (matches.length == 1) {
      // 4. One match -> reuse
      resolvedFolderId = matches.first.id!;
      debugPrint('Found existing matching Drive folder for $expectedFolderName: $resolvedFolderId');
    } else {
      // 5. Zero matches -> create
      resolvedFolderId = await driveService.createFolder(
        client: client,
        parentFolderId: parentFolderId,
        folderName: expectedFolderName,
      );
      createdNew = true;
      debugPrint('Created new Drive folder for $expectedFolderName: $resolvedFolderId');
    }

    // 6. Persist folder ID locally
    final availablePatient = patient.copyWith(
      driveFolderId: resolvedFolderId,
      folderStatus: FolderStatus.available,
      updatedAt: DateTime.now(),
    );
    await database.updatePatient(availablePatient);

    // 7. Write folder URL to blank Visits rows for that Patient ID
    if (config.spreadsheetId.isNotEmpty && config.sheetTabName.isNotEmpty) {
      final folderUrl = 'https://drive.google.com/drive/folders/$resolvedFolderId';
      try {
        await sheetsService.writePatientFolderUrl(
          client: client,
          spreadsheetId: config.spreadsheetId,
          sheetName: config.sheetTabName,
          patientId: patient.id,
          folderUrl: folderUrl,
        );
      } catch (e) {
        debugPrint('Warning: Could not write folder URL to Visits sheet: $e');
        // Folder exists and is persisted locally, so app remains recoverable.
      }
    }

    // 8. Mark available
    return PatientFolderResult(
      patient: availablePatient,
      driveFolderId: resolvedFolderId,
      createdNew: createdNew,
    );
  }
}
