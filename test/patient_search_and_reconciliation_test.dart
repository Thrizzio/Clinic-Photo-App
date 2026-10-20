import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;

import 'package:clinic_photos/models/clinic_config.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/patient_folder_service.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/widgets/new_patient_dialog.dart';

class FakeAuthClient extends http.BaseClient implements AuthClient {
  @override
  AccessCredentials get credentials => AccessCredentials(
        AccessToken('Bearer', 'fake_token', DateTime.now().toUtc().add(const Duration(hours: 1))),
        'refresh_token',
        ['https://www.googleapis.com/auth/drive'],
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}

class FakeGoogleAuthService implements GoogleAuthService {
  final AuthClient client = FakeAuthClient();

  @override
  Future<AuthClient?> getAuthenticatedClient() async => client;

  @override
  Future<AuthClient?> getAuthenticatedClientSilently() async => client;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeConfigService implements ConfigService {
  @override
  ClinicConfig loadConfig() {
    return const ClinicConfig(
      spreadsheetId: 'fake_spreadsheet',
      spreadsheetUrl: 'https://docs.google.com/spreadsheets/d/fake',
      sheetTabName: 'Patients',
      parentDriveFolderId: 'parent_folder_123',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSheetsService implements SheetsService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeDriveServiceWithPhoneDiscovery extends DriveService {
  final List<drive.File> existingFolders = [];

  @override
  Future<List<drive.File>> findFoldersByName({
    required AuthClient client,
    required String parentFolderId,
    required String folderName,
  }) async {
    return existingFolders.where((f) => f.name == folderName).toList();
  }

  @override
  Future<List<drive.File>> findFoldersByPartialName({
    required AuthClient client,
    required String parentFolderId,
    required String queryPart,
  }) async {
    return existingFolders.where((f) => f.name != null && f.name!.contains(queryPart)).toList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final rajaniPatient = Patient(
    id: 'rajani-uuid-1234',
    displayName: 'Rajani Suttati',
    phoneDisplay: '9422301089',
    normalizedPhone: '9422301089',
    legacyPatientId: '2000144',
    source: PatientSource.clinicSheet,
    folderStatus: FolderStatus.missing,
  );

  group('Patient Search & Vowel Tolerance Tests', () {
    test('Patient.matchesSearchQuery matches exact substring', () {
      expect(rajaniPatient.matchesSearchQuery('Rajani'), isTrue);
      expect(rajaniPatient.matchesSearchQuery('Suttati'), isTrue);
      expect(rajaniPatient.matchesSearchQuery('9422301089'), isTrue);
    });

    test('Patient.matchesSearchQuery matches vowel-dropped variations (Rajni -> Rajani)', () {
      expect(rajaniPatient.matchesSearchQuery('Rajni'), isTrue);
      expect(rajaniPatient.matchesSearchQuery('rajni'), isTrue);
    });

    test('InMemoryAppDatabase.searchPatients finds Rajani when query is Rajni', () async {
      final db = AppDatabase.inMemory(initialPatients: {rajaniPatient.id: rajaniPatient});
      final results = await db.searchPatients('Rajni');
      expect(results.length, equals(1));
      expect(results.first.displayName, equals('Rajani Suttati'));
      expect(results.first.id, equals(rajaniPatient.id));
    });

    test('getPatientByNormalizedPhone retrieves patient by phone', () async {
      final db = AppDatabase.inMemory(initialPatients: {rajaniPatient.id: rajaniPatient});
      final found = await db.getPatientByNormalizedPhone('9422301089');
      expect(found, isNotNull);
      expect(found!.id, equals(rajaniPatient.id));
      expect(found.displayName, equals('Rajani Suttati'));
    });
  });

  group('Phone-Based Drive Folder Discovery Tests', () {
    test('discovers existing Drive folder "Rajni Suttati - 9422301089" for patient "Rajani Suttati"', () async {
      final db = AppDatabase.inMemory(initialPatients: {rajaniPatient.id: rajaniPatient});
      final fakeDrive = FakeDriveServiceWithPhoneDiscovery();
      // On Drive, the folder was named without the middle 'a'
      fakeDrive.existingFolders.add(
        drive.File(
          id: 'drive_folder_rajni_suttati_id',
          name: 'Rajni Suttati - 9422301089',
          parents: ['parent_folder_123'],
        ),
      );

      final folderService = PatientFolderService(
        driveService: fakeDrive,
        sheetsService: FakeSheetsService(),
        database: db,
        configService: FakeConfigService(),
        authService: FakeGoogleAuthService(),
      );

      final discovered = await folderService.discoverExistingPatientFolder(rajaniPatient);
      expect(discovered, isNotNull);
      expect(discovered!.driveFolderId, equals('drive_folder_rajni_suttati_id'));
      expect(discovered.folderStatus, equals(FolderStatus.available));

      final persistedInDb = await db.getPatient(rajaniPatient.id);
      expect(persistedInDb?.driveFolderId, equals('drive_folder_rajni_suttati_id'));
      expect(persistedInDb?.folderStatus, equals(FolderStatus.available));
    });
  });

  group('NewPatientDialog Phone Deduplication Widget Tests', () {
    testWidgets('Entering existing patient phone prompts to open existing patient', (tester) async {
      final db = AppDatabase.inMemory(initialPatients: {rajaniPatient.id: rajaniPatient});

      Patient? selectedResult;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () async {
                  selectedResult = await NewPatientDialog.show(
                    ctx,
                    database: db,
                    initialName: 'Rajni Suttati',
                    initialPhone: '9422301089',
                  );
                },
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      expect(find.text('New Patient'), findsOneWidget);

      // Tap Create Patient
      await tester.tap(find.text('Create Patient'));
      await tester.pumpAndSettle();

      // Should show Patient Already Exists dialog
      expect(find.text('Patient Already Exists'), findsOneWidget);
      expect(find.textContaining('Rajani Suttati'), findsOneWidget);

      // Tap Open Patient
      await tester.tap(find.text('Open Patient'));
      await tester.pumpAndSettle();

      expect(selectedResult, isNotNull);
      expect(selectedResult!.id, equals(rajaniPatient.id));
      expect(selectedResult!.displayName, equals('Rajani Suttati'));
    });
  });
}
