import 'package:flutter/foundation.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:uuid/uuid.dart';
import '../models/patient.dart';
import 'database.dart';
import 'sheets.dart';
import 'supabase_patient_service.dart';

class ReconciliationResult {
  final int totalSheetPatients;
  final int linkedExistingCount;
  final int createdNewCount;
  final List<Patient> reconciledPatients;
  final bool isSupabaseSynced;
  final String? supabaseError;
  final int cloudPatientCount;

  const ReconciliationResult({
    required this.totalSheetPatients,
    required this.linkedExistingCount,
    required this.createdNewCount,
    required this.reconciledPatients,
    this.isSupabaseSynced = false,
    this.supabaseError,
    this.cloudPatientCount = 0,
  });
}

class DeletePatientResult {
  final bool localSuccess;
  final bool cloudSuccess;
  final String? cloudError;

  const DeletePatientResult({
    required this.localSuccess,
    required this.cloudSuccess,
    this.cloudError,
  });

  bool get isFullyDeleted => localSuccess && cloudSuccess;
  bool get cloudDeleted => cloudSuccess;
}

/// Orchestrates reconciliation of external Google Sheets clinic patients
/// into the canonical Supabase patient store and local SQLite cache.
///
/// CRITICAL INVARIANT:
/// Sheets is an external operational stream, NOT the authoritative master database.
/// Absence from Sheets NEVER deletes a canonical patient from Supabase or SQLite.
class PatientSyncService {
  final AppDatabase database;
  final SupabasePatientService supabaseService;
  final SheetsService sheetsService;

  PatientSyncService({
    required this.database,
    SupabasePatientService? supabaseService,
    required this.sheetsService,
  }) : supabaseService = supabaseService ?? InMemorySupabasePatientService();

  /// Formats raw Supabase errors into human-actionable diagnostic messages.
  static String formatSupabaseError(dynamic e) {
    final str = e.toString();
    if (str.contains('42501') ||
        str.contains('row-level security') ||
        str.contains('Unauthorized')) {
      return "Supabase Permission Error (42501): $str";
    }
    return str;
  }

