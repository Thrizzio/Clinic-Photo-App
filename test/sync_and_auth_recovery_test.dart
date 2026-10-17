import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clinic_photos/models/clinic_config.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/screens/patients_screen.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/patient_sync_service.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/supabase_patient_service.dart';
import 'package:clinic_photos/services/upload_queue.dart';

class _UnreadySupabasePatientService extends InMemorySupabasePatientService {
  int fetchAllCalled = 0;
  int upsertCalled = 0;

  @override
  bool get isReadyForSync => false;

  @override
  Future<List<Patient>> fetchAllPatients() async {
    fetchAllCalled++;
    throw Exception('Should not be called when isReadyForSync is false');
  }

  @override
  Future<void> upsertPatients(List<Patient> patients) async {
    upsertCalled++;
    throw Exception('Should not be called when isReadyForSync is false');
  }
}

class _TestGoogleAuthService extends GoogleAuthService {
  int signInCalls = 0;
  int silentCalls = 0;
  GoogleSignInAccount? mockAccount;

  _TestGoogleAuthService() : super(GoogleSignIn.instance);

  @override
  Future<GoogleSignInAccount?> signInSilently() async {
    silentCalls++;
    return mockAccount;
  }

  @override
  Future<GoogleSignInAccount?> signIn() async {
    signInCalls++;
    return mockAccount;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Sync & Authentication Recovery Tests', () {
    late InMemoryAppDatabase database;
    late SheetsService sheetsService;

    setUp(() {
      database = InMemoryAppDatabase();
      sheetsService = SheetsService();
    });

    test('1. reconcileSheetPatients skips Supabase fetch and upsert when isReadyForSync is false', () async {
      final unreadySupabase = _UnreadySupabasePatientService();
      final syncService = PatientSyncService(
        database: database,
        supabaseService: unreadySupabase,
        sheetsService: sheetsService,
      );

      final incoming = [
        Patient(
          id: 'temp_1',
          name: 'Jane Doe',
          phoneNumber: '9876543210',
          legacyPatientId: '1001',
          source: PatientSource.clinicSheet,
        ),
      ];

      final stopwatch = Stopwatch()..start();
      final result = await syncService.reconcileSheetPatients(incoming);
      stopwatch.stop();

      // Should complete nearly instantaneously (< 100ms) without hanging
      expect(stopwatch.elapsedMilliseconds, lessThan(500));
      expect(unreadySupabase.fetchAllCalled, 0);
      expect(unreadySupabase.upsertCalled, 0);

      // Successfully saved to local SQLite with pending_cloud status
      expect(result.reconciledPatients.length, 1);
      final inDb = await database.getPatient(result.reconciledPatients.first.id);
      expect(inDb, isNotNull);
      expect(inDb!.displayName, 'Jane Doe');
      expect(inDb.syncStatus, 'pending_cloud');
    });

    test('2. GoogleAuthService bounded one-time recovery attempt', () async {
      final auth = _TestGoogleAuthService();

      // Silent request never calls interactive signIn
      final silentClient = await auth.getAuthenticatedClientSilently();
      expect(silentClient, isNull);
      expect(auth.silentCalls, 1);
      expect(auth.signInCalls, 0);

      // First interactive request calls interactive signIn once
      final interactiveClient1 = await auth.getAuthenticatedClient();
      expect(interactiveClient1, isNull);
      expect(auth.signInCalls, 1);

      // Second interactive request before reset does NOT repeat prompt (bounded)
      final interactiveClient2 = await auth.getAuthenticatedClient();
      expect(interactiveClient2, isNull);
      expect(auth.signInCalls, 1); // Still 1! Did not loop

      // Explicit resetRecoveryAttempt allows a fresh attempt
      auth.resetRecoveryAttempt();
      final interactiveClient3 = await auth.getAuthenticatedClient();
      expect(interactiveClient3, isNull);
      expect(auth.signInCalls, 2); // Now 2
    });

    testWidgets('3. Pull-to-refresh completes promptly without leaving persistent spinner', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final configService = await ConfigService.init();
      await configService.saveConfig(
        const ClinicConfig(
          spreadsheetId: 'test_sheet',
          spreadsheetUrl: 'https://docs.google.com/spreadsheets/d/test_sheet/edit',
          sheetTabName: 'Visits',
          hasCompletedSetup: true,
          lastSyncedRow: 1,
        ),
      );

      final auth = _TestGoogleAuthService();
      final queueService = UploadQueueService(
        database: database,
        driveService: DriveService(),
        authService: auth,
      );

      await database.upsertPatients([
        Patient(
          id: 'test-uuid-1',
          name: 'Existing Patient',
          source: PatientSource.doctorCreated,
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: PatientsScreen(
            authService: auth,
            configService: configService,
            sheetsService: sheetsService,
            database: database,
            queueService: queueService,
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('Existing Patient'), findsOneWidget);

      // Trigger pull to refresh gesture
      await tester.fling(find.text('Existing Patient'), const Offset(0, 300), 1000);
      await tester.pump(); // Starts refresh animation
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      // The RefreshIndicator spinner should be dismissed
      expect(find.byType(RefreshProgressIndicator), findsNothing);
    });
  });
}
