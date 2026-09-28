import 'package:clinic_photos/models/patient.dart';
import 'package:clinic_photos/services/database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Patient search & cache in AppDatabase', () {
    late AppDatabase database;

    setUp(() async {
      database = InMemoryAppDatabase();

      await database.replacePatients([
        const Patient(id: 'P001', name: 'Rahul Sharma', driveFolderId: 'folder_p001'),
        const Patient(id: 'P002', name: 'Ananya Patel', driveFolderId: 'folder_p002'),
        const Patient(id: 'P014', name: 'Amit Patel', driveFolderId: 'folder_p014'),
        const Patient(id: 'P032', name: 'Priya Shah', driveFolderId: 'folder_p032'),
      ]);
    });

    tearDown(() async {
      await database.close();
    });

    test('empty query returns all patients ordered by ID', () async {
      final results = await database.searchPatients('');
      expect(results.length, 4);
      expect(results[0].id, 'P001');
      expect(results[1].id, 'P002');
      expect(results[2].id, 'P014');
      expect(results[3].id, 'P032');
    });

    test('case-insensitive search by name: "rahul" finds Rahul Sharma', () async {
      final results = await database.searchPatients('rahul');
      expect(results.length, 1);
      expect(results.first.id, 'P001');
      expect(results.first.name, 'Rahul Sharma');
    });

    test('case-insensitive search by uppercase name: "RAHUL" finds Rahul Sharma', () async {
      final results = await database.searchPatients('RAHUL');
      expect(results.length, 1);
      expect(results.first.id, 'P001');
    });

    test('case-insensitive search by Patient ID: "p001" and "P001"', () async {
      final lower = await database.searchPatients('p001');
      expect(lower.length, 1);
      expect(lower.first.name, 'Rahul Sharma');

      final upper = await database.searchPatients('P001');
      expect(upper.length, 1);
      expect(upper.first.name, 'Rahul Sharma');
    });

    test('partial search matches across multiple patients: "patel"', () async {
      final results = await database.searchPatients('patel');
      expect(results.length, 2);
      expect(results.map((p) => p.id), containsAll(['P002', 'P014']));
    });

    test('handles leading and trailing whitespace in query', () async {
      final results = await database.searchPatients('  Priya  ');
      expect(results.length, 1);
      expect(results.first.id, 'P032');
    });

    test('non-matching query returns empty list', () async {
      final results = await database.searchPatients('Unknown Doctor');
      expect(results, isEmpty);
    });
  });
}