  /// Reconciles parsed Google Sheets patients into Supabase and SQLite.
  ///
  /// Flow for each patient:
  /// 1. Look up existing canonical UUID by external source: `(google_sheets, externalId)`.
  /// 2. If not found, look up by business identity: `(normalized_name, normalized_phone)`.
  /// 3. If found:
  ///    - Preserve canonical UUID and existing Drive folder.
  ///    - Link source mapping in Supabase and SQLite.
  ///    - Merge non-conflicting information.
  /// 4. If not found:
  ///    - Generate a new canonical UUID.
  ///    - Insert into Supabase and SQLite.
  ///    - Link source mapping.
  /// 5. Patients in SQLite/Supabase absent from Sheets are completely untouched.
  Future<ReconciliationResult> reconcileSheetPatients(
    List<Patient> sheetPatients,
  ) async {
    int linkedCount = 0;
    int createdCount = 0;
    final reconciled = <Patient>[];
    const uuidGen = Uuid();
    String? lastSupabaseError;

    for (final incoming in sheetPatients) {
      // 0. Skip rows with no usable patient name - do not create "Name unavailable" patients
      if (!incoming.hasValidName || incoming.displayName == 'Name unavailable') {
        continue;
      }

      final sheetPatientId = (incoming.legacyPatientId != null && incoming.legacyPatientId!.isNotEmpty)
          ? incoming.legacyPatientId!
          : incoming.id;

      // 0b. Skip deliberately deleted patients (tombstones) to prevent accidental resurrection loop
      if (await database.isSourceDeleted(source: 'google_sheets', externalId: sheetPatientId)) {
        continue;
      }

      final normName = incoming.normalizedName;
      final normPhone = incoming.normalizedPhone;

      // 1. Check if this external Sheet ID is already mapped to a canonical patient UUID
      String? canonicalUuid = await supabaseService.getPatientIdBySource(
        source: 'google_sheets',
        externalId: sheetPatientId,
      );
      if (canonicalUuid == null || !Patient.isValidUuid(canonicalUuid)) {
        canonicalUuid = await database.getPatientIdBySource(
          source: 'google_sheets',
          externalId: sheetPatientId,
        );
      }

      Patient? existingPatient;
      if (canonicalUuid != null && Patient.isValidUuid(canonicalUuid)) {
        existingPatient = await supabaseService.getPatientById(canonicalUuid) ??
            await database.getPatient(canonicalUuid);
      }

      // 2. If not mapped by external ID, search by business identity: (normalized_name, normalized_phone)
      if (existingPatient == null && normPhone != null && normPhone.isNotEmpty) {
        existingPatient = await supabaseService.findPatientByBusinessIdentity(normName, normPhone) ??
            await database.getPatientByBusinessIdentity(normName, normPhone);
      }

      if (existingPatient != null) {
        // MATCH FOUND: Retain existing canonical UUID and Drive folder!
        linkedCount++;
        final effectiveUuid = Patient.isValidUuid(existingPatient.id)
            ? existingPatient.id
            : uuidGen.v4();

        final merged = Patient.merge(
          existingPatient,
          incoming.copyWith(
            id: effectiveUuid,
            legacyPatientId: sheetPatientId,
          ),
        ).copyWith(
          id: effectiveUuid,
          legacyPatientId: sheetPatientId,
        );

        // Update Supabase
        bool supabaseSuccess = false;
        try {
          await supabaseService.upsertPatient(merged);
          await supabaseService.linkPatientSource(
            patientId: effectiveUuid,
            source: 'google_sheets',
            externalId: sheetPatientId,
          );
          supabaseSuccess = true;
        } catch (e) {
          lastSupabaseError = formatSupabaseError(e);
          debugPrint('Warning: unable to sync reconciled patient to Supabase: $lastSupabaseError');
        }

        // Update SQLite (only mark synced if Supabase write succeeded)
        final localPatient = merged.copyWith(
          syncStatus: supabaseSuccess ? 'synced' : 'pending_cloud',
        );

        if (existingPatient.id != effectiveUuid) {
          await database.updatePatientId(oldId: existingPatient.id, newId: effectiveUuid);
        }
        await database.updatePatient(localPatient);
        await database.linkPatientSource(
          patientId: effectiveUuid,
          source: 'google_sheets',
          externalId: sheetPatientId,
        );

        reconciled.add(localPatient);
      } else {
        // GENUINELY NEW PATIENT: Assign fresh canonical UUID (never use Sheet ID as patients.id)
        createdCount++;
        final newUuid = uuidGen.v4();
        final newCanonical = incoming.copyWith(
          id: newUuid,
          legacyPatientId: sheetPatientId,
          source: PatientSource.clinicSheet,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        // Insert into Supabase
        bool supabaseSuccess = false;
        try {
          await supabaseService.upsertPatient(newCanonical);
          await supabaseService.linkPatientSource(
            patientId: newUuid,
            source: 'google_sheets',
            externalId: sheetPatientId,
          );
          supabaseSuccess = true;
        } catch (e) {
          lastSupabaseError = formatSupabaseError(e);
          debugPrint('Warning: unable to insert new patient to Supabase: $lastSupabaseError');
        }

        // Insert into SQLite (only mark synced if Supabase write succeeded)
        final localCanonical = newCanonical.copyWith(
          syncStatus: supabaseSuccess ? 'synced' : 'pending_cloud',
        );
        await database.upsertPatients([localCanonical]);
        await database.linkPatientSource(
          patientId: newUuid,
          source: 'google_sheets',
          externalId: sheetPatientId,
        );

        reconciled.add(localCanonical);
      }
    }

    // Verify Supabase persistence by querying back patients count
    int cloudCount = 0;
    try {
      final cloud = await supabaseService.fetchAllPatients();
      cloudCount = cloud.length;
    } catch (e) {
      lastSupabaseError ??= formatSupabaseError(e);
    }
    final isSynced = (lastSupabaseError == null) && (cloudCount > 0 || reconciled.isEmpty);

    return ReconciliationResult(
      totalSheetPatients: sheetPatients.length,
      linkedExistingCount: linkedCount,
      createdNewCount: createdCount,
      reconciledPatients: reconciled,
      isSupabaseSynced: isSynced,
      supabaseError: lastSupabaseError,
      cloudPatientCount: cloudCount,
    );
  }

  /// Fetches patients from Google Sheets and reconciles them into Supabase and SQLite.
  Future<ReconciliationResult> fetchAndReconcile({
    required AuthClient client,
    required String spreadsheetId,
    required String sheetName,
  }) async {
    final sheetResult = await sheetsService.validateAndFetchPatients(
      client: client,
      spreadsheetId: spreadsheetId,
      sheetName: sheetName,
    );

    return reconcileSheetPatients(sheetResult.patients);
  }

  /// Deletes a patient locally from SQLite and synchronizes the deletion to Supabase.
  /// If offline or if Supabase deletion fails, the deletion is persisted locally
  /// and queued in pending_deletions to retry when connectivity returns.
  /// Also records tombstones for all external source mappings to prevent Google Sheets
  /// from resurrecting the deleted patient.
  Future<DeletePatientResult> deletePatient(String patientId) async {
    final patient = await database.getPatient(patientId);
    final sources = await database.getSourcesForPatient(patientId);

    // 1. Record tombstones locally so Sheets reconciliation will never resurrect this patient
    for (final s in sources) {
      final src = s['source'];
      final ext = s['external_id'];
      if (src != null && ext != null) {
        await database.recordDeletedTombstone(
          patientId: patientId,
          source: src,
          externalId: ext,
        );
      }
    }
    if (patient?.legacyPatientId != null && patient!.legacyPatientId!.isNotEmpty) {
      await database.recordDeletedTombstone(
        patientId: patientId,
        source: 'google_sheets',
        externalId: patient.legacyPatientId!,
      );
    }
    await database.recordDeletedTombstone(
      patientId: patientId,
    );

    // 2. Record pending deletion in SQLite queue
    await database.addPendingDeletion(patientId);

    // 3. Delete locally from SQLite
    await database.deletePatient(patientId);

    // 4. Attempt to delete from Supabase
    bool cloudSuccess = false;
    String? cloudError;
    try {
      await supabaseService.deletePatient(patientId);
      cloudSuccess = true;
      await database.removePendingDeletion(patientId);
    } catch (e) {
      cloudError = formatSupabaseError(e);
      debugPrint('Supabase cloud delete deferred: $cloudError');
    }

    return DeletePatientResult(
      localSuccess: true,
      cloudSuccess: cloudSuccess,
      cloudError: cloudError,
    );
  }

  /// Synchronizes canonical patients between Supabase and local SQLite cache:
  /// 1. Retries any pending deletions from offline operations.
  /// 2. Pulls all canonical patients from Supabase and propagates cross-device deletions to SQLite.
  /// 3. Pushes any locally created/updated patients marked 'pending_cloud' to Supabase.
  /// 4. Caches all active canonical cloud patients in SQLite.
  Future<void> syncLocalWithSupabase() async {
    // 0. Retry any pending cloud deletions first
    final pendingDeletions = await database.getPendingDeletions();
    for (final pendingId in pendingDeletions) {
      try {
        await supabaseService.deletePatient(pendingId);
        await database.removePendingDeletion(pendingId);
      } catch (e) {
        debugPrint('Retry deletion of $pendingId deferred: $e');
      }
    }

    List<Patient> cloudPatients = const [];
    try {
      cloudPatients = await supabaseService.fetchAllPatients();
    } catch (e) {
      debugPrint('Supabase fetchAllPatients notice: $e');
      rethrow;
    }

    final localPatients = await database.getPatients();
    final cloudIds = cloudPatients.map((p) => p.id).toSet();

    // 1. Cross-device deletion propagation:
    // When Supabase has active patients (cloudPatients.isNotEmpty), any local patient
    // that was previously 'synced' but is now absent from cloudPatients was deleted
    // from Supabase by another device.
    if (cloudPatients.isNotEmpty) {
      for (final local in localPatients) {
        if (local.syncStatus == 'synced' && !cloudIds.contains(local.id)) {
          final sources = await database.getSourcesForPatient(local.id);
          for (final s in sources) {
            final src = s['source'];
            final ext = s['external_id'];
            if (src != null && ext != null) {
              await database.recordDeletedTombstone(
                patientId: local.id,
                source: src,
                externalId: ext,
              );
            }
          }
          if (local.legacyPatientId != null && local.legacyPatientId!.isNotEmpty) {
            await database.recordDeletedTombstone(
              patientId: local.id,
              source: 'google_sheets',
              externalId: local.legacyPatientId!,
            );
          }
          await database.recordDeletedTombstone(patientId: local.id);
          await database.deletePatient(local.id);
        }
      }
    }

    // 2. Push any local patients pending cloud push
    // If Supabase is empty but we have local patients (initial cloud migration / bootstrap),
    // treat all valid local patients as pending cloud push!
    final currentLocalPatients = await database.getPatients();
    final List<Patient> toPush;
    if (cloudPatients.isEmpty && currentLocalPatients.isNotEmpty) {
      toPush = currentLocalPatients.where((p) => Patient.isValidUuid(p.id) && p.hasValidName).toList();
    } else {
      toPush = currentLocalPatients.where((p) => p.syncStatus == 'pending_cloud' && Patient.isValidUuid(p.id)).toList();
    }

    String? lastPushError;
    for (final patient in toPush) {
      try {
        Patient? cloudMatch;
        if (patient.legacyPatientId != null && patient.legacyPatientId!.isNotEmpty) {
          final cloudUuid = await supabaseService.getPatientIdBySource(
            source: 'google_sheets',
            externalId: patient.legacyPatientId!,
          );
          if (cloudUuid != null && Patient.isValidUuid(cloudUuid)) {
            cloudMatch = await supabaseService.getPatientById(cloudUuid);
          }
        }

        if (cloudMatch == null && patient.normalizedPhone != null && patient.normalizedPhone!.isNotEmpty) {
          cloudMatch = await supabaseService.findPatientByBusinessIdentity(
            patient.normalizedName,
            patient.normalizedPhone!,
          );
        }

        if (cloudMatch != null) {
          final merged = Patient.merge(
            cloudMatch,
            patient.copyWith(id: cloudMatch.id),
          ).copyWith(
            id: cloudMatch.id,
            syncStatus: 'synced',
          );

          await supabaseService.upsertPatient(merged);
          if (patient.legacyPatientId != null && patient.legacyPatientId!.isNotEmpty) {
            await supabaseService.linkPatientSource(
              patientId: cloudMatch.id,
              source: 'google_sheets',
              externalId: patient.legacyPatientId!,
            );
          }

          if (patient.id != cloudMatch.id) {
            await database.updatePatientId(oldId: patient.id, newId: cloudMatch.id);
          }
          await database.updatePatient(merged);
        } else {
          await supabaseService.upsertPatient(patient);
          if (patient.legacyPatientId != null && patient.legacyPatientId!.isNotEmpty) {
            await supabaseService.linkPatientSource(
              patientId: patient.id,
              source: 'google_sheets',
              externalId: patient.legacyPatientId!,
            );
          }
          final synced = patient.copyWith(syncStatus: 'synced');
          await database.updatePatient(synced);
        }
      } catch (e) {
        lastPushError = formatSupabaseError(e);
        debugPrint('Failed to push patient ${patient.id} to Supabase: $lastPushError');
      }
    }

    if (lastPushError != null) {
      throw Exception(lastPushError);
    }

    // Pull canonical patients from Supabase to SQLite
    final updatedCloud = await supabaseService.fetchAllPatients();
    if (updatedCloud.isNotEmpty) {
      await database.upsertPatients(updatedCloud);
    }
  }
}
