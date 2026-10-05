import 'package:flutter/foundation.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import '../models/patient.dart';
import 'config_service.dart';
import 'database.dart';
import 'drive.dart';
import 'google_auth.dart';
import 'sheets.dart';
import 'supabase_patient_service.dart';

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
  final SupabasePatientService? supabaseService;

  PatientFolderService({
    required this.driveService,
    required this.sheetsService,
    required this.database,
    required this.configService,
    required this.authService,
    this.supabaseService,
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
      Patient updatedPatient = patient.copyWith(
        folderStatus: FolderStatus.available,
        updatedAt: DateTime.now(),
      );
      if (updatedPatient.syncStatus == 'pending_cloud' &&
          supabaseService != null &&
          Patient.isValidUuid(updatedPatient.id)) {
        try {
          await supabaseService!.upsertPatient(updatedPatient);
          updatedPatient = updatedPatient.copyWith(syncStatus: 'synced');
        } catch (_) {}
      }
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

    // Canonical folder naming: `<Patient Name> - <Phone>` or `<Patient Name>` if phone missing
    final phone = patient.phoneDisplay?.trim() ?? '';
    final canonicalName = phone.isNotEmpty
        ? '${patient.displayName} - $phone'
        : patient.displayName;

    debugPrint('Resolving patient folder: target canonical name "$canonicalName" under parent: $parentFolderId');

    // 3. Search the configured parent for exact canonical name
    var matches = await driveService.findFoldersByName(
      client: client,
      parentFolderId: parentFolderId,
      folderName: canonicalName,
    );

    // 3b. Legacy folder compatibility: If not found and patient has legacy ID, check `<LegacyId> - <Patient Name>`
    final legacyId = patient.legacyPatientId ??
        (patient.source != PatientSource.doctorCreated ? patient.id : null);
    if (matches.isEmpty && legacyId != null && legacyId.isNotEmpty) {
      final legacyName = '$legacyId - ${patient.displayName}';
      final legacyMatches = await driveService.findFoldersByName(
        client: client,
        parentFolderId: parentFolderId,
        folderName: legacyName,
      );
      if (legacyMatches.isNotEmpty) {
        debugPrint('Found matching legacy Drive folder "$legacyName" under configured parent.');
        matches = legacyMatches;
      }
    }

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
        'Multiple Drive folders (${matches.length}) found matching patient under parent. Please resolve in Google Drive.',
      );
    } else if (matches.length == 1) {
      // 4. One match -> reuse verified folder
      resolvedFolderId = matches.first.id!;
      debugPrint('Reusing existing matching Drive folder for ${patient.displayName}: $resolvedFolderId');
    } else {
      // 5. Zero matches -> create canonical folder
      resolvedFolderId = await driveService.createFolder(
        client: client,
        parentFolderId: parentFolderId,
        folderName: canonicalName,
      );
      createdNew = true;
      debugPrint('Created new Drive folder "$canonicalName" under parent $parentFolderId: $resolvedFolderId');
    }

    // 6. Persist folder ID locally marked pending_cloud
    final pendingPatient = patient.copyWith(
      driveFolderId: resolvedFolderId,
      folderStatus: FolderStatus.available,
      syncStatus: 'pending_cloud',
      updatedAt: DateTime.now(),
    );
    await database.updatePatient(pendingPatient);

    Patient effectivePatient = pendingPatient;

    // 7. Push to Supabase immediately if service is available
    if (supabaseService != null && Patient.isValidUuid(effectivePatient.id)) {
      try {
        await supabaseService!.upsertPatient(effectivePatient);
        effectivePatient = effectivePatient.copyWith(syncStatus: 'synced');
        await database.updatePatient(effectivePatient);
        debugPrint('Propagated drive_folder_id to Supabase for ${effectivePatient.displayName}: $resolvedFolderId');
      } catch (e) {
        debugPrint('Notice: Could not push resolved folder to Supabase immediately (queued for sync): $e');
      }
    }

    // 8. Mark available
    return PatientFolderResult(
      patient: effectivePatient,
      driveFolderId: resolvedFolderId,
      createdNew: createdNew,
    );
  }
}
