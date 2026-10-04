import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../models/patient.dart';

/// Abstract service managing canonical cloud patient identity in Supabase.
abstract class SupabasePatientService {
  /// Fetches all canonical patients from Supabase.
  Future<List<Patient>> fetchAllPatients();

  /// Retrieves a canonical patient by their primary UUID.
  Future<Patient?> getPatientById(String id);

  /// Searches for an existing patient matching the exact business identity:
  /// `normalized_name + normalized_phone`.
  Future<Patient?> findPatientByBusinessIdentity(
    String normalizedName,
    String? normalizedPhone,
  );

  /// Upserts a canonical patient record in Supabase.
  Future<Patient> upsertPatient(Patient patient);

  /// Links an external source ID (e.g. 'google_sheets' -> '1000048') to a canonical patient UUID.
  Future<void> linkPatientSource({
    required String patientId,
    required String source,
    required String externalId,
  });

  /// Resolves a canonical patient UUID given an external source identifier.
  Future<String?> getPatientIdBySource({
    required String source,
    required String externalId,
  });

  /// Gets all source mappings for a patient UUID.
  Future<List<Map<String, String>>> getSourcesForPatient(String patientId);

  /// Deletes a canonical patient and associated source mappings from Supabase.
  Future<void> deletePatient(String patientId);

  /// Factory constructor to create in-memory service for testing or offline mocking.
  factory SupabasePatientService.inMemory({
    Map<String, Patient>? initialPatients,
    Map<String, List<({String source, String externalId})>>? initialSources,
  }) {
    return InMemorySupabasePatientService(
      initialPatients: initialPatients,
      initialSources: initialSources,
    );
  }

  /// Production implementation using live Supabase client.
  factory SupabasePatientService.live(SupabaseClient client) {
    return RemoteSupabasePatientService(client);
  }
}

/// Production implementation connecting to Supabase via PostgREST.
class RemoteSupabasePatientService implements SupabasePatientService {
  final SupabaseClient client;

  RemoteSupabasePatientService(this.client);

  @override
  Future<List<Patient>> fetchAllPatients() async {
    try {
      final response = await client
          .from('patients')
          .select('id, display_name, normalized_name, phone_display, normalized_phone, drive_folder_id, created_at, updated_at');
      
      final list = <Patient>[];
      for (final row in (response as List<dynamic>)) {
        list.add(_patientFromSupabaseRow(row as Map<String, dynamic>));
      }
      return list;
    } catch (e) {
      debugPrint('Supabase fetchAllPatients error: $e');
      rethrow;
    }
  }

  @override
  Future<Patient?> getPatientById(String id) async {
    if (!Patient.isValidUuid(id)) {
      return null;
    }

    try {
      final response = await client
          .from('patients')
          .select()
          .eq('id', id)
          .maybeSingle();
      if (response == null) return null;
      return _patientFromSupabaseRow(response);
    } catch (e) {
      debugPrint('Supabase getPatientById error: $e');
      rethrow;
    }
  }

  @override
  Future<Patient?> findPatientByBusinessIdentity(
    String normalizedName,
    String? normalizedPhone,
  ) async {
    if (normalizedPhone == null || normalizedPhone.isEmpty) {
      return null;
    }

    try {
      final response = await client
          .from('patients')
          .select()
          .eq('normalized_name', normalizedName)
          .eq('normalized_phone', normalizedPhone)
          .maybeSingle();

      if (response == null) return null;
      return _patientFromSupabaseRow(response);
    } catch (e) {
      debugPrint('Supabase findPatientByBusinessIdentity error: $e');
      rethrow;
    }
  }

