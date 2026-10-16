import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/screens/clinic_setup_screen.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('setup lists every worksheet and validates the selected worksheet', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final configService = await ConfigService.init();
    final database = InMemoryAppDatabase();
    final sheetsService = SelectionSheetsService(
      const ['Appointments', 'Patients', 'Visits'],
    );
    final authService = SetupAuthService();
    final queueService = UploadQueueService(
      database: database,
      authService: authService,
      driveService: DriveService(),
    );
    addTearDown(queueService.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ClinicSetupScreen(
          authService: authService,
          configService: configService,
          sheetsService: sheetsService,
          database: database,
          queueService: queueService,
        ),
      ),
    );

    await tester.enterText(
      find.byType(TextField),
      'https://docs.google.com/spreadsheets/d/sheet_id_12345678901234567890/edit',
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Appointments'), findsOneWidget);
    expect(find.text('Patients'), findsOneWidget);
    expect(find.text('Visits'), findsOneWidget);

    await tester.tap(find.text('Visits'));
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(sheetsService.validatedSheet, 'Visits');
    expect(find.text('Parent Drive Folder'), findsOneWidget);
  });
}

class SelectionSheetsService extends SheetsService {
  final List<String> _tabs;
  String? validatedSheet;

  SelectionSheetsService(this._tabs);

  @override
  Future<List<String>> fetchSheetTabs({
    required AuthClient client,
    required String spreadsheetId,
  }) async {
    return _tabs;
  }

  @override
  Future<SheetParseResult> validateAndFetchPatients({
    required AuthClient client,
    required String spreadsheetId,
    required String sheetName,
  }) async {
    validatedSheet = sheetName;
    return SheetParseResult(
      patients: [
        const Patient(
          id: 'sheet-patient',
          name: 'Selected Patient',
          source: PatientSource.clinicSheet,
        ),
      ],
      totalRows: 2,
      effectiveSheetName: sheetName,
    );
  }
}

class SetupAuthService extends GoogleAuthService {
  @override
  Future<AuthClient?> getAuthenticatedClient() async => SetupAuthClient();
}

class SetupAuthClient extends http.BaseClient implements AuthClient {
  @override
  AccessCredentials get credentials => AccessCredentials(
        AccessToken(
          'Bearer',
          'setup-test-token',
          DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
        null,
        const [],
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}
