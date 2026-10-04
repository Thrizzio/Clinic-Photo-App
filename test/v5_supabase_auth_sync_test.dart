import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:clinic_photos/config.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/patient_sync_service.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/supabase_patient_service.dart';
import 'package:clinic_photos/services/supabase_auth_service.dart';

void main() {
  group('V5 Supabase Authentication, RLS & Multi-Device Sync Integration Tests', () {
    const supabaseUrl = AppConfig.defaultSupabaseUrl;
    const anonKey = AppConfig.defaultSupabaseAnonKey;

    test('1. Direct client (anon role) can access patients and patient_sources under single-clinic MVP', () async {
      final anonClient = SupabaseClient(
        supabaseUrl,
        anonKey,
        authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      );

      expect(anonClient.auth.currentUser, isNull);
      expect(anonClient.auth.currentSession, isNull);

      final testUuid = const Uuid().v4();
      final insertedPatient = await anonClient.from('patients').upsert({
        'id': testUuid,
        'display_name': 'Single Clinic Test Patient',
        'normalized_name': 'single clinic test patient',
      }).select().single();

      expect(insertedPatient['id'], testUuid);
      expect(insertedPatient['clinic_id'], 'c0000000-0000-0000-0000-000000000001');

      final externalId = 'anon_${testUuid.substring(0, 8)}';
      final insertedSource = await anonClient.from('patient_sources').upsert({
        'patient_id': testUuid,
        'source': 'google_sheets',
        'external_id': externalId,
      }).select().single();

      expect(insertedSource['patient_id'], testUuid);

      // Clean up test data
      await anonClient.from('patient_sources').delete().eq('patient_id', testUuid);
      await anonClient.from('patients').delete().eq('id', testUuid);
    });

    test('2. Authenticate clinic doctor and verify patient + patient_sources writes and multi-device retrieval', () async {
      final clientDevice1 = SupabaseClient(
        supabaseUrl,
        anonKey,
        authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      );

      final authService1 = SupabaseAuthService(client: clientDevice1);
      final didAuth1 = await authService1.ensureAuthenticated();
      expect(didAuth1, isTrue);
      expect(authService1.isAuthenticated, isTrue);
      expect(authService1.currentUser, isNotNull);

      final supabaseService1 = SupabasePatientService.live(clientDevice1);
      final dbDevice1 = InMemoryAppDatabase();
      final syncService1 = PatientSyncService(
        database: dbDevice1,
        supabaseService: supabaseService1,
        sheetsService: SheetsService(),
      );

      // Create a test patient with unique external Sheet ID and phone
      final testPatientUuid = const Uuid().v4();
      final uniqueSuffix = DateTime.now().microsecondsSinceEpoch.toString();
      final uniqueExternalId = 'sheet_${uniqueSuffix.substring(uniqueSuffix.length - 8)}';
      final uniquePhone = '9${uniqueSuffix.substring(uniqueSuffix.length - 9)}';

      final localPatient = Patient(
        id: testPatientUuid,
        name: 'Dr Sync Test Patient $uniqueSuffix',
        displayName: 'Dr Sync Test Patient $uniqueSuffix',
        normalizedName: 'dr sync test patient $uniqueSuffix',
        phoneNumber: uniquePhone,
        phoneDisplay: uniquePhone,
        normalizedPhone: uniquePhone,
        legacyPatientId: uniqueExternalId,
        source: PatientSource.clinicSheet,
        syncStatus: 'pending_cloud',
      );

      await dbDevice1.upsertPatients([localPatient]);

      // Run syncLocalWithSupabase
      await syncService1.syncLocalWithSupabase();

      // Verify patient in Supabase
      final cloudPatient = await supabaseService1.getPatientById(testPatientUuid);
      expect(cloudPatient, isNotNull);
      expect(cloudPatient!.displayName, 'Dr Sync Test Patient $uniqueSuffix');

      // Verify patient_sources mapping in Supabase
      final mappedUuid = await supabaseService1.getPatientIdBySource(
        source: 'google_sheets',
        externalId: uniqueExternalId,
      );
      expect(mappedUuid, testPatientUuid);

      // 3. Second device authenticates and retrieves the same canonical patient
      final clientDevice2 = SupabaseClient(
        supabaseUrl,
        anonKey,
        authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      );
      final authService2 = SupabaseAuthService(client: clientDevice2);
      await authService2.ensureAuthenticated();
      expect(authService2.isAuthenticated, isTrue);

      final supabaseService2 = SupabasePatientService.live(clientDevice2);
      final dbDevice2 = InMemoryAppDatabase();
      final syncService2 = PatientSyncService(
        database: dbDevice2,
        supabaseService: supabaseService2,
        sheetsService: SheetsService(),
      );

      // Device 2 pulls cloud patients into local SQLite cache
      await syncService2.syncLocalWithSupabase();

      final device2Patients = await dbDevice2.getPatients();
      final foundOnDevice2 = device2Patients.any((p) => p.id == testPatientUuid);
      expect(foundOnDevice2, isTrue);

      // Clean up test patient and sources from Supabase
      await clientDevice1.from('patient_sources').delete().eq('patient_id', testPatientUuid);
      await clientDevice1.from('patients').delete().eq('id', testPatientUuid);
    });

    test('3. Newly created doctor patient immediately syncs to Supabase under authenticated session', () async {
      final client = SupabaseClient(
        supabaseUrl,
        anonKey,
        authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      );
      final authService = SupabaseAuthService(client: client);
      await authService.ensureAuthenticated();

      final supabaseService = SupabasePatientService.live(client);
      final db = InMemoryAppDatabase();

      final newUuid = const Uuid().v4();
      final newDoctorPatient = Patient(
        id: newUuid,
        name: 'New Walkin Patient',
        displayName: 'New Walkin Patient',
        normalizedName: 'new walkin patient',
        phoneNumber: '9123456780',
        phoneDisplay: '9123456780',
        normalizedPhone: '9123456780',
        source: PatientSource.doctorCreated,
        syncStatus: 'pending_cloud',
      );

      await db.upsertPatients([newDoctorPatient]);

      // Direct push
      final pushed = await supabaseService.upsertPatient(newDoctorPatient);
      expect(pushed.id, newUuid);

      final retrieved = await supabaseService.getPatientById(newUuid);
      expect(retrieved, isNotNull);
      expect(retrieved!.displayName, 'New Walkin Patient');

      // Clean up
      await client.from('patients').delete().eq('id', newUuid);
    });

    test('4. Full reconciliation with Google Sheets patients populates Supabase and patient_sources without placeholders', () async {
      final client = SupabaseClient(
        supabaseUrl,
        anonKey,
        authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      );
      final authService = SupabaseAuthService(client: client);
      await authService.ensureAuthenticated();

      final supabaseService = SupabasePatientService.live(client);
      final db = InMemoryAppDatabase();
      final syncService = PatientSyncService(
        database: db,
        supabaseService: supabaseService,
        sheetsService: SheetsService(),
      );

      final sheetPatients = [
        const Patient(
          id: '1000101',
          name: 'Aarav Sharma',
          displayName: 'Aarav Sharma',
          phoneNumber: '9876543201',
          legacyPatientId: '1000101',
          source: PatientSource.clinicSheet,
          folderStatus: FolderStatus.missing,
        ),
        const Patient(
          id: '1000102',
          name: 'Diya Patel',
          displayName: 'Diya Patel',
          phoneNumber: '9876543202',
          legacyPatientId: '1000102',
          source: PatientSource.clinicSheet,
          folderStatus: FolderStatus.missing,
        ),
        // Empty name row that must be skipped and NEVER create a placeholder
        const Patient(
          id: '1000103',
          name: '',
          displayName: '',
          phoneNumber: '9876543203',
          legacyPatientId: '1000103',
          source: PatientSource.clinicSheet,
          folderStatus: FolderStatus.missing,
        ),
      ];

      final reconResult = await syncService.reconcileSheetPatients(sheetPatients);

      // Verify empty row was completely skipped (only 2 valid patients reconciled)
      expect(reconResult.reconciledPatients.length, 2);
      expect(reconResult.reconciledPatients.any((p) => p.displayName.isEmpty || p.displayName == 'Name unavailable'), isFalse);

      // Verify each patient in Supabase has a valid UUID and patient_sources mapping
      final createdUuids = <String>[];
      for (final p in reconResult.reconciledPatients) {
        expect(Patient.isValidUuid(p.id), isTrue);
        createdUuids.add(p.id);

        final cloudP = await supabaseService.getPatientById(p.id);
        expect(cloudP, isNotNull);
        expect(cloudP!.displayName, p.displayName);

        // Verify patient_sources mapping
        final mappedId = await supabaseService.getPatientIdBySource(
          source: 'google_sheets',
          externalId: p.legacyPatientId!,
        );
        expect(mappedId, p.id);
      }

      // Verify truthful sync reporting
      expect(reconResult.isSupabaseSynced, isTrue);
      expect(reconResult.cloudPatientCount, greaterThanOrEqualTo(2));

      // Clean up test patients
      for (final id in createdUuids) {
        await client.from('patient_sources').delete().eq('patient_id', id);
        await client.from('patients').delete().eq('id', id);
      }
    });
  });
}
