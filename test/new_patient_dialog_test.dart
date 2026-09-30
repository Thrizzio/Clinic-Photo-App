import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/widgets/new_patient_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NewPatientDialog Tests (Phase 4)', () {
    late InMemoryAppDatabase database;

    setUp(() {
      database = InMemoryAppDatabase();
    });

    tearDown(() async {
      await database.close();
    });

    testWidgets('1. Requires both Name and Phone before submission', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => NewPatientDialog.show(context, database: database),
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      expect(find.text('New Patient'), findsOneWidget);
      expect(find.text('Patient Name *'), findsOneWidget);
      expect(find.text('Phone Number *'), findsOneWidget);

      // Attempt to submit empty form
      await tester.tap(find.text('Create Patient'));
      await tester.pumpAndSettle();

      expect(find.text('Patient name is required'), findsOneWidget);
      expect(find.text('Phone number is required'), findsOneWidget);
    });

    testWidgets('2. Validates 10-digit Indian phone number strictly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => NewPatientDialog.show(context, database: database),
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'Abhijit Gaikwad');
      // Enter invalid phone (too short)
      await tester.enterText(find.byType(TextFormField).last, '12345');
      await tester.tap(find.text('Create Patient'));
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid 10-digit Indian phone number'), findsOneWidget);

      // Enter invalid phone (placeholder zeros)
      await tester.enterText(find.byType(TextFormField).last, '0000000000');
      await tester.tap(find.text('Create Patient'));
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid 10-digit Indian phone number'), findsOneWidget);
    });

    testWidgets('3. Creates doctor-created patient with UUID and saves to SQLite', (tester) async {
      Patient? createdPatient;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  createdPatient = await NewPatientDialog.show(context, database: database);
                },
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'Dr. Sarah Connor');
      await tester.enterText(find.byType(TextFormField).last, '+91 98220 12345');
      await tester.tap(find.text('Create Patient'));
      await tester.pumpAndSettle();

      // Dialog closed and returned created patient
      expect(createdPatient, isNotNull);
      expect(createdPatient!.displayName, 'Dr. Sarah Connor');
      expect(createdPatient!.normalizedName, 'dr. sarah connor');
      expect(createdPatient!.normalizedPhone, '9822012345');
      expect(createdPatient!.source, PatientSource.doctorCreated);
      expect(createdPatient!.folderStatus, FolderStatus.missing);
      expect(createdPatient!.legacyPatientId, isNull);

      // Persisted in SQLite
      final inDb = await database.getPatient(createdPatient!.id);
      expect(inDb, isNotNull);
      expect(inDb!.displayName, 'Dr. Sarah Connor');
      expect(inDb.source, PatientSource.doctorCreated);
    });

    testWidgets('4. Detects existing patient by (name, phone) and prompts to open existing', (tester) async {
      final existing = Patient(
        id: 'existing-uuid-123',
        name: 'Abhijit Gaikwad',
        displayName: 'Abhijit Gaikwad',
        normalizedName: 'abhijit gaikwad',
        phoneNumber: '9373264424',
        phoneDisplay: '9373264424',
        normalizedPhone: '9373264424',
        source: PatientSource.doctorCreated,
        folderStatus: FolderStatus.available,
        driveFolderId: 'folder_existing_123',
      );
      await database.upsertPatients([existing]);

      Patient? resultPatient;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  resultPatient = await NewPatientDialog.show(context, database: database);
                },
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      // Enter same name (different case/spacing) and same phone
      await tester.enterText(find.byType(TextFormField).first, '  abhijit   gaikwad  ');
      await tester.enterText(find.byType(TextFormField).last, '+91-93732-64424');
      await tester.tap(find.text('Create Patient'));
      await tester.pumpAndSettle();

      // Duplicate alert dialog appears
      expect(find.text('Patient Already Exists'), findsOneWidget);
      expect(find.textContaining('Would you like to open this existing patient instead?'), findsOneWidget);

      // Tap "Open Patient"
      await tester.tap(find.text('Open Patient'));
      await tester.pumpAndSettle();

      expect(resultPatient, isNotNull);
      expect(resultPatient!.id, 'existing-uuid-123');
      expect(resultPatient!.driveFolderId, 'folder_existing_123');
    });
  });
}
