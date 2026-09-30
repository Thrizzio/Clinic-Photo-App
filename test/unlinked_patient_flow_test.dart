import 'package:clinic_photos/models/clinic_config.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/patient_folder_service.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

class FakeAuthClient extends http.BaseClient implements AuthClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream.empty(), 200);
  }

  @override
  AccessCredentials get credentials => AccessCredentials(
        AccessToken('Bearer', 'fake_token', DateTime.now().toUtc().add(const Duration(hours: 1))),
        null,
        ['https://www.googleapis.com/auth/drive'],
      );
}

class FakeGoogleAuthService extends GoogleAuthService {
  AuthClient? client;
  FakeGoogleAuthService(this.client);

  @override
  Future<AuthClient?> getAuthenticatedClient() async => client;
}

class MockDriveService extends DriveService {
  final Map<String, List<drive.File>> parentFolders = {};
  int createFolderCalls = 0;
  int findFoldersCalls = 0;
  String? createdFolderIdToReturn;

  @override
  Future<List<drive.File>> findFoldersByName({
    required AuthClient client,
    required String parentFolderId,
    required String folderName,
  }) async {
    findFoldersCalls++;
    final list = parentFolders[parentFolderId] ?? [];
    return list.where((f) => f.name == folderName).toList();
  }

  @override
  Future<String> createFolder({
    required AuthClient client,
    required String parentFolderId,
    required String folderName,
  }) async {
    createFolderCalls++;
    final folderId = createdFolderIdToReturn ?? 'new_folder_${createFolderCalls}_999';
    final newFile = drive.File()
      ..id = folderId
      ..name = folderName;
    parentFolders.putIfAbsent(parentFolderId, () => []).add(newFile);
    return folderId;
  }
}

class MockSheetsService extends SheetsService {
  final List<String> writtenUrls = [];
  final List<String> writtenPatientIds = [];
  bool shouldThrowOnWrite = false;

