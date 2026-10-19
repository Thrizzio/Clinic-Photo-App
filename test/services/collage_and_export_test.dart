import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:clinic_photos/models/clinic_config.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/collage_service.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/patient_folder_service.dart';
import 'package:clinic_photos/services/sheets.dart';

Uint8List _createDummyJpeg(int width, int height, img.ColorRgb8 color) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: color);
  return Uint8List.fromList(img.encodeJpg(image, quality: 85));
}

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

class FakeDriveService extends DriveService {
  final Map<String, List<drive.File>> foldersByName = {};

  @override
  Future<List<drive.File>> findFoldersByName({
    required AuthClient client,
    required String parentFolderId,
    required String folderName,
  }) async {
    final key = '$parentFolderId:$folderName';
    return foldersByName[key] ?? [];
  }
}

class FakeSheetsService implements SheetsService {
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

class FakeDatabase implements AppDatabase {
  final Map<String, Patient> patients = {};

  @override
  Future<int> updatePatient(Patient patient) async {
    patients[patient.id] = patient;
    return 1;
  }

  @override
  Future<Patient?> getPatient(String id) async => patients[id];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('collage_test_');
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('CollageService Unit Tests', () {
    test('enforces between 2 and 6 images', () async {
      final service = CollageService();
      final oneItem = [CollageItem(bytes: _createDummyJpeg(100, 100, img.ColorRgb8(255, 0, 0)))];

      expect(
        () => service.createCollage(items: oneItem, outputDirectory: tempDir),
        throwsA(isA<ArgumentError>()),
      );

      final sevenItems = List.generate(
        7,
        (i) => CollageItem(bytes: _createDummyJpeg(50, 50, img.ColorRgb8(i * 30, 0, 0))),
      );
      expect(
        () => service.createCollage(items: sevenItems, outputDirectory: tempDir),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('creates 2-image horizontal comparison collage', () async {
      final service = CollageService(targetMaxDimension: 1000, gapSize: 8);
      final items = [
        CollageItem(bytes: _createDummyJpeg(300, 400, img.ColorRgb8(255, 0, 0))), // Red
        CollageItem(bytes: _createDummyJpeg(300, 400, img.ColorRgb8(0, 0, 255))), // Blue
      ];

      final result = await service.createCollage(
        items: items,
        layout: CollageLayout.horizontalComparison,
        outputDirectory: tempDir,
      );

      expect(result.bytes, isNotEmpty);
      expect(File(result.filePath).existsSync(), isTrue);
      expect(result.height, greaterThanOrEqualTo(600));
      expect(result.width, greaterThan(result.height)); // Horizontal side-by-side is wider than height

      final decoded = img.decodeImage(result.bytes);
      expect(decoded, isNotNull);
      expect(decoded!.width, result.width);
      expect(decoded.height, result.height);
    });

    test('creates 3-image balanced collage', () async {
      final service = CollageService(targetMaxDimension: 1000, gapSize: 8);
      final items = [
        CollageItem(bytes: _createDummyJpeg(200, 300, img.ColorRgb8(255, 0, 0))),
        CollageItem(bytes: _createDummyJpeg(200, 300, img.ColorRgb8(0, 255, 0))),
        CollageItem(bytes: _createDummyJpeg(200, 300, img.ColorRgb8(0, 0, 255))),
      ];

      final result = await service.createCollage(items: items, outputDirectory: tempDir);
      expect(result.bytes, isNotEmpty);
      expect(File(result.filePath).existsSync(), isTrue);
    });

    test('creates 4-image 2x2 grid collage', () async {
      final service = CollageService(targetMaxDimension: 1000, gapSize: 8);
      final items = List.generate(
        4,
        (i) => CollageItem(bytes: _createDummyJpeg(200, 200, img.ColorRgb8(i * 50, 50, 50))),
      );

      final result = await service.createCollage(items: items, outputDirectory: tempDir);
      expect(result.bytes, isNotEmpty);
      expect(File(result.filePath).existsSync(), isTrue);
    });

    test('creates 6-image 2x3 grid collage', () async {
      final service = CollageService(targetMaxDimension: 1200, gapSize: 8);
      final items = List.generate(
        6,
        (i) => CollageItem(bytes: _createDummyJpeg(150, 200, img.ColorRgb8(i * 40, 20, 20))),
      );

      final result = await service.createCollage(items: items, outputDirectory: tempDir);
      expect(result.bytes, isNotEmpty);
      expect(File(result.filePath).existsSync(), isTrue);
    });
  });

  group('PatientFolderService.discoverExistingPatientFolder Unit Tests', () {
    late FakeDriveService fakeDriveService;
    late FakeGoogleAuthService fakeAuthService;
    late FakeConfigService fakeConfigService;
    late FakeDatabase fakeDb;
    late PatientFolderService folderService;

    setUp(() {
      fakeDriveService = FakeDriveService();
      fakeAuthService = FakeGoogleAuthService();
      fakeConfigService = FakeConfigService();
      fakeDb = FakeDatabase();

      folderService = PatientFolderService(
        authService: fakeAuthService,
        driveService: fakeDriveService,
        sheetsService: FakeSheetsService(),
        configService: fakeConfigService,
        database: fakeDb,
      );
    });

    test('discovers canonical folder directly under parent', () async {
      final patient = Patient(
        id: 'patient_uuid_1',
        displayName: 'Harshad Chavan',
        phoneDisplay: '9011315385',
        driveFolderId: null,
      );

      // Setup Drive folder match: Harshad Chavan - 9011315385
      fakeDriveService.foldersByName['parent_folder_123:Harshad Chavan - 9011315385'] = [
        drive.File(id: 'drive_folder_harshad', name: 'Harshad Chavan - 9011315385'),
      ];

      final discovered = await folderService.discoverExistingPatientFolder(patient);

      expect(discovered, isNotNull);
      expect(discovered!.driveFolderId, 'drive_folder_harshad');
      expect(discovered.folderStatus, FolderStatus.available);
      expect(fakeDb.patients['patient_uuid_1']?.driveFolderId, 'drive_folder_harshad');
    });

    test('discovers canonical folder nested under Patient_Photos subfolder', () async {
      final patient = Patient(
        id: 'patient_uuid_2',
        displayName: 'Harshad Chavan',
        phoneDisplay: '9011315385',
        driveFolderId: null,
      );

      // Parent contains Patient_Photos subfolder
      fakeDriveService.foldersByName['parent_folder_123:Patient_Photos'] = [
        drive.File(id: 'subfolder_patient_photos', name: 'Patient_Photos'),
      ];
      // Patient_Photos contains Harshad Chavan - 9011315385
      fakeDriveService.foldersByName['subfolder_patient_photos:Harshad Chavan - 9011315385'] = [
        drive.File(id: 'drive_nested_folder_harshad', name: 'Harshad Chavan - 9011315385'),
      ];

      final discovered = await folderService.discoverExistingPatientFolder(patient);

      expect(discovered, isNotNull);
      expect(discovered!.driveFolderId, 'drive_nested_folder_harshad');
      expect(discovered.folderStatus, FolderStatus.available);
    });

    test('discovers legacy format folder <LegacyId> - <Patient Name>', () async {
      final patient = Patient(
        id: 'patient_uuid_3',
        legacyPatientId: '2000130',
        displayName: 'Harshad Chavan',
        phoneDisplay: '9011315385',
        driveFolderId: null,
      );

      // Setup legacy match
      fakeDriveService.foldersByName['parent_folder_123:2000130 - Harshad Chavan'] = [
        drive.File(id: 'drive_folder_legacy', name: '2000130 - Harshad Chavan'),
      ];

      final discovered = await folderService.discoverExistingPatientFolder(patient);

      expect(discovered, isNotNull);
      expect(discovered!.driveFolderId, 'drive_folder_legacy');
    });

    test('marks conflict when multiple matching folders are found', () async {
      final patient = Patient(
        id: 'patient_uuid_4',
        displayName: 'Duplicate Patient',
        phoneDisplay: '9999999999',
        driveFolderId: null,
      );

      fakeDriveService.foldersByName['parent_folder_123:Duplicate Patient - 9999999999'] = [
        drive.File(id: 'folder_1', name: 'Duplicate Patient - 9999999999'),
        drive.File(id: 'folder_2', name: 'Duplicate Patient - 9999999999'),
      ];

      final discovered = await folderService.discoverExistingPatientFolder(patient);

      expect(discovered, isNotNull);
      expect(discovered!.folderStatus, FolderStatus.conflict);
      expect(discovered.driveFolderId, isNull);
    });

    test('returns null when no matching folder is found without altering patient', () async {
      final patient = Patient(
        id: 'patient_uuid_5',
        displayName: 'Brand New Patient',
        phoneDisplay: '1234567890',
        driveFolderId: null,
      );

      final discovered = await folderService.discoverExistingPatientFolder(patient);

      expect(discovered, isNull);
      expect(fakeDb.patients.containsKey('patient_uuid_5'), isFalse);
    });
  });
}
