import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:clinic_photos/widgets/patient_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PatientTile Widget Tests', () {
    testWidgets('1. Displays genuine patient name and ID badge', (tester) async {
      const patient = Patient(
        id: '1000001',
        name: 'Anil Jain',
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

      // Verifies patient ID is shown in badge
      expect(find.text('1000001'), findsOneWidget);
      // Verifies genuine patient name is displayed
      expect(find.text('Anil Jain'), findsOneWidget);
      // Verifies "Patient 1000001" is NOT displayed
      expect(find.text('Patient 1000001'), findsNothing);
      // Verifies subtitle is displayed
      expect(find.text('Folder auto-creates on photo capture'), findsOneWidget);
      // Verifies both action buttons exist
      expect(find.byIcon(Icons.photo_library_outlined), findsOneWidget);
      expect(find.byIcon(Icons.camera_alt_outlined), findsOneWidget);
    });

    testWidgets('2. Displays Name unavailable when name is missing or synthetic placeholder', (tester) async {
      const emptyPatient = Patient(
        id: '1000003',
        name: '',
        folderStatus: FolderStatus.missing,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PatientTile(
              patient: emptyPatient,
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.text('1000003'), findsOneWidget);
      expect(find.text('Name unavailable'), findsOneWidget);
      expect(find.text('Patient 1000003'), findsNothing);
    });

    testWidgets('3. Never overflows on narrow screen width (320px) — 33px overflow eliminated', (tester) async {
      // Set tester window to narrow phone width (320px)
      tester.view.physicalSize = const Size(320 * 2.0, 640 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);

      const patient = Patient(
        id: '1000004',
        name: 'Ovi Vanage with a Very Long Clinical Name That Should Ellipsize Cleanly',
        folderStatus: FolderStatus.missing,
      );

      bool tappedPhotos = false;
      bool tappedCamera = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: PatientTile(
                patient: patient,
                onTap: () {},
                onViewPhotos: () => tappedPhotos = true,
                onTakePhotos: () => tappedCamera = true,
              ),
            ),
          ),
        ),
      );

      // Verify no RenderFlex overflow exception occurred
      expect(tester.takeException(), isNull);

      // Verify action buttons are reachable and clickable
      await tester.tap(find.byIcon(Icons.photo_library_outlined));
      expect(tappedPhotos, isTrue);

      await tester.tap(find.byIcon(Icons.camera_alt_outlined));
      expect(tappedCamera, isTrue);
    });

    testWidgets('4. Conflict state displays warning subtitle without overflow', (tester) async {
      tester.view.physicalSize = const Size(360 * 2.0, 640 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);

      const patient = Patient(
        id: '1000005',
        name: 'Ashwini Marawa',
        folderStatus: FolderStatus.conflict,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: PatientTile(
                patient: patient,
                onTap: () {},
                onViewPhotos: () {},
                onTakePhotos: () {},
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Conflicting Drive folders in Visits'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });
  });

  group('SQLite Patient Name & ID Persistence Tests', () {
    test('SQLite insert and query preserves Patient.name and ID correctly', () async {
      final db = InMemoryAppDatabase();

      final originalPatients = [
        const Patient(
          id: '1000001',
          name: 'Anil Jain',
          folderStatus: FolderStatus.missing,
        ),
        const Patient(
          id: '1000002',
          name: 'Shilpa Kalbhor',
          folderStatus: FolderStatus.missing,
        ),
        const Patient(
          id: '1000003',
          name: 'Pragati Waghaji',
          folderStatus: FolderStatus.missing,
        ),
      ];

      await db.replacePatients(originalPatients);

      final retrieved = await db.getPatients();
      expect(retrieved.length, 3);
      expect(retrieved[0].id, '1000001');
      expect(retrieved[0].name, 'Anil Jain');
      expect(retrieved[1].id, '1000002');
      expect(retrieved[1].name, 'Shilpa Kalbhor');
      expect(retrieved[2].id, '1000003');
      expect(retrieved[2].name, 'Pragati Waghaji');

      // Search by ID
      final searchById = await db.searchPatients('1000002');
      expect(searchById.length, 1);
      expect(searchById.first.name, 'Shilpa Kalbhor');

      // Search by Name
      final searchByName = await db.searchPatients('Pragati');
      expect(searchByName.length, 1);
      expect(searchByName.first.id, '1000003');
    });
  });
}
