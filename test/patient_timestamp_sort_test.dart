import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/patient_sync_service.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/supabase_patient_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final olderTimestamp = DateTime.utc(2026, 1, 1, 9);
  final newerTimestamp = DateTime.utc(2026, 1, 2, 9);

  Patient patient({
    required String id,
    required String name,
    required DateTime updatedAt,
    String? driveFolderId,
    String? legacyPatientId,
  }) {
    return Patient(
      id: id,
      name: name,
      phoneNumber: id.replaceAll('-', '').padRight(10, '0').substring(0, 10),
      legacyPatientId: legacyPatientId,
      driveFolderId: driveFolderId,
      folderStatus: driveFolderId == null
          ? FolderStatus.missing
          : FolderStatus.available,
      createdAt: olderTimestamp,
      updatedAt: updatedAt,
    );
  }

  group('Patient last-modified ordering', () {
    test(
      'getPatients and searchPatients return newest patients first',
      () async {
        final database = InMemoryAppDatabase();
        addTearDown(database.close);

        await database.replacePatients([
          patient(
            id: 'older',
            name: 'Older Patient',
            updatedAt: olderTimestamp,
          ),
          patient(
            id: 'newer',
            name: 'Newer Patient',
            updatedAt: newerTimestamp,
          ),
        ]);

        expect((await database.getPatients()).map((p) => p.id), [
          'newer',
          'older',
        ]);
        expect((await database.searchPatients('Patient')).map((p) => p.id), [
          'newer',
          'older',
        ]);
      },
    );

    test(
      'equal timestamps use a deterministic name and ID tie-breaker',
      () async {
        final database = InMemoryAppDatabase();
        addTearDown(database.close);

        await database.replacePatients([
          patient(id: 'tie-b', name: 'Same Name', updatedAt: newerTimestamp),
          patient(id: 'tie-a', name: 'Same Name', updatedAt: newerTimestamp),
        ]);

        final firstRead = await database.getPatients();
        final secondRead = await database.getPatients();
        final searchRead = await database.searchPatients('Same');

        expect(firstRead.map((p) => p.id), ['tie-a', 'tie-b']);
        expect(secondRead.map((p) => p.id), ['tie-a', 'tie-b']);
        expect(searchRead.map((p) => p.id), ['tie-a', 'tie-b']);
      },
    );
  });

  group('Patient updatedAt semantics', () {
    test('unchanged remote reconciliation preserves updatedAt', () async {
      const patientId = '11111111-1111-4111-8111-111111111111';
      final existing = patient(
        id: patientId,
        name: 'Stable Patient',
        updatedAt: olderTimestamp,
        driveFolderId: 'folder-stable',
        legacyPatientId: 'sheet-stable',
      );
      final database = InMemoryAppDatabase(
        initialPatients: {patientId: existing},
      );
      final supabase = InMemorySupabasePatientService(
        initialPatients: {patientId: existing},
      );
      addTearDown(database.close);

      final sync = PatientSyncService(
        database: database,
        supabaseService: supabase,
        sheetsService: SheetsService(),
      );

      // The parser creates a fresh incoming timestamp for each fetch, but the
      // patient data itself is unchanged.
      await sync.reconcileSheetPatients([
        existing.copyWith(
          id: 'sheet-stable',
          legacyPatientId: 'sheet-stable',
          updatedAt: newerTimestamp,
        ),
      ]);
      await sync.syncLocalWithSupabase();

      final localAfter = await database.getPatient(patientId);
      final cloudAfter = await supabase.getPatientById(patientId);
      expect(localAfter?.updatedAt, olderTimestamp);
      expect(cloudAfter?.updatedAt, olderTimestamp);
      expect(localAfter?.id, patientId);
      expect(localAfter?.driveFolderId, 'folder-stable');
    });

    test(
      'a genuine local edit advances updatedAt without changing identity',
      () async {
        const patientId = '22222222-2222-4222-8222-222222222222';
        final database = InMemoryAppDatabase();
        addTearDown(database.close);
        final existing = patient(
          id: patientId,
          name: 'Before Edit',
          updatedAt: olderTimestamp,
          driveFolderId: 'folder-local',
        );
        await database.upsertPatients([existing]);

        await database.updatePatient(existing.copyWith(name: 'After Edit'));

        final updated = await database.getPatient(patientId);
        expect(updated?.updatedAt, isNotNull);
        expect(updated!.updatedAt!.isAfter(olderTimestamp), isTrue);
        expect(updated.id, patientId);
        expect(updated.driveFolderId, 'folder-local');
      },
    );

    test(
      'cloud reconciliation changes advance updatedAt consistently',
      () async {
        const patientId = '33333333-3333-4333-8333-333333333333';
        final cloudChangedAt = DateTime.utc(2026, 1, 3, 9);
        final existing = patient(
          id: patientId,
          name: 'Before Cloud Edit',
          updatedAt: olderTimestamp,
          driveFolderId: 'folder-cloud',
        );
        final database = InMemoryAppDatabase(
          initialPatients: {patientId: existing},
        );
        final supabase = InMemorySupabasePatientService(
          initialPatients: {patientId: existing},
        );
        addTearDown(database.close);

        final sync = PatientSyncService(
          database: database,
          supabaseService: supabase,
          sheetsService: SheetsService(),
        );
        await sync.reconcileSheetPatients([
          Patient(
            id: 'sheet-cloud',
            legacyPatientId: 'sheet-cloud',
            name: 'After Cloud Edit',
            phoneNumber: existing.phoneNumber,
            source: PatientSource.clinicSheet,
            driveFolderId: 'folder-cloud',
            folderStatus: FolderStatus.available,
            updatedAt: cloudChangedAt,
          ),
        ]);

        final localAfter = await database.getPatient(patientId);
        final cloudAfter = await supabase.getPatientById(patientId);
        expect(localAfter?.updatedAt, cloudChangedAt);
        expect(cloudAfter?.updatedAt, cloudChangedAt);
        expect(localAfter?.displayName, 'After Cloud Edit');
        expect(localAfter?.id, patientId);
        expect(localAfter?.driveFolderId, 'folder-cloud');
      },
    );
  });
}
