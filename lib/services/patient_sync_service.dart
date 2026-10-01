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

  const ReconciliationResult({
    required this.totalSheetPatients,
    required this.linkedExistingCount,
    required this.createdNewCount,
    required this.reconciledPatients,
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

    for (final incoming in sheetPatients) {
      final externalId = incoming.legacyPatientId ?? incoming.id;
      final normName = incoming.normalizedName;
      final normPhone = incoming.normalizedPhone;

      // 1. Check if this external Sheet ID is already mapped to a canonical patient UUID
      String? canonicalId = await supabaseService.getPatientIdBySource(
        source: 'google_sheets',
        externalId: externalId,
      ) ?? await database.getPatientIdBySource(
        source: 'google_sheets',
        externalId: externalId,
      );

      Patient? existingPatient;
      if (canonicalId != null && canonicalId.isNotEmpty) {
        existingPatient = await supabaseService.getPatientById(canonicalId) ??
            await database.getPatient(canonicalId);
      }

      // 2. If not mapped by external ID, search by business identity: (normalized_name, normalized_phone)
      if (existingPatient == null && normPhone != null && normPhone.isNotEmpty) {
        existingPatient = await supabaseService.findPatientByBusinessIdentity(normName, normPhone) ??
            await database.getPatientByBusinessIdentity(normName, normPhone);
      }

      if (existingPatient != null) {
        // MATCH FOUND: Retain existing canonical UUID and Drive folder!
        linkedCount++;
        final merged = Patient.merge(existingPatient, incoming.copyWith(id: existingPatient.id));

        // Update Supabase
        try {
          await supabaseService.upsertPatient(merged);
          await supabaseService.linkPatientSource(
            patientId: existingPatient.id,
            source: 'google_sheets',
            externalId: externalId,
          );
        } catch (e) {
          debugPrint('Warning: unable to sync reconciled patient to Supabase: $e');
        }

        // Update SQLite
        await database.updatePatient(merged);
        await database.linkPatientSource(
          patientId: existingPatient.id,
          source: 'google_sheets',
          externalId: externalId,
        );

        reconciled.add(merged);
      } else {
        // GENUINELY NEW PATIENT: Assign fresh canonical UUID
        createdCount++;
        final newUuid = incoming.id.contains('-') ? incoming.id : uuidGen.v4();
        final newCanonical = incoming.copyWith(
          id: newUuid,
          legacyPatientId: externalId,
          source: PatientSource.clinicSheet,
          syncStatus: 'synced',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        // Insert into Supabase
        try {
          await supabaseService.upsertPatient(newCanonical);
          await supabaseService.linkPatientSource(
            patientId: newUuid,
            source: 'google_sheets',
            externalId: externalId,
          );
        } catch (e) {
          debugPrint('Warning: unable to insert new patient to Supabase: $e');
        }

        // Insert into SQLite
        await database.upsertPatients([newCanonical]);
        await database.linkPatientSource(
          patientId: newUuid,
          source: 'google_sheets',
          externalId: externalId,
        );

        reconciled.add(newCanonical);
      }
    }

    return ReconciliationResult(
      totalSheetPatients: sheetPatients.length,
      linkedExistingCount: linkedCount,
      createdNewCount: createdCount,
      reconciledPatients: reconciled,
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
  /// 2. Pulls all canonical patients from Supabase and caches them in SQLite.
  Future<void> syncLocalWithSupabase() async {
    // 1. Push pending local patients to Supabase
    final localPatients = await database.getPatients();
    final pending = localPatients.where((p) => p.syncStatus == 'pending_cloud').toList();

    for (final patient in pending) {
      try {
        await supabaseService.upsertPatient(patient);
        final synced = patient.copyWith(syncStatus: 'synced');
        await database.updatePatient(synced);
      } catch (e) {
        debugPrint('Failed to push patient ${patient.id} to Supabase: $e');
      }
    }

    // 2. Pull canonical patients from Supabase to SQLite
    try {
      final cloudPatients = await supabaseService.fetchAllPatients();
      if (cloudPatients.isNotEmpty) {
        await database.upsertPatients(cloudPatients);
      }
    } catch (e) {
      debugPrint('Failed to fetch patients from Supabase: $e');
    }
  }
}
