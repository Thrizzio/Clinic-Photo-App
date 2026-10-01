import 'dart:io';
import 'package:clinic_photos/models/capture_session.dart';
import 'package:clinic_photos/models/clinic_config.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/screens/patients_screen.dart';
import 'package:clinic_photos/services/config_service.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/services/drive.dart';
import 'package:clinic_photos/services/google_auth.dart';
import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/services/upload_queue.dart';
import 'package:clinic_photos/widgets/patient_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // =========================================================================
  // 1. DATA REGRESSION TESTS
  // =========================================================================
  group('1. DATA regression tests', () {
    const headerIndices = HeaderIndices(
      idColIndex: 0,
      nameColIndex: 1,
      folderColIndex: 2,
      phoneColIndex: 3,
    );

    test('1.1 Sheets patient name is preserved', () {
      final rows = [
        ['Patient ID', 'Patient Name', 'Photos (Drive)', 'Phone Number'],
        ['1000001', 'Anil Jain', '', '+91 98765 43210'],
        ['1000002', 'Shilpa Kalbhor', '', '9876543211'],
        ['1000003', 'Pragati Waghaji', '', ''],
      ];

      final patients = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );

      expect(patients.length, 3);
      expect(patients['1000001']!.name, 'Anil Jain');
      expect(patients['1000002']!.name, 'Shilpa Kalbhor');
      expect(patients['1000003']!.name, 'Pragati Waghaji');
    });

    test('1.2 Patient name survives SQLite insert and 1.3 query', () async {
      final db = InMemoryAppDatabase();

      const patient = Patient(
        id: '1000001',
        name: 'Anil Jain',
        phoneNumber: '+91 98765 43210',
        phoneNumberNormalized: '9876543210',
        folderStatus: FolderStatus.missing,
      );

      await db.replacePatients([patient]);

      final retrieved = await db.getPatient('1000001');
      expect(retrieved, isNotNull);
      expect(retrieved!.id, '1000001');
      expect(retrieved.name, 'Anil Jain');
      expect(retrieved.displayName, 'Anil Jain');
      expect(retrieved.hasValidName, isTrue);

      final allPatients = await db.getPatients();
      expect(allPatients.length, 1);
      expect(allPatients.first.name, 'Anil Jain');
    });

    test('1.4 Patient name survives model mapping (toMap <-> fromMap)', () {
      const original = Patient(
        id: '1000001',
        name: 'Anil Jain',
        phoneNumber: '+91 98765 43210',
        phoneNumberNormalized: '9876543210',
        folderStatus: FolderStatus.missing,
      );

      final map = original.toMap();
      expect(map['id'], '1000001');
      expect(map['name'], 'Anil Jain');
      expect(map['phone_number'], '+91 98765 43210');
      expect(map['phone_number_normalized'], '9876543210');

      final reconstructed = Patient.fromMap(map);
      expect(reconstructed.id, original.id);
      expect(reconstructed.name, original.name);
      expect(reconstructed.phoneNumber, original.phoneNumber);
      expect(reconstructed.phoneNumberNormalized, original.phoneNumberNormalized);
      expect(reconstructed.displayName, 'Anil Jain');
    });

    test('1.5 Phone number is parsed from Sheets and cleaned of fake placeholders', () {
      final rows = [
        ['Patient ID', 'Patient Name', 'Photos (Drive)', 'Phone Number'],
        ['1000001', 'Anil Jain', '', '+91 98765 43210'],
        ['1000002', 'Shilpa Kalbhor', '', '0000000000'], // fake phone
        ['1000003', 'Pragati Waghaji', '', 'Unknown'], // fake phone
        ['1000004', 'Ovi Vanage', '', '-'], // fake phone
        ['1000005', 'Ashwini Marawa', '', null], // null phone
      ];

      final patients = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );

      expect(patients['1000001']!.phoneNumber, '+91 98765 43210');
      expect(patients['1000001']!.phoneNumberNormalized, '9876543210');

      // Fake values must NOT be stored in database model
      expect(patients['1000002']!.phoneNumber, isNull);
      expect(patients['1000003']!.phoneNumber, isNull);
      expect(patients['1000004']!.phoneNumber, isNull);
      expect(patients['1000005']!.phoneNumber, isNull);
    });

    test('1.6 Phone number survives SQLite persistence', () async {
      final db = InMemoryAppDatabase();

      const patient = Patient(
        id: '1000001',
        name: 'Anil Jain',
        phoneNumber: '+91 98765 43210',
        phoneNumberNormalized: '9876543210',
      );

      await db.replacePatients([patient]);

      final retrieved = await db.getPatient('1000001');
      expect(retrieved, isNotNull);
      expect(retrieved!.phoneNumber, '+91 98765 43210');
      expect(retrieved.phoneNumberNormalized, '9876543210');
    });

    test('1.7 Duplicate patient IDs are deduplicated into a single patient', () {
      final rows = [
        ['Patient ID', 'Patient Name', 'Photos (Drive)', 'Phone Number'],
        ['1000001', 'Anil Jain', '', '+91 98765 43210'],
        ['1000001', 'Anil Jain', '', '+91 98765 43210'],
        ['1000001', 'Anil Jain', 'https://drive.google.com/drive/folders/1ABC_folder101_XYZ', '+91 98765 43210'],
      ];

      final patients = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );

      expect(patients.length, 1);
      expect(patients.containsKey('1000001'), isTrue);
      expect(patients['1000001']!.driveFolderId, '1ABC_folder101_XYZ');
      expect(patients['1000001']!.folderStatus, FolderStatus.available);
    });

    test('1.8 Blank values do not overwrite populated name/phone across visits', () {
      final rows = [
        ['Patient ID', 'Patient Name', 'Photos (Drive)', 'Phone Number'],
        ['1000001', 'Anil Jain', '', '+91 98765 43210'],
        ['1000001', '', '', ''], // Visit 2: receptionist left name & phone blank
      ];

      final patients = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );

      expect(patients.length, 1);
      final p = patients['1000001']!;
      expect(p.name, 'Anil Jain');
      expect(p.displayName, 'Anil Jain');
      expect(p.phoneNumber, '+91 98765 43210');
      expect(p.phoneNumberNormalized, '9876543210');

      // Also verify via Patient.merge directly
      const existing = Patient(
        id: '1000001',
        name: 'Anil Jain',
        phoneNumber: '+91 98765 43210',
      );
      const incomingBlank = Patient(
        id: '1000001',
        name: '',
        phoneNumber: null,
      );

      final merged = Patient.merge(existing, incomingBlank);
      expect(merged.name, 'Anil Jain');
      expect(merged.phoneNumber, '+91 98765 43210');
      expect(merged.phoneNumberNormalized, '9876543210');
    });

    test('1.9 Null phone number is supported without synthetic strings', () {
      const patient = Patient(
        id: '1000006',
        name: 'Patient Without Phone',
        phoneNumber: null,
      );

      expect(patient.phoneNumber, isNull);
      expect(patient.phoneNumberNormalized, isNull);

      final map = patient.toMap();
      expect(map['phone_number'], isNull);
      expect(map['phone_number_normalized'], isNull);

      final fromMap = Patient.fromMap(map);
      expect(fromMap.phoneNumber, isNull);
      expect(fromMap.phoneNumberNormalized, isNull);
    });
  });

  // =========================================================================
  // 2. SEARCH REGRESSION TESTS
  // =========================================================================
  group('2. SEARCH regression tests', () {
    late InMemoryAppDatabase database;

    setUp(() async {
      database = InMemoryAppDatabase();
      await database.replacePatients([
        const Patient(
          id: '1000001',
          name: 'Anil Jain',
          phoneNumber: '+91 98765 43210',
          phoneNumberNormalized: '9876543210',
        ),
        const Patient(
          id: '1000002',
          name: 'Shilpa Kalbhor',
          phoneNumber: '+91 87654 32109',
          phoneNumberNormalized: '8765432109',
        ),
        const Patient(
          id: '1000003',
          name: 'Pragati Waghaji',
          phoneNumber: null,
          phoneNumberNormalized: null,
        ),
        const Patient(
          id: '1000004',
          name: 'Ovi Vanage',
          phoneNumber: '020-25678901',
          phoneNumberNormalized: '02025678901',
        ),
      ]);
    });

    tearDown(() async {
      await database.close();
    });

    test('2.1 Search by name', () async {
      final results = await database.searchPatients('Anil');
      expect(results.length, 1);
      expect(results.first.id, '1000001');
      expect(results.first.name, 'Anil Jain');
    });

    test('2.2 Search by partial name', () async {
      final results = await database.searchPatients('il Ja');
      expect(results.length, 1);
      expect(results.first.name, 'Anil Jain');
    });

    test('2.3 Search by phone', () async {
      final results = await database.searchPatients('9876543210');
      expect(results.length, 1);
      expect(results.first.id, '1000001');
    });

    test('2.4 Search by partial phone', () async {
      final results = await database.searchPatients('98765');
      expect(results.length, 1);
      expect(results.first.id, '1000001');
    });

    test('2.5 Search by patient ID', () async {
      final results = await database.searchPatients('1000002');
      expect(results.length, 1);
      expect(results.first.name, 'Shilpa Kalbhor');
    });

    test('2.6 All mode matches ID, name, or phone', () async {
      // By ID
      final byId = await database.searchPatients('1000003', mode: SearchFilterMode.all);
      expect(byId.length, 1);
      expect(byId.first.name, 'Pragati Waghaji');

      // By Name
      final byName = await database.searchPatients('Shilpa', mode: SearchFilterMode.all);
      expect(byName.length, 1);
      expect(byName.first.id, '1000002');

      // By Phone
      final byPhone = await database.searchPatients('32109', mode: SearchFilterMode.all);
      expect(byPhone.length, 1);
      expect(byPhone.first.id, '1000002');
    });

    test('2.7 Name mode matches only patient name', () async {
      // Searching ID in Name mode yields nothing
      final byId = await database.searchPatients('1000001', mode: SearchFilterMode.name);
      expect(byId, isEmpty);

      // Searching Phone in Name mode yields nothing
      final byPhone = await database.searchPatients('9876543210', mode: SearchFilterMode.name);
      expect(byPhone, isEmpty);

      // Searching Name matches
      final byName = await database.searchPatients('Anil', mode: SearchFilterMode.name);
      expect(byName.length, 1);
      expect(byName.first.id, '1000001');
    });

    test('2.8 Phone mode matches only phone number', () async {
      // Searching Name in Phone mode yields nothing
      final byName = await database.searchPatients('Anil', mode: SearchFilterMode.phone);
      expect(byName, isEmpty);

      // Searching ID in Phone mode yields nothing
      final byId = await database.searchPatients('1000001', mode: SearchFilterMode.phone);
      expect(byId, isEmpty);

      // Searching Phone matches
      final byPhone = await database.searchPatients('9876543210', mode: SearchFilterMode.phone);
      expect(byPhone.length, 1);
      expect(byPhone.first.name, 'Anil Jain');
    });

    test('2.9 Patient ID mode matches only patient ID', () async {
      // Searching Name in Patient ID mode yields nothing
      final byName = await database.searchPatients('Anil', mode: SearchFilterMode.patientId);
      expect(byName, isEmpty);

      // Searching Phone in Patient ID mode yields nothing
      final byPhone = await database.searchPatients('9876543210', mode: SearchFilterMode.patientId);
      expect(byPhone, isEmpty);

      // Searching ID matches
      final byId = await database.searchPatients('1000001', mode: SearchFilterMode.patientId);
      expect(byId.length, 1);
      expect(byId.first.name, 'Anil Jain');
    });

    test('2.10 Case-insensitive name search', () async {
      final lower = await database.searchPatients('anil jain');
      expect(lower.length, 1);
      expect(lower.first.id, '1000001');

      final upper = await database.searchPatients('ANIL JAIN');
      expect(upper.length, 1);
      expect(upper.first.id, '1000001');
    });

    test('2.11 Normalized phone search matches formatted and raw variants', () async {
      // Searching raw without country code
      final raw = await database.searchPatients('9876543210', mode: SearchFilterMode.phone);
      expect(raw.length, 1);
      expect(raw.first.id, '1000001');

      // Searching with spaces
      final spaced = await database.searchPatients('98765 43210', mode: SearchFilterMode.phone);
      expect(spaced.length, 1);
      expect(spaced.first.id, '1000001');

      // Searching with +91 prefix
      final country = await database.searchPatients('+91 98765 43210', mode: SearchFilterMode.phone);
      expect(country.length, 1);
      expect(country.first.id, '1000001');

      // Partial search with +91 prefix
      final partialCountry = await database.searchPatients('+91 98765', mode: SearchFilterMode.phone);
      expect(partialCountry.length, 1);
      expect(partialCountry.first.id, '1000001');
    });
  });

  // =========================================================================
  // 3. COUNT REGRESSION TESTS
  // =========================================================================
  group('3. COUNT regression tests', () {
    test('3.1 75 Visits rows produces exactly 65 unique patients', () {
      const headerIndices = HeaderIndices(
        idColIndex: 0,
        nameColIndex: 1,
        folderColIndex: 2,
      );

      final rows = <List<dynamic>>[
        ['Patient ID', 'Patient Name', 'Photos (Drive)'],
      ];

      // Generate 65 unique patients (IDs 1000001 to 1000065)
      for (int i = 1; i <= 65; i++) {
        final id = (1000000 + i).toString();
        rows.add([id, 'Patient Name $id', '']);
      }

      // Add 10 repeat visit rows for the first 10 patients (75 total data rows)
      for (int i = 1; i <= 10; i++) {
        final id = (1000000 + i).toString();
        rows.add([id, 'Patient Name $id', '']);
      }

      expect(rows.length, 76); // 1 header + 75 data rows

      final patients = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );

      expect(patients.length, 65);
    });

    test('3.2 Repeated patient IDs produce exactly one patient', () {
      const headerIndices = HeaderIndices(
        idColIndex: 0,
        nameColIndex: 1,
        folderColIndex: 2,
      );

      final rows = [
        ['Patient ID', 'Patient Name', 'Photos (Drive)'],
        ['1000001', 'Anil Jain', ''],
        ['1000001', 'Anil Jain', ''],
        ['1000001', 'Anil Jain', ''],
        ['1000001', 'Anil Jain', ''],
      ];

      final patients = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );

      expect(patients.length, 1);
      expect(patients.keys.first, '1000001');
    });

    test('3.3 Unassigned sessions are not counted as patients', () async {
      final db = InMemoryAppDatabase();

      // Insert 3 real patients
      await db.replacePatients([
        const Patient(id: '1000001', name: 'Anil Jain'),
        const Patient(id: '1000002', name: 'Shilpa Kalbhor'),
        const Patient(id: '1000003', name: 'Pragati Waghaji'),
      ]);

      // Create 2 unassigned capture sessions in the database
      await db.insertSession(
        CaptureSession(
          id: 'unassigned_sess_001',
          createdAt: DateTime.now(),
          status: 'unassigned',
        ),
      );
      await db.insertSession(
        CaptureSession(
          id: 'unassigned_sess_002',
          createdAt: DateTime.now(),
          status: 'unassigned',
        ),
      );

      // Verify unassigned sessions exist
      final unassignedCount = await db.getUnassignedSessionsCount();
      expect(unassignedCount, 2);

      // Verify patients count is strictly 3, unassigned sessions are NOT patients
      final patients = await db.getPatients();
      expect(patients.length, 3);
      expect(patients.map((p) => p.id), containsAll(['1000001', '1000002', '1000003']));
    });
  });

  // =========================================================================
  // 4. UI REGRESSION TESTS
  // =========================================================================
  group('4. UI regression tests', () {
    testWidgets('4.1 PatientTile displays actual patient name and zero ID', (tester) async {
      const patient = Patient(
        id: '1000001',
        name: 'Anil Jain',
        phoneNumber: '+91 98765 43210',
        folderStatus: FolderStatus.missing,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PatientTile(
              patient: patient,
              onTap: () {},
              onViewPhotos: () {},
              onTakePhotos: () {},
            ),
          ),
        ),
      );

      expect(find.text('1000001'), findsNothing);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('Anil Jain'), findsOneWidget);
      expect(find.text('+91 98765 43210'), findsOneWidget);
      expect(find.text('Folder auto-creates on photo capture'), findsOneWidget);
      expect(find.text('Name unavailable'), findsNothing);
      expect(find.text('Patient 1000001'), findsNothing);
    });

    testWidgets('4.2 Fallback Name unavailable appears only when name is genuinely missing', (tester) async {
      const missingNamePatient = Patient(
        id: '1000002',
        name: '',
        folderStatus: FolderStatus.missing,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PatientTile(
              patient: missingNamePatient,
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.text('1000002'), findsNothing);
      expect(find.text('Name unavailable'), findsOneWidget);
    });

    testWidgets('4.3 Long names and long phone numbers do not overlap action buttons', (tester) async {
      tester.view.physicalSize = const Size(320 * 2.0, 640 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);

      const longPatient = Patient(
        id: '1000004',
        name: 'Dr. Very Extremely Long Clinical Patient Name That Exceeds Normal Screen Width',
        phoneNumber: '+91 98765 43210 (Extension 40992)',
        folderStatus: FolderStatus.missing,
      );

      bool photoTapped = false;
      bool cameraTapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: PatientTile(
                patient: longPatient,
                onTap: () {},
                onViewPhotos: () => photoTapped = true,
                onTakePhotos: () => cameraTapped = true,
              ),
            ),
          ),
        ),
      );

      // Verify zero RenderFlex overflow exceptions occurred
      expect(tester.takeException(), isNull);

      // Verify action buttons are visible and interactable
      await tester.tap(find.byIcon(Icons.photo_library_outlined));
      expect(photoTapped, isTrue);

      await tester.tap(find.byIcon(Icons.camera_alt_outlined));
      expect(cameraTapped, isTrue);
    });

    testWidgets('4.4 Search filter chips work and filter list interactively', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final configService = await ConfigService.init();
      await configService.saveConfig(
        const ClinicConfig(
          spreadsheetId: 'dummy_id',
          spreadsheetUrl: 'https://docs.google.com/spreadsheets/d/dummy_id/edit',
          sheetTabName: 'Visits',
          hasCompletedSetup: true,
          lastSyncedRow: 75,
        ),
      );

      final db = InMemoryAppDatabase();
      await db.replacePatients([
        const Patient(
          id: '1000001',
          name: 'Anil Jain',
          phoneNumber: '+91 98765 43210',
          phoneNumberNormalized: '9876543210',
        ),
        const Patient(
          id: '1000002',
          name: 'Shilpa Kalbhor',
          phoneNumber: '+91 87654 32109',
          phoneNumberNormalized: '8765432109',
        ),
      ]);

      final tempDir = Directory.systemTemp.createTempSync('patients_screen_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final queueService = UploadQueueService(
        database: db,
        driveService: DriveService(),
        authService: GoogleAuthService(),
        customDocsDirectory: tempDir.path,
      );
      addTearDown(queueService.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: PatientsScreen(
            authService: GoogleAuthService(),
            configService: configService,
            sheetsService: SheetsService(),
            database: db,
            queueService: queueService,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Initially both patients are shown
      expect(find.text('Anil Jain'), findsOneWidget);
      expect(find.text('Shilpa Kalbhor'), findsOneWidget);

      // Verify filter chips exist: All, Name, Phone (zero Patient ID chip)
      expect(find.widgetWithText(ChoiceChip, 'All'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Name'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Phone'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Patient ID'), findsNothing);

      // Enter search query "Anil"
      await tester.enterText(find.byType(TextField), 'Anil');
      await tester.pumpAndSettle();

      // Only Anil Jain is shown
      expect(find.text('Anil Jain'), findsOneWidget);
      expect(find.text('Shilpa Kalbhor'), findsNothing);

      // Switch to Phone filter chip
      await tester.tap(find.widgetWithText(ChoiceChip, 'Phone'));
      await tester.pumpAndSettle();

      // "Anil" is not a phone number, so no patients match
      expect(find.text('Anil Jain'), findsNothing);
      expect(find.text('Shilpa Kalbhor'), findsNothing);

      // Enter phone query "32109"
      await tester.enterText(find.byType(TextField), '32109');
      await tester.pumpAndSettle();

      // Shilpa Kalbhor matches phone number
      expect(find.text('Shilpa Kalbhor'), findsOneWidget);
      expect(find.text('Anil Jain'), findsNothing);

      // Switch back to All filter chip
      await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
      await tester.pumpAndSettle();

      // Still matches Shilpa Kalbhor
      expect(find.text('Shilpa Kalbhor'), findsOneWidget);

      // Clear search
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();

      // Both patients return
      expect(find.text('Anil Jain'), findsOneWidget);
      expect(find.text('Shilpa Kalbhor'), findsOneWidget);
    });

    test('14.1 Shilpa Kalbhor (1000002) SQLite insert and query using PatientsScreen query', () async {
      final db = InMemoryAppDatabase();

      const patient = Patient(
        id: '1000002',
        name: 'Shilpa Kalbhor',
        phoneNumber: '8956387071',
        phoneNumberNormalized: '8956387071',
        folderStatus: FolderStatus.missing,
      );

      await db.replacePatients([patient]);

      // Same query used by PatientsScreen (getPatients)
      final retrievedList = await db.getPatients();
      expect(retrievedList.length, 1);
      final retrieved = retrievedList.first;
      expect(retrieved.id, '1000002');
      expect(retrieved.name, 'Shilpa Kalbhor');
      expect(retrieved.displayName, 'Shilpa Kalbhor');
      expect(retrieved.hasValidName, isTrue);
      expect(retrieved.phoneNumber, '8956387071');
    });

    test('14.2 Patient 1000002 appearing in multiple Visits rows preserves name when later row is blank', () {
      const headerIndices = HeaderIndices(
        idColIndex: 0,
        nameColIndex: 1,
        folderColIndex: 2,
        phoneColIndex: 3,
      );

      final rows = [
        ['Patient ID', 'Patient Name', 'Photos (Drive)', 'Phone Number'],
        ['1000002', 'Shilpa Kalbhor', '', '8956387071'],
        ['1000002', '', '', ''], // Blank follow up visit
      ];

      final patients = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headerIndices,
      );

      expect(patients.length, 1);
      expect(patients['1000002']!.name, 'Shilpa Kalbhor');
      expect(patients['1000002']!.phoneNumber, '8956387071');
    });

    test('14.3 Clinic Patients directory enrichment resolves blank visits row and populates phone', () {
      final visitRows = [
        ['Patient ID', 'Patient Name', 'Photos (Drive)'],
        ['1000001', '', ''],
        ['1000002', '', ''],
        ['1000003', '', ''],
      ];

      final patientsMap = SheetsService.resolvePatientsFromVisits(
        rows: visitRows,
        headerIndices: const HeaderIndices(idColIndex: 0, nameColIndex: 1, folderColIndex: 2),
      );

      final directoryRows = [
        [],
        ['', 'Nidhi Skin Clinic - Patient Tracker'],
        [],
        ['', 'Appointment ID', 'Patient ID', 'Patient Name', 'Gender', 'Age', 'Phone Number'],
        ['', '', '1000001', 'Anil Jain', 'M', '48', '9422301214'],
        ['', '', '1000002', 'Shilpa Kalbhor', 'F', '34', '8956387071'],
        ['', '', '1000003', 'Pragati Waghaji', 'F', '26', '8767718749'],
      ];

      SheetsService.enrichPatientsFromDirectory(patientsMap, directoryRows);

      expect(patientsMap['1000001']!.name, 'Anil Jain');
      expect(patientsMap['1000001']!.phoneNumber, '9422301214');
      expect(patientsMap['1000002']!.name, 'Shilpa Kalbhor');
      expect(patientsMap['1000002']!.phoneNumber, '8956387071');
      expect(patientsMap['1000003']!.name, 'Pragati Waghaji');
      expect(patientsMap['1000003']!.phoneNumber, '8767718749');
    });
  });

  // =========================================================================
  // 15. RELATIONAL WORKBOOK & APPOINTMENT RESOLUTION REGRESSION TESTS
  // =========================================================================
  group('15. Relational Workbook & Appointment Resolution Regression Tests', () {
    test('15.1 Visits header discovery finds headers at row 8 including Photos (Drive) at col O', () {
      final visitsRows = [
        ['Nidhi Skin Clinic - Visits Log'],
        ['Total Visits', '56'],
        [],
        [],
        [],
        [],
        [],
        [
          '', // A
          'Patient ID', // B
          'Patient Name', // C
          'Visit Date', // D
          'Fees Paid', // E
          'LAB PAID', // F
          'EXPENSES', // G
          'Notes', // H
          'Earnings', // I
          'Visit Type', // J
          'Fees Type', // K
          'Receipt Number', // L
          'Prescription Link', // M
          'Diagnosis Notes', // N
          'Photos (Drive)', // O
          'Whatsapp Message Sent', // P
        ],
        ['', '1000001', 'Anil Jain', '07/09/2026', '600', '', '', '', '600', 'New', 'Online', '', '', '', 'https://drive.google.com/drive/folders/1abcFolderId12345'],
      ];

      final headers = SheetsService.discoverHeaderIndices(visitsRows);
      expect(headers.headerRowIndex, 7); // 0-indexed row 7 is row 8
      expect(headers.headerRowNumber, 8);
      expect(headers.idColIndex, 1); // Column B
      expect(headers.nameColIndex, 2); // Column C
      expect(headers.folderColIndex, 14); // Column O
    });

    test('15.2 parseAppointments correctly parses schedule tab', () {
      final apptRows = [
        ['Nidhi Skin Clinic - Appointment Schedule'],
        ['Total Appointments', '21'],
        [],
        [],
        [],
        [],
        [],
        [
          '',
          'Appointment ID',
          'Patient Name',
          'Phone Number',
          'Date',
          'Time',
          'Visit Type',
          'Status',
        ],
        ['', '2000011.0', 'Abhijit Gaikwad', '9373264424', '2026-09-26', '02:00 PM', 'Consultation', 'Completed'],
        ['', '2000010.0', 'Kajal Gurjar', '9697980016', '2026-09-26', '05:30 PM', 'Consultation', 'Completed'],
        ['', '2000012.0', 'Priya Chavan ', '7218223864', '2026-09-28', '05:30 PM', 'Consultation', 'Completed'],
        ['', '2000014.0', 'Kashefa Shaikh', '9130819937', '2026-09-28', '07:00 PM', 'Consultation', 'Completed'],
        ['', '1000019.0', 'Kirti Walunjkar', '9420206324', '2026-09-29', '06:00 PM', 'Consultation', 'Completed'],
        ['', '2000017.0', 'Madhuri Rao', '7294187156', '2026-09-30', '10:30 AM', 'Consultation', 'Scheduled'],
      ];

      final appts = SheetsService.parseAppointments(apptRows);
      expect(appts.length, 6);
      expect(appts['2000011']!.patientName, 'Abhijit Gaikwad');
      expect(appts['2000011']!.phoneNumber, '9373264424');
      expect(appts['2000010']!.patientName, 'Kajal Gurjar');
      expect(appts['2000010']!.phoneNumber, '9697980016');
      expect(appts['2000012']!.patientName, 'Priya Chavan');
      expect(appts['2000012']!.phoneNumber, '7218223864');
      expect(appts['2000014']!.patientName, 'Kashefa Shaikh');
      expect(appts['2000014']!.phoneNumber, '9130819937');
      expect(appts['1000019']!.patientName, 'Kirti Walunjkar');
      expect(appts['1000019']!.phoneNumber, '9420206324');
      expect(appts['2000017']!.patientName, 'Madhuri Rao');
      expect(appts['2000017']!.phoneNumber, '7294187156');
    });

    test('15.3 Full relational resolution: exact workbook cases 1000047, 1000048, 1000049, 1000050, 1000051, 1000054', () {
      // 1. Operational Visits sheet rows (Formula-derived names return blank from API)
      final visitsRows = [
        ['', 'Patient ID', 'Patient Name', 'Photos (Drive)'],
        ['', '1000047.0', '', ''], // Walk-in (Siddheshwar Nalawade)
        ['', '1000048.0', '', ''], // Appointment (Abhijit Gaikwad)
        ['', '1000049.0', '', ''], // Appointment (Kajal Gurjar)
        ['', '1000050.0', '', ''], // Appointment (Priya Chavan)
        ['', '1000051.0', '', ''], // Appointment (Kashefa Shaikh)
        ['', '1000054.0', '', ''], // Walk-in (Suvarna Bhapkar)
        ['', '1000055.0', '', ''], // Template empty row
      ];

      final headers = SheetsService.discoverHeaderIndices(visitsRows);
      final patientsMap = SheetsService.resolvePatientsFromVisits(
        rows: visitsRows,
        headerIndices: headers,
      );

      // 2. Appointments schedule tab
      final apptRows = [
        ['Appointment ID', 'Patient Name', 'Phone Number'],
        ['2000011.0', 'Abhijit Gaikwad', '9373264424'],
        ['2000010.0', 'Kajal Gurjar', '9697980016'],
        ['2000012.0', 'Priya Chavan ', '7218223864'],
        ['2000014.0', 'Kashefa Shaikh', '9130819937'],
      ];
      final appointmentsMap = SheetsService.parseAppointments(apptRows);

      // 3. Patients directory tab (Row 8 header: B=Appt ID, C=Patient ID, D=Name, G=Phone)
      final directoryRows = [
        ['Appointment ID', 'Patient ID', 'Patient Name', 'Gender', 'Age', 'Phone Number'],
        ['', '1000047.0', 'Siddheshwar Nalawade', 'M', '35', '8.007094554E9'], // Direct name & scientific phone
        ['2000011.0', '1000048.0', '', 'M', '26', ''], // Name & phone are formulas -> blank in API
        ['2000010.0', '1000049.0', '', 'F', '29', ''], // Name & phone are formulas -> blank in API
        ['2000012.0', '1000050.0', '', 'F', '26', ''], // Name & phone are formulas -> blank in API
        ['2000014.0', '1000051.0', '', 'F', '27', ''], // Name & phone are formulas -> blank in API
        ['', '1000054.0', 'Suvarna Bhapkar', 'F', '36', '9.890969729E9'], // Direct name & scientific phone
        ['', '1000055.0', '', '', '', ''], // Template empty row
      ];

      SheetsService.enrichPatientsFromDirectory(
        patientsMap,
        directoryRows,
        appointmentsMap: appointmentsMap,
      );

      // Verify 1000047: Siddheshwar Nalawade (Walk-in)
      final p47 = patientsMap['1000047']!;
      expect(p47.name, 'Siddheshwar Nalawade');
      expect(p47.hasValidName, isTrue);
      expect(p47.phoneNumber, '8007094554');
      expect(p47.phoneNumberNormalized, '8007094554');

      // Verify 1000048: Abhijit Gaikwad (Appointment-linked)
      final p48 = patientsMap['1000048']!;
      expect(p48.name, 'Abhijit Gaikwad');
      expect(p48.hasValidName, isTrue);
      expect(p48.phoneNumber, '9373264424');
      expect(p48.phoneNumberNormalized, '9373264424');

      // Verify 1000049: Kajal Gurjar (Appointment-linked)
      final p49 = patientsMap['1000049']!;
      expect(p49.name, 'Kajal Gurjar');
      expect(p49.hasValidName, isTrue);
      expect(p49.phoneNumber, '9697980016');
      expect(p49.phoneNumberNormalized, '9697980016');

      // Verify 1000050: Priya Chavan (Appointment-linked)
      final p50 = patientsMap['1000050']!;
      expect(p50.name, 'Priya Chavan');
      expect(p50.hasValidName, isTrue);
      expect(p50.phoneNumber, '7218223864');
      expect(p50.phoneNumberNormalized, '7218223864');

      // Verify 1000051: Kashefa Shaikh (Appointment-linked)
      final p51 = patientsMap['1000051']!;
      expect(p51.name, 'Kashefa Shaikh');
      expect(p51.hasValidName, isTrue);
      expect(p51.phoneNumber, '9130819937');
      expect(p51.phoneNumberNormalized, '9130819937');

      // Verify 1000054: Suvarna Bhapkar (Walk-in)
      final p54 = patientsMap['1000054']!;
      expect(p54.name, 'Suvarna Bhapkar');
      expect(p54.hasValidName, isTrue);
      expect(p54.phoneNumber, '9890969729');
      expect(p54.phoneNumberNormalized, '9890969729');

      // Verify template row 1000055: has no name, cleanly handled without crash
      final p55 = patientsMap['1000055']!;
      expect(p55.name, '');
      expect(p55.displayName, 'Name unavailable');
      expect(p55.hasValidName, isFalse);
    });

    test('15.4 Duplicate visits deduplication: multiple visits rows for 1000001 become 1 SQLite patient', () {
      final visitRows = [
        ['Patient ID', 'Patient Name', 'Visit Date', 'Photos (Drive)'],
        ['1000001.0', 'Anil Jain', '07/09/2026', ''],
        ['1000001.0', '', '16/09/2026', 'https://drive.google.com/drive/folders/1folder_for_anil_jain'],
      ];

      final headers = SheetsService.discoverHeaderIndices(visitRows);
      final patientsMap = SheetsService.resolvePatientsFromVisits(
        rows: visitRows,
        headerIndices: headers,
      );

      expect(patientsMap.length, 1);
      final p1 = patientsMap['1000001']!;
      expect(p1.id, '1000001');
      expect(p1.name, 'Anil Jain');
      expect(p1.driveFolderId, '1folder_for_anil_jain');
      expect(p1.folderStatus, FolderStatus.available);
    });

    test('15.5 Preserving populated values when later visit row is blank', () {
      final existing = const Patient(
        id: '1000048',
        name: 'Abhijit Gaikwad',
        phoneNumber: '9373264424',
        phoneNumberNormalized: '9373264424',
        driveFolderId: 'folder_48',
        folderStatus: FolderStatus.available,
      );

      final blankIncoming = const Patient(
        id: '1000048',
        name: '',
        phoneNumber: null,
        phoneNumberNormalized: null,
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );

      final merged = Patient.merge(existing, blankIncoming);
      expect(merged.name, 'Abhijit Gaikwad');
      expect(merged.phoneNumber, '9373264424');
      expect(merged.phoneNumberNormalized, '9373264424');
      expect(merged.driveFolderId, 'folder_48');
      expect(merged.folderStatus, FolderStatus.available);
    });

    test('15.6 Phone normalization supports formatted, unformatted, and scientific variants identically', () {
      const expectedNormalized = '9422301214';

      expect(Patient.normalizePhone('9422301214'), expectedNormalized);
      expect(Patient.normalizePhone('+91 94223 01214'), expectedNormalized);
      expect(Patient.normalizePhone('+919422301214'), expectedNormalized);
      expect(Patient.normalizePhone('09422301214'), expectedNormalized);
      expect(Patient.normalizePhone('9.422301214E9'), expectedNormalized);
      expect(Patient.normalizePhone('9422301214.0'), expectedNormalized);
    });

    test('15.7 SQLite search across All, Name, Phone, and Patient ID for resolved patients', () async {
      final db = InMemoryAppDatabase();

      final p47 = const Patient(
        id: '1000047',
        name: 'Siddheshwar Nalawade',
        phoneNumber: '8007094554',
        phoneNumberNormalized: '8007094554',
        folderStatus: FolderStatus.missing,
      );
      final p48 = const Patient(
        id: '1000048',
        name: 'Abhijit Gaikwad',
        phoneNumber: '9373264424',
        phoneNumberNormalized: '9373264424',
        folderStatus: FolderStatus.missing,
      );

      await db.replacePatients([p47, p48]);

      // Search by ID
      final byId = await db.searchPatients('1000048', mode: SearchFilterMode.patientId);
      expect(byId.length, 1);
      expect(byId.first.name, 'Abhijit Gaikwad');

      // Search by Name
      final byName = await db.searchPatients('Abhijit', mode: SearchFilterMode.name);
      expect(byName.length, 1);
      expect(byName.first.id, '1000048');

      // Search by Phone
      final byPhone = await db.searchPatients('9373264424', mode: SearchFilterMode.phone);
      expect(byPhone.length, 1);
      expect(byPhone.first.id, '1000048');

      // Search by formatted phone in All mode
      final byFormattedPhone = await db.searchPatients('+91 93732 64424', mode: SearchFilterMode.all);
      expect(byFormattedPhone.length, 1);
      expect(byFormattedPhone.first.id, '1000048');
    });

    test('15.8 Blank patient IDs are skipped, and blank patient names fallback cleanly', () {
      final rows = [
        ['Patient ID', 'Patient Name', 'Photos (Drive)'],
        ['', 'Orphan Name', ''], // Blank ID -> skipped
        ['   ', 'Another Orphan', ''], // Whitespace ID -> skipped
        ['1000099', '', ''], // Valid ID, blank Name
      ];

      final headers = SheetsService.discoverHeaderIndices(rows);
      final patients = SheetsService.resolvePatientsFromVisits(
        rows: rows,
        headerIndices: headers,
      );

      expect(patients.length, 1);
      expect(patients.containsKey('1000099'), isTrue);
      expect(patients['1000099']!.name, '');
      expect(patients['1000099']!.displayName, 'Name unavailable');
      expect(patients['1000099']!.hasValidName, isFalse);
    });

    test('15.9 Idempotent synchronization: repeatedly replacing/syncing patients produces identical state', () async {
      final db = InMemoryAppDatabase();

      final p47 = const Patient(
        id: '1000047',
        name: 'Siddheshwar Nalawade',
        phoneNumber: '8007094554',
        phoneNumberNormalized: '8007094554',
        folderStatus: FolderStatus.missing,
      );
      final p48 = const Patient(
        id: '1000048',
        name: 'Abhijit Gaikwad',
        phoneNumber: '9373264424',
        phoneNumberNormalized: '9373264424',
        folderStatus: FolderStatus.available,
        driveFolderId: 'folder_48',
      );

      // Pass 1
      await db.replacePatients([p47, p48]);
      final pass1 = await db.getPatients();
      expect(pass1.length, 2);

      // Pass 2 (identical sync payload)
      await db.replacePatients([p47, p48]);
      final pass2 = await db.getPatients();
      expect(pass2.length, 2);
      expect(pass2[0].name, pass1[0].name);
      expect(pass2[0].phoneNumber, pass1[0].phoneNumber);
      expect(pass2[1].name, pass1[1].name);
      expect(pass2[1].driveFolderId, pass1[1].driveFolderId);
    });
  });
}
