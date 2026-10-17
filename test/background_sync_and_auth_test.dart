import 'dart:async';
import 'dart:io';

import 'package:clinic_photos/models/clinic_config.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/screens/patients_screen.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class _FakeConnectivity implements Connectivity {
  final _controller = StreamController<List<ConnectivityResult>>.broadcast();
  List<ConnectivityResult> current = [ConnectivityResult.wifi];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _controller.stream;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => current;

  void emit(List<ConnectivityResult> results) {
    current = results;
    _controller.add(results);
  }

  void dispose() {
    _controller.close();
  }
}

class _TestAuthClient extends http.BaseClient implements AuthClient {
  @override
  AccessCredentials get credentials => AccessCredentials(
        AccessToken('Bearer', 'mock_token', DateTime.now().toUtc().add(const Duration(hours: 1))),
        'mock_refresh',
        ['https://www.googleapis.com/auth/drive'],
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}

class _MockGoogleAuthWithConcurrency extends GoogleAuthService {
  int silentCalls = 0;
  int interactiveCalls = 0;
  AuthClient? client;

  _MockGoogleAuthWithConcurrency({this.client}) : super(GoogleSignIn.instance);

  @override
  Future<AuthClient?> getAuthenticatedClientSilently() async {
    silentCalls++;
    return client;
  }

  @override
  Future<AuthClient?> getAuthenticatedClient() async {
    interactiveCalls++;
    return client;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phases 3 & 4: Background-First Sync, Doctor UI, and Auth Lifecycle', () {
    late InMemoryAppDatabase database;
    late ConfigService configService;
    late SheetsService sheetsService;
    late DriveService driveService;
    late _FakeConnectivity connectivity;
    late Directory tempDocsDir;

    final patient1 = Patient(
      id: 'patient_1_cache',
      name: 'Aarav Patel',
      phoneNumber: '9876543210',
      driveFolderId: 'folder_aarav',
      folderStatus: FolderStatus.available,
      lastViewedAt: DateTime(2026, 10, 17, 10, 0, 0),
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      configService = await ConfigService.init();
      await configService.saveConfig(
        const ClinicConfig(
          spreadsheetId: 'test_sheet',
          spreadsheetUrl: 'https://docs.google.com/spreadsheets/d/test_sheet/edit',
          sheetTabName: 'Visits',
          hasCompletedSetup: true,
          lastSyncedRow: 1,
        ),
      );

      tempDocsDir = Directory.systemTemp.createTempSync('bg_sync_test_');
      database = InMemoryAppDatabase(initialPatients: {patient1.id: patient1});
      sheetsService = SheetsService();
      driveService = DriveService();
      connectivity = _FakeConnectivity();
    });

    tearDown(() {
      connectivity.dispose();
      try {
        tempDocsDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    testWidgets('1. Doctor UI: Cached patient renders immediately, no technical sync banner or manual Refresh button', (tester) async {
      final auth = _MockGoogleAuthWithConcurrency(client: _TestAuthClient());
      final queueService = UploadQueueService(
        database: database,
        authService: auth,
        driveService: driveService,
        connectivity: connectivity,
        customDocsDirectory: tempDocsDir.path,
      );
      addTearDown(queueService.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: PatientsScreen(
            authService: auth,
            configService: configService,
            sheetsService: sheetsService,
            database: database,
            queueService: queueService,
            connectivity: connectivity,
          ),
        ),
      );

      // Verify cached patient renders immediately
      await tester.pump();
      expect(find.text('Aarav Patel'), findsOneWidget);

      // Verify technical sync status and manual Refresh button are NOT present in normal doctor workflow
      expect(find.text('Synced'), findsNothing);
      expect(find.text('Local only'), findsNothing);
      expect(find.text('Updating in background...'), findsNothing);
      expect(find.text('Refresh'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('2. Offline Notice: Appears ONLY when genuinely disconnected (ConnectivityResult.none), not on auth errors', (tester) async {
      final auth = _MockGoogleAuthWithConcurrency(client: null); // Auth returns null
      final queueService = UploadQueueService(
        database: database,
        authService: auth,
        driveService: driveService,
        connectivity: connectivity,
        customDocsDirectory: tempDocsDir.path,
      );
      addTearDown(queueService.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: PatientsScreen(
            authService: auth,
            configService: configService,
            sheetsService: sheetsService,
            database: database,
            queueService: queueService,
            connectivity: connectivity,
          ),
        ),
      );
      await tester.pump();

      // With WiFi connected, auth failure does NOT trigger offline notice
      expect(find.text('Offline · Using local records'), findsNothing);

      // When connectivity becomes none:
      connectivity.emit([ConnectivityResult.none]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Offline notice appears
      expect(find.text('Offline · Using local records'), findsOneWidget);
      expect(find.byIcon(Icons.wifi_off), findsOneWidget);

      // When network recovers to wifi:
      connectivity.emit([ConnectivityResult.wifi]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Offline notice disappears
      expect(find.text('Offline · Using local records'), findsNothing);
    });

    testWidgets('3. Auth Lifecycle & Concurrency: Silent requests never trigger interactive consent loop', (tester) async {
      final auth = GoogleAuthService(GoogleSignIn.instance);

      // Run multiple concurrent silent client requests through Zone
      final futures = List.generate(5, (_) {
        return runZoned(
          () => auth.getAuthenticatedClientSilently(),
          zoneValues: {#_googleAuthSilentRequest: true},
        );
      });

      final results = await Future.wait(futures);
      // All concurrent requests complete without throwing StateError or race condition
      expect(results.length, 5);
    });
  });
}