  @override
  Future<Patient> upsertPatient(Patient patient) async {
    if (!Patient.isValidUuid(patient.id)) {
      throw ArgumentError(
        'Cannot upsert patient with non-UUID id: "${patient.id}". Supabase requires a valid UUID primary key.',
      );
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final rowData = {
      'id': patient.id,
      'display_name': patient.displayName,
      'normalized_name': patient.normalizedName,
      'phone_display': patient.phoneDisplay,
      'normalized_phone': patient.normalizedPhone,
      'drive_folder_id': patient.driveFolderId,
      'updated_at': nowIso,
    };

    try {
      final response = await client
          .from('patients')
          .upsert(
            rowData,
            onConflict: 'id',
          )
          .select()
          .maybeSingle();

      if (response != null) {
        return _patientFromSupabaseRow(response).copyWith(
          legacyPatientId: patient.legacyPatientId,
          source: patient.source,
          syncStatus: 'synced',
        );
      }
      return patient.copyWith(syncStatus: 'synced');
    } catch (e) {
      debugPrint('Supabase upsertPatient error: $e');
      rethrow;
    }
  }

  @override
  Future<void> linkPatientSource({
    required String patientId,
    required String source,
    required String externalId,
  }) async {
    if (!Patient.isValidUuid(patientId)) {
      throw ArgumentError(
        'Cannot link patient source with non-UUID patientId: "$patientId". patient_id must be a valid UUID foreign key.',
      );
    }

    final rowData = {
      'id': const Uuid().v4(),
      'patient_id': patientId,
      'source': source,
      'external_id': externalId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };

    try {
      await client.from('patient_sources').upsert(
        rowData,
        onConflict: 'source,external_id',
      );
    } catch (e) {
      debugPrint('Supabase linkPatientSource error: $e');
      rethrow;
    }
  }

  @override
  Future<String?> getPatientIdBySource({
    required String source,
    required String externalId,
  }) async {
    try {
      final response = await client
          .from('patient_sources')
          .select('patient_id')
          .eq('source', source)
          .eq('external_id', externalId)
          .maybeSingle();

      if (response == null) return null;
      final pId = response['patient_id']?.toString();
      if (pId != null && Patient.isValidUuid(pId)) {
        return pId;
      }
      return null;
    } catch (e) {
      debugPrint('Supabase getPatientIdBySource error: $e');
      rethrow;
    }
  }

  @override
  Future<List<Map<String, String>>> getSourcesForPatient(String patientId) async {
    if (!Patient.isValidUuid(patientId)) {
      return [];
    }

    try {
      final response = await client
          .from('patient_sources')
          .select('source, external_id')
          .eq('patient_id', patientId);

      final result = <Map<String, String>>[];
      for (final row in (response as List<dynamic>)) {
        final m = row as Map<String, dynamic>;
        result.add({
          'source': m['source']?.toString() ?? '',
          'external_id': m['external_id']?.toString() ?? '',
        });
      }
      return result;
    } catch (e) {
      debugPrint('Supabase getSourcesForPatient error: $e');
      return [];
    }
  }

  @override
  Future<void> deletePatient(String patientId) async {
    if (!Patient.isValidUuid(patientId)) {
      return;
    }
    try {
      // Delete source mappings first to satisfy foreign key ordering
      await client.from('patient_sources').delete().eq('patient_id', patientId);
      // Delete patient record
      await client.from('patients').delete().eq('id', patientId);
    } catch (e) {
      debugPrint('Supabase deletePatient error: $e');
      rethrow;
    }
  }

  Patient _patientFromSupabaseRow(Map<String, dynamic> row) {
    final rawName = row['display_name']?.toString() ?? '';
    final rawPhone = row['phone_display']?.toString();
    final folderId = row['drive_folder_id']?.toString();
    final createdAt = row['created_at'] != null ? DateTime.tryParse(row['created_at'].toString()) : null;
    final updatedAt = row['updated_at'] != null ? DateTime.tryParse(row['updated_at'].toString()) : null;

    return Patient(
      id: row['id'].toString(),
      displayName: rawName,
      name: rawName,
      normalizedName: row['normalized_name']?.toString() ?? Patient.normalizeName(rawName),
      phoneDisplay: rawPhone,
      normalizedPhone: row['normalized_phone']?.toString() ?? Patient.normalizePhone(rawPhone),
      driveFolderId: folderId,
      folderStatus: folderId != null && folderId.isNotEmpty ? FolderStatus.available : FolderStatus.missing,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

/// In-memory implementation of SupabasePatientService for fast unit tests and offline testing.
class InMemorySupabasePatientService implements SupabasePatientService {
  final Map<String, Patient> _patients = {};
  // key: "$source:$externalId" -> patient_id
  final Map<String, String> _sourceToPatientId = {};
  // key: patientId -> list of {source, external_id}
  final Map<String, List<({String source, String externalId})>> _patientSources = {};

  InMemorySupabasePatientService({
    Map<String, Patient>? initialPatients,
    Map<String, List<({String source, String externalId})>>? initialSources,
  }) {
    if (initialPatients != null) {
      _patients.addAll(initialPatients);
    }
    if (initialSources != null) {
      _patientSources.addAll(initialSources);
      for (final entry in initialSources.entries) {
        for (final s in entry.value) {
          _sourceToPatientId['${s.source}:${s.externalId}'] = entry.key;
        }
      }
    }
  }

  @override
  Future<List<Patient>> fetchAllPatients() async {
    return List.from(_patients.values);
  }

  @override
  Future<Patient?> getPatientById(String id) async {
    if (!Patient.isValidUuid(id)) return null;
    return _patients[id];
  }

  @override
  Future<Patient?> findPatientByBusinessIdentity(
    String normalizedName,
    String? normalizedPhone,
  ) async {
    if (normalizedPhone == null || normalizedPhone.isEmpty) return null;

    for (final p in _patients.values) {
      if (p.normalizedName == normalizedName && p.normalizedPhone == normalizedPhone) {
        return p;
      }
    }
    return null;
  }

  @override
  Future<Patient> upsertPatient(Patient patient) async {
    if (!Patient.isValidUuid(patient.id)) {
      throw ArgumentError(
        'Cannot upsert patient with non-UUID id: "${patient.id}". Supabase requires a valid UUID primary key.',
      );
    }
    _patients[patient.id] = patient;
    return patient;
  }

  @override
  Future<void> linkPatientSource({
    required String patientId,
    required String source,
    required String externalId,
  }) async {
    if (!Patient.isValidUuid(patientId)) {
      throw ArgumentError(
        'Cannot link patient source with non-UUID patientId: "$patientId". patient_id must be a valid UUID foreign key.',
      );
    }
    _sourceToPatientId['$source:$externalId'] = patientId;
    final list = _patientSources.putIfAbsent(patientId, () => []);
    list.removeWhere((item) => item.source == source && item.externalId == externalId);
    list.add((source: source, externalId: externalId));
  }

  @override
  Future<String?> getPatientIdBySource({
    required String source,
    required String externalId,
  }) async {
    final pId = _sourceToPatientId['$source:$externalId'];
    if (pId != null && Patient.isValidUuid(pId)) {
      return pId;
    }
    return null;
  }

  @override
  Future<List<Map<String, String>>> getSourcesForPatient(String patientId) async {
    if (!Patient.isValidUuid(patientId)) return [];
    final list = _patientSources[patientId] ?? [];
    return list.map((s) => {'source': s.source, 'external_id': s.externalId}).toList();
  }

  @override
  Future<void> deletePatient(String patientId) async {
    _patients.remove(patientId);
    final sources = _patientSources.remove(patientId);
    if (sources != null) {
      for (final s in sources) {
        _sourceToPatientId.remove('${s.source}:${s.externalId}');
      }
    }
  }
}