  @override
  Future<int> writePatientFolderUrl({
    required AuthClient client,
    required String spreadsheetId,
    required String sheetName,
    required String patientId,
    required String folderUrl,
    HeaderIndices? headerIndices,
  }) async {
    if (shouldThrowOnWrite) {
      throw Exception('Read-only permissions: cannot update sheet cell');
    }
    writtenUrls.add(folderUrl);
    writtenPatientIds.add(patientId);
    return 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Unlinked Patients & Lazy Folder Creation Regression Tests', () {
    late ConfigService configService;
    late InMemoryAppDatabase database;
    late MockDriveService mockDrive;
    late MockSheetsService mockSheets;
    late FakeAuthClient fakeClient;
    late FakeGoogleAuthService fakeAuth;
    late PatientFolderService folderService;

    const parentFolderId = 'parent_root_123';

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      configService = await ConfigService.init();
      await configService.saveConfig(const ClinicConfig(
        spreadsheetId: 'test_sheet_123',
        spreadsheetUrl: 'https://docs.google.com/spreadsheets/d/test_sheet_123/edit',
        sheetTabName: 'Visits',
        parentDriveFolderId: parentFolderId,
        hasCompletedSetup: true,
      ));

      database = InMemoryAppDatabase();
      mockDrive = MockDriveService();
      mockSheets = MockSheetsService();
      fakeClient = FakeAuthClient();
      fakeAuth = FakeGoogleAuthService(fakeClient);

      folderService = PatientFolderService(
        database: database,
        driveService: mockDrive,
        sheetsService: mockSheets,
        authService: fakeAuth,
        configService: configService,
      );
    });

    test('1. Patient model supports valid intermediate states (linked vs unlinked)', () {
      // Patient with existing folder ID
      const linked = Patient(
        id: '1000001',
        name: 'Anil Jain',
        driveFolderId: 'folder_anil_123',
        folderStatus: FolderStatus.available,
      );
      expect(linked.driveFolderId, 'folder_anil_123');
      expect(linked.folderStatus, FolderStatus.available);
      expect(linked.isUploadable, isTrue);

      // Patient with NO folder: intermediate state
      const unlinked = Patient(
        id: '1000002',
        name: 'Sunita Sharma',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );
      expect(unlinked.driveFolderId, isNull);
      expect(unlinked.folderStatus, FolderStatus.missing);
      expect(unlinked.isUploadable, isFalse);

      // Serialization and deserialization preserves null driveFolderId
      final map = unlinked.toMap();
      expect(map['drive_folder_id'], isNull);
      expect(map['folder_status'], 'missing');

      final fromMap = Patient.fromMap(map);
      expect(fromMap.id, '1000002');
      expect(fromMap.name, 'Sunita Sharma');
      expect(fromMap.driveFolderId, isNull);
      expect(fromMap.folderStatus, FolderStatus.missing);
    });

    test('2. Initial sync of 65 unlinked patients succeeds with zero Drive folder creation', () async {
      // Simulate reading 65 patient rows from Google Sheets without Drive links
      final rows = <List<dynamic>>[
        ['Patient ID', 'Patient Name', 'Photos (Drive)'],
      ];
      for (int i = 1; i <= 65; i++) {
        final id = (1000000 + i).toString();
        rows.add([id, 'Patient $i', '']); // Blank Photos (Drive) column
      }

      final headerIndices = SheetsService.discoverHeaderIndices(rows);
      final resolved = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );

      expect(resolved.length, 65);
      for (final p in resolved.values) {
        expect(p.driveFolderId, isNull);
        expect(p.folderStatus, FolderStatus.missing);
      }

      // Initial sync saves all 65 patients to SQLite cache
      await database.replacePatients(resolved.values.toList());

      final cached = await database.getPatients();
      expect(cached.length, 65);
      expect(cached.every((p) => p.driveFolderId == null), isTrue);
      expect(cached.every((p) => p.folderStatus == FolderStatus.missing), isTrue);

      // CRITICAL: Absolutely ZERO Drive API calls or folder creations occur during initial sync
      expect(mockDrive.createFolderCalls, 0);
      expect(mockDrive.findFoldersCalls, 0);
    });

    test('3. Lazy creation: getOrCreatePatientFolder creates folder only on demand when needed', () async {
      const patient = Patient(
        id: '1000005',
        name: 'Rajesh Verma',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );
      await database.replacePatients([patient]);

      expect(mockDrive.createFolderCalls, 0);

      // Clinician captures photos: resolves/creates folder on demand
      final result = await folderService.getOrCreatePatientFolder(patient);

      expect(result.createdNew, isTrue);
      expect(result.driveFolderId, isNotEmpty);
      expect(result.patient.folderStatus, FolderStatus.available);
      expect(mockDrive.createFolderCalls, 1);

      // Newly created folder ID is persisted in database
      final inDb = await database.getPatient('1000005');
      expect(inDb?.driveFolderId, result.driveFolderId);
      expect(inDb?.folderStatus, FolderStatus.available);

      // V4: Never write folder URL back to Google Sheets (Sheets is strictly read-only)
      expect(mockSheets.writtenUrls.isEmpty, isTrue);
    });

    test('4. Existing folder is reused without creating a duplicate', () async {
      const patient = Patient(
        id: '1000006',
        name: 'Meena Kumari',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );
      await database.replacePatients([patient]);

      // An existing folder already exists in the configured parent folder
      mockDrive.parentFolders[parentFolderId] = [
        drive.File()
          ..id = 'existing_meena_folder_888'
          ..name = '1000006 - Meena Kumari',
      ];

      final result = await folderService.getOrCreatePatientFolder(patient);

      expect(result.createdNew, isFalse);
      expect(result.driveFolderId, 'existing_meena_folder_888');
      expect(mockDrive.createFolderCalls, 0); // No new folder created

      final inDb = await database.getPatient('1000006');
      expect(inDb?.driveFolderId, 'existing_meena_folder_888');
      expect(inDb?.folderStatus, FolderStatus.available);
    });

    test('5. Duplicate matching folders produce conflict and refuse upload', () async {
      const patient = Patient(
        id: '1000007',
        name: 'Duplicate Patient',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );
      await database.replacePatients([patient]);

      mockDrive.parentFolders[parentFolderId] = [
        drive.File()..id = 'dup_1'..name = '1000007 - Duplicate Patient',
        drive.File()..id = 'dup_2'..name = '1000007 - Duplicate Patient',
      ];

      await expectLater(
        () => folderService.getOrCreatePatientFolder(patient),
        throwsA(isA<ConflictFolderException>()),
      );

      final inDb = await database.getPatient('1000007');
      expect(inDb?.folderStatus, FolderStatus.conflict);
      expect(inDb?.driveFolderId, isNull);
    });

    test('6. Failed folder creation does not lose patient data', () async {
      const patient = Patient(
        id: '1000008',
        name: 'Network Error Patient',
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );
      await database.replacePatients([patient]);

      // Offline / unauthenticated
      fakeAuth.client = null;
      await expectLater(
        () => folderService.getOrCreatePatientFolder(patient),
        throwsA(isA<StateError>()),
      );

      // Patient data remains intact in SQLite
      final inDb = await database.getPatient('1000008');
      expect(inDb, isNotNull);
      expect(inDb?.name, 'Network Error Patient');
      expect(inDb?.folderStatus, FolderStatus.missing);
    });
  });

  group('SQLite Database Schema Migration Unit Tests', () {
    test('1. Migration triggers when patients table has NOT NULL drive_folder_id', () async {
      // Represents legacy table schema where drive_folder_id has notnull == 1
      final legacyTableInfo = <Map<String, Object?>>[
        {'cid': 0, 'name': 'id', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 1},
        {'cid': 1, 'name': 'name', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
        {'cid': 2, 'name': 'drive_folder_id', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
        {'cid': 3, 'name': 'folder_status', 'type': 'TEXT', 'notnull': 1, 'dflt_value': "'available'", 'pk': 0},
      ];

      final fakeDb = FakeMigrationDatabase(legacyTableInfo);

      await SqliteAppDatabase.ensurePatientsTableSchemaForTesting(fakeDb);

      // Verify table migration was executed
      expect(fakeDb.executedStatements.any((s) => s.contains('ALTER TABLE patients RENAME TO _patients_old')), isTrue);
      expect(fakeDb.executedStatements.any((s) => s.contains('CREATE TABLE patients')), isTrue);
      expect(fakeDb.executedStatements.any((s) => s.contains('INSERT INTO patients')), isTrue);
      expect(fakeDb.executedStatements.any((s) => s.contains('DROP TABLE _patients_old')), isTrue);
      expect(fakeDb.executedStatements.any((s) => s.contains('CREATE INDEX IF NOT EXISTS idx_patients_status')), isTrue);
    });

    test('2. Migration is a NO-OP when table has modern schema with nullable drive_folder_id and phone columns', () async {
      // Modern table schema where drive_folder_id has notnull == 0 and phone columns exist
      final modernTableInfo = <Map<String, Object?>>[
        {'cid': 0, 'name': 'id', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 1},
        {'cid': 1, 'name': 'name', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
        {'cid': 2, 'name': 'phone_number', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
        {'cid': 3, 'name': 'phone_number_normalized', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
        {'cid': 4, 'name': 'drive_folder_id', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
        {'cid': 5, 'name': 'folder_status', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
        {'cid': 6, 'name': 'updated_at', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
      ];

      final fakeDb = FakeMigrationDatabase(modernTableInfo);

      await SqliteAppDatabase.ensurePatientsTableSchemaForTesting(fakeDb);

      // Only PRAGMA was queried, no transaction or table rewrite occurred
      expect(fakeDb.executedStatements.any((s) => s.contains('ALTER TABLE patients RENAME')), isFalse);
    });

    test('3. Migration triggers when patients table is missing phone_number columns (v5 -> v6)', () async {
      // V5 table info (missing phone_number and phone_number_normalized)
      final v5TableInfo = <Map<String, Object?>>[
        {'cid': 0, 'name': 'id', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 1},
        {'cid': 1, 'name': 'name', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
        {'cid': 2, 'name': 'drive_folder_id', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
        {'cid': 3, 'name': 'folder_status', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
        {'cid': 4, 'name': 'updated_at', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
      ];

      final fakeDb = FakeMigrationDatabase(v5TableInfo);

      await SqliteAppDatabase.ensurePatientsTableSchemaForTesting(fakeDb);

      expect(fakeDb.executedStatements.any((s) => s.contains('ALTER TABLE patients RENAME TO _patients_old')), isTrue);
      expect(fakeDb.executedStatements.any((s) => s.contains('phone_number TEXT')), isTrue);
      expect(fakeDb.executedStatements.any((s) => s.contains('phone_number_normalized TEXT')), isTrue);
      expect(fakeDb.executedStatements.any((s) => s.contains('CREATE INDEX IF NOT EXISTS idx_patients_search')), isTrue);
    });
  });
}

class FakeMigrationDatabase extends Fake implements Database {
  final List<Map<String, Object?>> tableInfo;
  final List<String> executedStatements = [];

  FakeMigrationDatabase(this.tableInfo);

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {
    executedStatements.add(sql);
    if (sql.contains('PRAGMA table_info(patients)')) {
      return tableInfo;
    }
    return [];
  }

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action, {bool? exclusive}) async {
    final fakeTxn = FakeMigrationTransaction(executedStatements, tableInfo);
    return await action(fakeTxn);
  }
}

class FakeMigrationTransaction extends Fake implements Transaction {
  final List<String> executedStatements;
  final List<Map<String, Object?>> tableInfo;

  FakeMigrationTransaction(this.executedStatements, this.tableInfo);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    executedStatements.add(sql);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {
    executedStatements.add(sql);
    if (sql.contains('PRAGMA table_info(_patients_old)')) {
      return tableInfo;
    }
    return [];
  }
}
