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

    // 1. Pre-fetch cloud and local datasets once to avoid N+1 queries
    List<Patient> cloudPatients = const [];
    List<Map<String, String>> cloudSources = const [];
    try {
      cloudPatients = await supabaseService.fetchAllPatients();
      cloudSources = await supabaseService.fetchAllPatientSources();
    } catch (e) {
      lastSupabaseError = formatSupabaseError(e);
      debugPrint('Warning: unable to fetch from Supabase during sheet reconciliation: $lastSupabaseError');
    }

    final localPatients = await database.getPatients();
    final localSources = await database.getAllPatientSources();
    final deletedTombstones = await database.getAllDeletedTombstoneSources();

    // 2. Build in-memory indexes
    final cloudById = {for (final p in cloudPatients) p.id: p};
    final localById = {for (final p in localPatients) p.id: p};

    final sourceToPatientId = <String, String>{};
    for (final s in cloudSources) {
      final src = s['source'];
      final ext = s['external_id'];
      final pId = s['patient_id'];
      if (src != null && ext != null && pId != null) {
        sourceToPatientId['$src:$ext'] = pId;
      }
    }
    for (final s in localSources) {
      final src = s['source'];
      final ext = s['external_id'];
      final pId = s['patient_id'];
      if (src != null && ext != null && pId != null) {
        sourceToPatientId.putIfAbsent('$src:$ext', () => pId);
      }
    }

    final businessIdToPatient = <String, Patient>{};
    for (final p in cloudPatients) {
      if (p.normalizedPhone != null && p.normalizedPhone!.isNotEmpty) {
        businessIdToPatient['${p.normalizedName}:${p.normalizedPhone}'] = p;
      }
    }
    for (final p in localPatients) {
      if (p.normalizedPhone != null && p.normalizedPhone!.isNotEmpty) {
        businessIdToPatient.putIfAbsent('${p.normalizedName}:${p.normalizedPhone}', () => p);
      }
    }

    final List<Patient> patientsToUpsert = [];
    final List<({String patientId, String source, String externalId})> sourcesToLink = [];
    final List<({String oldId, String newId})> idUpdates = [];

    // 3. Process sheet patients entirely in memory
    for (final incoming in sheetPatients) {
      // Skip rows with no usable patient name - do not create "Name unavailable" patients
      if (!incoming.hasValidName || incoming.displayName == 'Name unavailable') {
        continue;
      }

      final sheetPatientId = (incoming.legacyPatientId != null && incoming.legacyPatientId!.isNotEmpty)
          ? incoming.legacyPatientId!
          : incoming.id;

      // Skip deliberately deleted patients (tombstones) to prevent accidental resurrection loop
      if (deletedTombstones.contains('google_sheets:$sheetPatientId')) {
        continue;
      }

      final normName = incoming.normalizedName;
      final normPhone = incoming.normalizedPhone;

      // 1. Check if external Sheet ID is already mapped to a canonical patient UUID
      String? canonicalUuid = sourceToPatientId['google_sheets:$sheetPatientId'];
      Patient? existingPatient;

      if (canonicalUuid != null && Patient.isValidUuid(canonicalUuid)) {
        existingPatient = cloudById[canonicalUuid] ?? localById[canonicalUuid];
      }

      // 2. If not mapped by external ID, search by business identity: (normalized_name, normalized_phone)
      if (existingPatient == null && normPhone != null && normPhone.isNotEmpty) {
        existingPatient = businessIdToPatient['$normName:$normPhone'];
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

        patientsToUpsert.add(merged);
        sourcesToLink.add((
          patientId: effectiveUuid,
          source: 'google_sheets',
          externalId: sheetPatientId,
        ));
        reconciled.add(merged);

        if (existingPatient.id != effectiveUuid) {
          idUpdates.add((oldId: existingPatient.id, newId: effectiveUuid));
        }

        // Update in-memory indexes
        cloudById[effectiveUuid] = merged;
        localById[effectiveUuid] = merged;
        sourceToPatientId['google_sheets:$sheetPatientId'] = effectiveUuid;
        if (normPhone != null && normPhone.isNotEmpty) {
          businessIdToPatient['$normName:$normPhone'] = merged;
        }
      } else {
        // GENUINELY NEW PATIENT: Assign fresh canonical UUID
        createdCount++;
        final newUuid = uuidGen.v4();
        final newCanonical = incoming.copyWith(
          id: newUuid,
          legacyPatientId: sheetPatientId,
          source: PatientSource.clinicSheet,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        patientsToUpsert.add(newCanonical);
        sourcesToLink.add((
          patientId: newUuid,
          source: 'google_sheets',
          externalId: sheetPatientId,
        ));
        reconciled.add(newCanonical);

        // Update in-memory indexes
        cloudById[newUuid] = newCanonical;
        localById[newUuid] = newCanonical;
        sourceToPatientId['google_sheets:$sheetPatientId'] = newUuid;
        if (normPhone != null && normPhone.isNotEmpty) {
          businessIdToPatient['$normName:$normPhone'] = newCanonical;
        }
      }
    }

    // 4. Batch persist to Supabase
    bool supabaseSuccess = false;
    try {
      if (patientsToUpsert.isNotEmpty) {
        await supabaseService.upsertPatients(patientsToUpsert);
      }
      if (sourcesToLink.isNotEmpty) {
        await supabaseService.linkPatientSources(sourcesToLink);
      }
      supabaseSuccess = true;
    } catch (e) {
      lastSupabaseError = formatSupabaseError(e);
      debugPrint('Warning: unable to batch sync reconciled patients to Supabase: $lastSupabaseError');
    }

    // 5. Batch persist to SQLite
    final syncStatus = supabaseSuccess ? 'synced' : 'pending_cloud';
    final localPatientsToSave = patientsToUpsert.map((p) => p.copyWith(syncStatus: syncStatus)).toList();
    if (localPatientsToSave.isNotEmpty) {
      for (final update in idUpdates) {
        await database.updatePatientId(oldId: update.oldId, newId: update.newId);
      }
      await database.upsertPatients(localPatientsToSave);
      await database.linkPatientSources(sourcesToLink);
    }

    final cloudCount = cloudById.length;
    final isSynced = (lastSupabaseError == null) && (cloudCount > 0 || reconciled.isEmpty);

    return ReconciliationResult(
      totalSheetPatients: sheetPatients.length,
      linkedExistingCount: linkedCount,
      createdNewCount: createdCount,
      reconciledPatients: localPatientsToSave,
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

    // 1. Fetch canonical cloud patients and source mappings once
    List<Patient> cloudPatients = const [];
    List<Map<String, String>> cloudSources = const [];
    try {
      cloudPatients = await supabaseService.fetchAllPatients();
      cloudSources = await supabaseService.fetchAllPatientSources();
    } catch (e) {
      debugPrint('Supabase fetchAllPatients notice: $e');
      rethrow;
    }

    final localPatients = await database.getPatients();
    final cloudById = {for (final p in cloudPatients) p.id: p};
    final cloudByBusinessId = <String, Patient>{};
    for (final p in cloudPatients) {
      if (p.normalizedPhone != null && p.normalizedPhone!.isNotEmpty) {
        cloudByBusinessId['${p.normalizedName}:${p.normalizedPhone}'] = p;
      }
    }

    final cloudSourceToPatientId = <String, String>{};
    for (final s in cloudSources) {
      final src = s['source'];
      final ext = s['external_id'];
      final pId = s['patient_id'];
      if (src != null && ext != null && pId != null) {
        cloudSourceToPatientId['$src:$ext'] = pId;
      }
    }

    // 2. Cross-device deletion propagation:
    // When Supabase has active patients (cloudPatients.isNotEmpty), any local patient
    // that was previously 'synced' but is now absent from cloudPatients was deleted
    // from Supabase by another device.
    if (cloudPatients.isNotEmpty) {
      for (final local in localPatients) {
        if (local.syncStatus == 'synced' && !cloudById.containsKey(local.id)) {
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

    // 3. Push any local patients pending cloud push
    final currentLocalPatients = await database.getPatients();
    final List<Patient> toPush;
    if (cloudPatients.isEmpty && currentLocalPatients.isNotEmpty) {
      toPush = currentLocalPatients.where((p) => Patient.isValidUuid(p.id) && p.hasValidName).toList();
    } else {
      toPush = currentLocalPatients.where((p) => p.syncStatus == 'pending_cloud' && Patient.isValidUuid(p.id)).toList();
    }

    if (toPush.isNotEmpty) {
      final List<Patient> patientsToUpsert = [];
      final List<({String patientId, String source, String externalId})> sourcesToLink = [];
      final List<({String oldId, String newId})> idUpdates = [];
      final List<Patient> localPatientsToUpdate = [];

      for (final patient in toPush) {
        Patient? cloudMatch;
        // In-memory lookup by external source ID
        if (patient.legacyPatientId != null && patient.legacyPatientId!.isNotEmpty) {
          final cloudUuid = cloudSourceToPatientId['google_sheets:${patient.legacyPatientId}'];
          if (cloudUuid != null && Patient.isValidUuid(cloudUuid)) {
            cloudMatch = cloudById[cloudUuid];
          }
        }

        // In-memory lookup by business identity
        if (cloudMatch == null && patient.normalizedPhone != null && patient.normalizedPhone!.isNotEmpty) {
          cloudMatch = cloudByBusinessId['${patient.normalizedName}:${patient.normalizedPhone}'];
        }

        if (cloudMatch != null) {
          // Merge with cloud record:
          // Rule: cloud drive_folder_id is preserved if local is null/empty.
          // If local has drive_folder_id and cloud doesn't, local is used.
          final merged = Patient.merge(
            cloudMatch,
            patient.copyWith(id: cloudMatch.id),
          ).copyWith(
            id: cloudMatch.id,
            syncStatus: 'synced',
          );

          patientsToUpsert.add(merged);
          cloudById[cloudMatch.id] = merged;

          if (patient.legacyPatientId != null && patient.legacyPatientId!.isNotEmpty) {
            sourcesToLink.add((
              patientId: cloudMatch.id,
              source: 'google_sheets',
              externalId: patient.legacyPatientId!,
            ));
          }

          if (patient.id != cloudMatch.id) {
            idUpdates.add((oldId: patient.id, newId: cloudMatch.id));
          }
          localPatientsToUpdate.add(merged);
        } else {
          final synced = patient.copyWith(syncStatus: 'synced');
          patientsToUpsert.add(synced);
          cloudById[patient.id] = synced;

          if (patient.legacyPatientId != null && patient.legacyPatientId!.isNotEmpty) {
            sourcesToLink.add((
              patientId: patient.id,
              source: 'google_sheets',
              externalId: patient.legacyPatientId!,
            ));
          }
          localPatientsToUpdate.add(synced);
        }
      }

      // Batch persist to Supabase
      try {
        await supabaseService.upsertPatients(patientsToUpsert);
        if (sourcesToLink.isNotEmpty) {
          await supabaseService.linkPatientSources(sourcesToLink);
        }
        for (final update in idUpdates) {
          await database.updatePatientId(oldId: update.oldId, newId: update.newId);
        }
        for (final p in localPatientsToUpdate) {
          await database.updatePatient(p);
        }
      } catch (e) {
        final lastPushError = formatSupabaseError(e);
        debugPrint('Failed to batch push patients to Supabase: $lastPushError');
        throw Exception(lastPushError);
      }
    }

    // 4. Cache canonical cloud patients in SQLite (using in-memory updated map)
    if (cloudById.isNotEmpty) {
      await database.upsertPatients(cloudById.values.toList());
    }
  }
}
