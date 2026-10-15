import 'package:clinic_photos/services/sheets.dart';
import 'package:clinic_photos/models/patient.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Appointments master patient resolution', () {
    test('deduplicates by phone, preserves one folder, and normalizes IDs', () {
      final rows = <List<dynamic>>[
        ['Clinic appointments'],
        ['Appointment ID', 'Patient Name', 'Phone Number', 'Photos (Drive)'],
        ['2000011.0', 'Abhijit Gaikwad', '+91 93732 64424', 'folder-abhijit-12345'],
        ['2000012.0', 'Abhijit Gaikwad', '9373264424', 'folder-abhijit-12345'],
        ['2000013.0', 'Kajal Gurjar', '', 'folder-kajal-a-12345'],
        ['2000014.0', 'Kajal Gurjar', '', 'folder-kajal-b-12345'],
        ['2000015.0', '#N/A', '9876543210', 'ignored'],
      ];

      final patients = SheetsService.resolvePatientsFromAppointments(rows);

      expect(patients.length, 3);
      expect(patients.values.where((p) => p.hasValidName), hasLength(2));
      final abhijit = patients['phone:9373264424']!;
      expect(abhijit.legacyPatientId, '2000011');
      expect(abhijit.name, 'Abhijit Gaikwad');
      expect(abhijit.normalizedPhone, '9373264424');
      expect(abhijit.driveFolderId, 'folder-abhijit-12345');
      expect(abhijit.folderStatus.name, 'available');

      final kajal = patients['name:kajal gurjar']!;
      expect(kajal.legacyPatientId, '2000013');
      expect(kajal.driveFolderId, isNull);
      expect(kajal.folderStatus.name, 'conflict');
    });

    test('keeps appointment identity when a directory row supplies the patient ID', () {
      final patients = SheetsService.resolvePatientsFromAppointments([
        ['Appointment ID', 'Patient Name', 'Phone Number'],
        ['2000011.0', 'Abhijit Gaikwad', '9373264424'],
      ]);

      SheetsService.enrichPatientsFromDirectory(
        patients,
        [
          ['Appointment ID', 'Patient ID', 'Patient Name', 'Phone Number'],
          ['2000011.0', '1000048.0', '', ''],
        ],
        appointmentsMap: SheetsService.parseAppointments([
          ['Appointment ID', 'Patient Name', 'Phone Number'],
          ['2000011.0', 'Abhijit Gaikwad', '9373264424'],
        ]),
      );

      expect(patients, hasLength(1));
      expect(patients.values.single.name, 'Abhijit Gaikwad');
      expect(patients.values.single.legacyPatientId, '2000011');
    });

    test('fingerprint is independent of appointment row order', () {
      final first = SheetsService.resolvePatientsFromAppointments([
        ['Appointment ID', 'Patient Name', 'Phone Number'],
        ['1', 'Anil Jain', '9876543210'],
        ['2', 'Kajal Gurjar', '9697980016'],
      ]);
      final second = SheetsService.resolvePatientsFromAppointments([
        ['Appointment ID', 'Patient Name', 'Phone Number'],
        ['2', 'Kajal Gurjar', '9697980016'],
        ['1', 'Anil Jain', '9876543210'],
      ]);

      expect(
        SheetsService.fingerprintPatients(first.values),
        SheetsService.fingerprintPatients(second.values),
      );
    });

    test('retains a unique Visits folder and flags multiple folder matches', () {
      final patients = SheetsService.resolvePatientsFromAppointments([
        ['Appointment ID', 'Patient Name', 'Phone Number'],
        ['2000011', 'Abhijit Gaikwad', '9373264424'],
        ['2000012', 'Kajal Gurjar', '9697980016'],
      ]);

      SheetsService.enrichPatientsFromVisitsFolders(patients, [
        ['Patient ID', 'Patient Name', 'Phone Number', 'Photos (Drive)'],
        ['1000048', 'Abhijit Gaikwad', '9373264424', 'folder-abhijit-12345'],
        ['1000049', 'Kajal Gurjar', '9697980016', 'folder-kajal-a-12345'],
        ['1000050', 'Kajal Gurjar', '9697980016', 'folder-kajal-b-12345'],
      ]);

      expect(patients['phone:9373264424']!.driveFolderId, 'folder-abhijit-12345');
      expect(patients['phone:9373264424']!.folderStatus, FolderStatus.available);
      expect(patients['phone:9697980016']!.driveFolderId, isNull);
      expect(patients['phone:9697980016']!.folderStatus, FolderStatus.conflict);
    });

    test('uses the Patients directory link when Visits formula names are blank', () {
      final patients = SheetsService.resolvePatientsFromAppointments([
        ['Appointment ID', 'Patient Name', 'Phone Number'],
        ['2000011', 'Abhijit Gaikwad', '9373264424'],
      ]);

      SheetsService.enrichPatientsFromVisitsFolders(
        patients,
        [
          ['Patient ID', 'Patient Name', 'Photos (Drive)'],
          ['1000048', '', 'folder-abhijit-12345'],
        ],
        directoryRows: [
          ['Appointment ID', 'Patient ID', 'Patient Name'],
          ['2000011', '1000048', ''],
        ],
      );

      expect(patients['phone:9373264424']!.driveFolderId, 'folder-abhijit-12345');
    });
  });
}
