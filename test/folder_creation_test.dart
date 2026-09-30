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

class FakeAuthClient extends http.BaseClient implements AuthClient {
  @override
  AccessCredentials get credentials => AccessCredentials(
        AccessToken('Bearer', 'fake_token', DateTime.now().toUtc().add(const Duration(hours: 1))),
        'fake_refresh_token',
        ['https://www.googleapis.com/auth/drive'],
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}

class MockDriveService extends DriveService {
  final Map<String, List<drive.File>> parentFolders = {};
  int createFolderCalls = 0;
  String? createdFolderIdToReturn;

  @override
  Future<List<drive.File>> findFoldersByName({
    required AuthClient client,
    required String parentFolderId,
    required String folderName,
  }) async {
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
    final folderId = createdFolderIdToReturn ?? 'new_folder_${createFolderCalls}_123';
    final newFile = drive.File()
      ..id = folderId
      ..name = folderName;
    parentFolders.putIfAbsent(parentFolderId, () => []).add(newFile);
    return folderId;
  }
}

class MockSheetsService extends SheetsService {
  String? lastWrittenRange;
  String? lastWrittenUrl;
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
    lastWrittenUrl = folderUrl;
    lastWrittenRange = '$sheetName!O9'; // standard test mock range
    return 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Folder Creation Tests (Section 23.1)', () {
    late ConfigService configService;
    late InMemoryAppDatabase database;
    late MockDriveService mockDrive;
    late MockSheetsService mockSheets;
    late GoogleAuthService authService;
    late PatientFolderService folderService;
    late FakeAuthClient fakeClient;

    const parentFolderId = 'parent_drive_folder_root';

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      configService = await ConfigService.init();
      await configService.saveConfig(const ClinicConfig(
        spreadsheetId: 'sheet_clinic_test',
        spreadsheetUrl: 'https://docs.google.com/spreadsheets/d/sheet_clinic_test/edit',
        sheetTabName: 'Visits',
        parentDriveFolderId: parentFolderId,
        hasCompletedSetup: true,
      ));

      database = InMemoryAppDatabase();
      mockDrive = MockDriveService();
      mockSheets = MockSheetsService();
      authService = GoogleAuthService();
      fakeClient = FakeAuthClient();

