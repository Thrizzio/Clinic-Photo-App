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
  /// Explicitly identifies RLS 42501 (Unauthorized: role mismatch).
  static String formatSupabaseError(dynamic e) {
    final str = e.toString();
    if (str.contains('42501') ||
        str.contains('row-level security') ||
        str.contains('Unauthorized')) {
      return "Supabase RLS Error (42501 Unauthorized): Row-Level Security policies on 'patients'/'patient_sources' require the 'authenticated' role, but the app connects with the 'anon' role without a Supabase Auth session.";
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

  /// Synchronizes canonical patients between Supabase and local SQLite cache:
  /// 1. Pushes any locally created/updated patients marked 'pending_cloud' to Supabase.
  ///    (If Supabase is completely empty, bootstraps all valid local patients to cloud).
  /// 2. Pulls all canonical patients from Supabase and caches them in SQLite.
  Future<void> syncLocalWithSupabase() async {
    List<Patient> cloudPatients = const [];
    try {
      cloudPatients = await supabaseService.fetchAllPatients();
    } catch (e) {
      debugPrint('Supabase fetchAllPatients notice: $e');
    }

    final localPatients = await database.getPatients();

    // If Supabase is empty but we have local patients (initial cloud migration / bootstrap),
    // treat all valid local patients as pending cloud push!
    final List<Patient> toPush;
    if (cloudPatients.isEmpty && localPatients.isNotEmpty) {
      toPush = localPatients.where((p) => Patient.isValidUuid(p.id) && p.hasValidName).toList();
    } else {
      toPush = localPatients.where((p) => p.syncStatus == 'pending_cloud' && Patient.isValidUuid(p.id)).toList();
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
