import 'package:flutter_test/flutter_test.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/supabase_patient_service.dart';
import 'package:clinic_photos/services/patient_sync_service.dart';

class FakeSheetsService extends SheetsService {}

void main() {
  late InMemoryAppDatabase database;
  late InMemorySupabasePatientService supabaseService;
  late FakeSheetsService sheetsService;
  late PatientSyncService syncService;

  setUp(() {
    database = InMemoryAppDatabase();
    supabaseService = InMemorySupabasePatientService();
    sheetsService = FakeSheetsService();
    syncService = PatientSyncService(
      database: database,
      supabaseService: supabaseService,
      sheetsService: sheetsService,
    );
  });

  group('V5 Canonical Identity & Cross-Source Deduplication Tests', () {
    test('Day 1 doctor creation + Day 5 Sheets reconciliation links without duplicates', () async {
      // Day 1: Doctor creates a patient in-app
      const doctorPatientId = 'uuid-doctor-anil-001';
      final doctorPatient = Patient(
        id: doctorPatientId,
        name: 'Anil Jain',
        displayName: 'Anil Jain',
        phoneNumber: '+91 94223 01214',
        source: PatientSource.doctorCreated,
        driveFolderId: 'folder_anil_drive_123',
        folderStatus: FolderStatus.available,
        syncStatus: 'pending_cloud',
      );

      await database.upsertPatients([doctorPatient]);
      // Doctor-created patient is synced to Supabase
      await supabaseService.upsertPatient(doctorPatient);

      final initialPatients = await database.getPatients();
      expect(initialPatients.length, 1);
      expect(initialPatients.first.id, doctorPatientId);
      expect(initialPatients.first.source, PatientSource.doctorCreated);
      expect(initialPatients.first.legacyPatientId, isNull);

      // Day 5: Google Sheets sync occurs with a matching patient
      final incomingSheetPatient = Patient(
        id: '1000048', // Sheet legacy ID
        legacyPatientId: '1000048',
        name: 'Anil Jain',
        displayName: 'Anil Jain',
        phoneNumber: '9422301214',
        source: PatientSource.clinicSheet,
      );

      final result = await syncService.reconcileSheetPatients([incomingSheetPatient]);

      // Assertions:
      // 1. One patient was linked to existing
      expect(result.totalSheetPatients, 1);
      expect(result.linkedExistingCount, 1);
      expect(result.createdNewCount, 0);

      // 2. Exactly one patient exists in database (zero duplicates)
      final allPatients = await database.getPatients();
      expect(allPatients.length, 1);

      final reconciled = allPatients.first;
      // 3. Canonical UUID is strictly preserved
      expect(reconciled.id, doctorPatientId);
      // 4. Source transitioned to merged
      expect(reconciled.source, PatientSource.merged);
      // 5. Legacy Patient ID attached
      expect(reconciled.legacyPatientId, '1000048');
      // 6. Existing Drive folder preserved
      expect(reconciled.driveFolderId, 'folder_anil_drive_123');
      expect(reconciled.isUploadable, isTrue);

      // 7. Source mapping is established in both SQLite and Supabase
      final mappedIdLocal = await database.getPatientIdBySource(
        source: 'google_sheets',
        externalId: '1000048',
      );
      expect(mappedIdLocal, doctorPatientId);

      final mappedIdSupabase = await supabaseService.getPatientIdBySource(
        source: 'google_sheets',
        externalId: '1000048',
      );
      expect(mappedIdSupabase, doctorPatientId);
    });

    test('Absence of a patient from Google Sheets NEVER deletes or archives canonical patient', () async {
      // Setup 3 patients:
      // - 2 doctor-created patients
      // - 1 sheet-imported patient
      final docPatient1 = Patient(
        id: 'uuid-doc-1',
        name: 'Ramesh Pawar',
        phoneNumber: '9822011111',
        source: PatientSource.doctorCreated,
      );
      final docPatient2 = Patient(
        id: 'uuid-doc-2',
        name: 'Suresh Patil',
        phoneNumber: '9822022222',
        source: PatientSource.doctorCreated,
      );
      final sheetPatient1 = Patient(
        id: 'uuid-sheet-1',
        legacyPatientId: '1000001',
        name: 'Anita Sharma',
        phoneNumber: '9822033333',
        source: PatientSource.clinicSheet,
      );

      for (final p in [docPatient1, docPatient2, sheetPatient1]) {
        await database.upsertPatients([p]);
        await supabaseService.upsertPatient(p);
      }
      await database.linkPatientSource(
        patientId: 'uuid-sheet-1',
        source: 'google_sheets',
        externalId: '1000001',
      );
      await supabaseService.linkPatientSource(
        patientId: 'uuid-sheet-1',
        source: 'google_sheets',
        externalId: '1000001',
      );

      expect((await database.getPatients()).length, 3);

      // New Sheet sync with ONLY Anita Sharma (Ramesh and Suresh are not in the sheet)
      final incomingSheet = [
        Patient(
          id: '1000001',
          legacyPatientId: '1000001',
          name: 'Anita Sharma',
          phoneNumber: '9822033333',
          source: PatientSource.clinicSheet,
        ),
      ];

      final result = await syncService.reconcileSheetPatients(incomingSheet);

      expect(result.linkedExistingCount, 1);
      expect(result.createdNewCount, 0);

      // Invariant: Both doctor-created patients MUST still exist!
      final remaining = await database.getPatients();
      expect(remaining.length, 3);
      expect(remaining.any((p) => p.id == 'uuid-doc-1'), isTrue);
      expect(remaining.any((p) => p.id == 'uuid-doc-2'), isTrue);
      expect(remaining.any((p) => p.id == 'uuid-sheet-1'), isTrue);

      // Supabase still has all 3
      final supabasePatients = await supabaseService.fetchAllPatients();
      expect(supabasePatients.length, 3);
    });

    test('Business identity matching handles whitespace, casing, and varied phone formats', () async {
      // Existing patient in Supabase and SQLite
      const canonicalId = 'uuid-rahul-999';
      final existing = Patient(
        id: canonicalId,
        displayName: 'Rahul Verma',
        phoneNumber: '+91 98765 43210',
        source: PatientSource.doctorCreated,
      );
      await database.upsertPatients([existing]);
      await supabaseService.upsertPatient(existing);

      // Incoming sheet patient with different formatting: all uppercase, multiple spaces, national format phone
      final incoming = Patient(
        id: '2000099',
        legacyPatientId: '2000099',
        name: '  RAHUL   VERMA  ',
        phoneNumber: '09876543210',
      );

      final result = await syncService.reconcileSheetPatients([incoming]);

      expect(result.linkedExistingCount, 1);
      expect(result.createdNewCount, 0);

      final patients = await database.getPatients();
      expect(patients.length, 1);
      expect(patients.first.id, canonicalId);
      expect(patients.first.source, PatientSource.merged);
      expect(patients.first.legacyPatientId, '2000099');
    });

    test('syncLocalWithSupabase uploads local pending patients and downloads remote patients', () async {
      // 1. Local offline patient not yet in Supabase
      final localPending = Patient(
        id: 'uuid-offline-local',
        name: 'Offline Local Patient',
        phoneNumber: '9111122222',
        source: PatientSource.doctorCreated,
        syncStatus: 'pending_cloud',
      );
      await database.upsertPatients([localPending]);

      // 2. Remote patient in Supabase not yet in local SQLite
      final remoteCloud = Patient(
        id: 'uuid-remote-cloud',
        name: 'Remote Cloud Patient',
        phoneNumber: '9333344444',
        source: PatientSource.clinicSheet,
        legacyPatientId: '1000999',
        syncStatus: 'synced',
      );
      await supabaseService.upsertPatient(remoteCloud);
      await supabaseService.linkPatientSource(
        patientId: remoteCloud.id,
        source: 'google_sheets',
        externalId: '1000999',
      );

      // Perform sync
      await syncService.syncLocalWithSupabase();

      // Local database now has both patients
      final localAll = await database.getPatients();
      expect(localAll.length, 2);
      expect(localAll.any((p) => p.id == 'uuid-offline-local'), isTrue);
      expect(localAll.any((p) => p.id == 'uuid-remote-cloud'), isTrue);

      // Local offline patient marked 'synced'
      final syncedLocal = await database.getPatient('uuid-offline-local');
      expect(syncedLocal?.syncStatus, 'synced');

      // Supabase now has both patients
      final remoteAll = await supabaseService.fetchAllPatients();
      expect(remoteAll.length, 2);
      expect(remoteAll.any((p) => p.id == 'uuid-offline-local'), isTrue);
      expect(remoteAll.any((p) => p.id == 'uuid-remote-cloud'), isTrue);
    });
  });
}