      folderService = PatientFolderService(
        driveService: mockDrive,
        sheetsService: mockSheets,
        database: database,
        configService: configService,
        authService: authService,
      );
    });

    test('1. Idempotent get-or-create: Calling twice returns same folder ID without creating duplicate', () async {
      const patient = Patient(
        id: 'P001',
        name: 'John Doe',
        folderStatus: FolderStatus.missing,
      );
      await database.upsertPatients([patient]);

      // Call 1: Creates new folder
      final result1 = await folderService.getOrCreatePatientFolder(
        patient,
        clientOverride: fakeClient,
      );
      expect(result1.createdNew, isTrue);
      expect(result1.driveFolderId, isNotEmpty);
      expect(mockDrive.createFolderCalls, 1);

      // Call 2: Second call with patient bearing the new folder ID
      final result2 = await folderService.getOrCreatePatientFolder(
        result1.patient,
        clientOverride: fakeClient,
      );
      expect(result2.createdNew, isFalse);
      expect(result2.driveFolderId, result1.driveFolderId);
      expect(mockDrive.createFolderCalls, 1); // No new folder created
    });

    test('2. Single match reuse: When matching folder exists, reuses it without creating new one', () async {
      const patient = Patient(
        id: 'P002',
        name: 'Jane Smith',
        folderStatus: FolderStatus.missing,
      );
      await database.upsertPatients([patient]);

      // Pre-seed matching folder in Drive parent
      mockDrive.parentFolders[parentFolderId] = [
        drive.File()
          ..id = 'existing_folder_p002'
          ..name = 'P002 - Jane Smith',
      ];

      final result = await folderService.getOrCreatePatientFolder(
        patient,
        clientOverride: fakeClient,
      );

      expect(result.createdNew, isFalse);
      expect(result.driveFolderId, 'existing_folder_p002');
      expect(mockDrive.createFolderCalls, 0); // Reused, zero creates
      expect(result.patient.isUploadable, isTrue);
    });

    test('3. Zero match create: Creates folder, persists ID, and writes URL to Sheet', () async {
      const patient = Patient(
        id: 'P003',
        name: 'Alice Brown',
        folderStatus: FolderStatus.missing,
      );
      await database.upsertPatients([patient]);

      final result = await folderService.getOrCreatePatientFolder(
        patient,
        clientOverride: fakeClient,
      );

      expect(result.createdNew, isTrue);
      expect(mockDrive.createFolderCalls, 1);
      expect(result.patient.folderStatus, FolderStatus.available);

      // V4: Never write folder URL back to Google Sheets (Sheets is read-only)
      expect(mockSheets.lastWrittenUrl, isNull);

      // Verifies saved locally in SQLite
      final inDb = await database.getPatient('P003');
      expect(inDb?.driveFolderId, result.driveFolderId);
      expect(inDb?.folderStatus, FolderStatus.available);
    });

    test('4. Multiple match conflict: Flags conflict and refuses upload when duplicate folders exist', () async {
      const patient = Patient(
        id: 'P004',
        name: 'Bob Duplicate',
        folderStatus: FolderStatus.missing,
      );
      await database.upsertPatients([patient]);

      // Pre-seed two folders with exact same name
      mockDrive.parentFolders[parentFolderId] = [
        drive.File()..id = 'dup_folder_1'..name = 'P004 - Bob Duplicate',
        drive.File()..id = 'dup_folder_2'..name = 'P004 - Bob Duplicate',
      ];

      await expectLater(
        () => folderService.getOrCreatePatientFolder(patient, clientOverride: fakeClient),
        throwsA(isA<ConflictFolderException>()),
      );

      // Verifies patient flagged as conflict in database
      final inDb = await database.getPatient('P004');
      expect(inDb?.folderStatus, FolderStatus.conflict);
      expect(inDb?.driveFolderId, isNull);
    });

    test('5. Sheet writeback: Calculates correct A1 notation for column index', () {
      expect(SheetsService.columnIndexToA1Notation(0), 'A');
      expect(SheetsService.columnIndexToA1Notation(1), 'B');
      expect(SheetsService.columnIndexToA1Notation(14), 'O');
      expect(SheetsService.columnIndexToA1Notation(25), 'Z');
      expect(SheetsService.columnIndexToA1Notation(26), 'AA');
      expect(SheetsService.columnIndexToA1Notation(27), 'AB');
    });

    test('6. Read-only fallback: If Sheet write fails, folder ID is still saved locally', () async {
      mockSheets.shouldThrowOnWrite = true;

      const patient = Patient(
        id: 'P005',
        name: 'Charlie Readonly',
        folderStatus: FolderStatus.missing,
      );
      await database.upsertPatients([patient]);

      final result = await folderService.getOrCreatePatientFolder(
        patient,
        clientOverride: fakeClient,
      );

      // Folder creation still succeeds locally
      expect(result.driveFolderId, isNotEmpty);
      expect(result.patient.isUploadable, isTrue);

      final inDb = await database.getPatient('P005');
      expect(inDb?.driveFolderId, result.driveFolderId);
      expect(inDb?.folderStatus, FolderStatus.available);
    });

    test('7. Offline handling: Throws StateError when account is not authenticated', () async {
      const patient = Patient(
        id: 'P006',
        name: 'Offline Patient',
        folderStatus: FolderStatus.missing,
      );

      await expectLater(
        () => folderService.getOrCreatePatientFolder(patient, clientOverride: null),
        throwsA(isA<StateError>()),
      );
    });
  });
}
