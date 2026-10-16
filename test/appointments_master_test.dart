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

      final phoneOnly = patients['phone:9876543210']!;
      expect(phoneOnly.hasValidName, isFalse);
      expect(phoneOnly.hasUsableIdentity, isTrue);
      expect(phoneOnly.normalizedPhone, '9876543210');
    });

    test('recognizes appointment headers regardless of worksheet title and skips unusable rows', () {
      final rows = [
        ['Report export'],
        ['Phone Number', 'Patient Name', 'Appointment ID'],
        ['+91 98765 43210', '', '400001'],
        ['', '   ', '400002'],
      ];

      expect(SheetsService.hasAppointmentTableHeaders(rows), isTrue);
      final patients = SheetsService.resolvePatientsFromAppointments(rows);
      expect(patients, hasLength(1));
      expect(patients.values.single.normalizedPhone, '9876543210');
      expect(patients.values.single.hasUsableIdentity, isTrue);
    });

    test('does not treat a Patients directory row with Patient ID as an appointment table', () {
      expect(
        SheetsService.hasAppointmentTableHeaders([
          ['Appointment ID', 'Patient ID', 'Patient Name', 'Phone Number'],
        ]),
        isFalse,
      );
    });

    test('retains support for legacy Appointments tabs without an appointment ID column', () {
      expect(
        SheetsService.hasAppointmentTableHeaders(
          [
            ['Patient Name', 'Phone Number'],
          ],
          allowMissingAppointmentId: true,
        ),
        isTrue,
      );
    });

    test('joins blank-phone rows to the only matching normalized phone group', () {
      final patients = SheetsService.resolvePatientsFromAppointments([
        ['Appointment ID', 'Patient Name', 'Phone Number', 'Photos (Drive)'],
        ['3000011', '  Nisha   Patil ', '+91 98765 43210', 'folder-nisha-12345'],
        ['3000012', 'Nisha Patil', '', ''],
      ]);

      expect(patients, hasLength(1));
      final patient = patients.values.single;
      expect(patient.normalizedName, 'nisha patil');
      expect(patient.normalizedPhone, '9876543210');
      expect(patient.legacyPatientId, '3000011');
      expect(patient.driveFolderId, 'folder-nisha-12345');
    });

    test('does not merge same-name rows when their normalized phones conflict', () {
      final patients = SheetsService.resolvePatientsFromAppointments([
        ['Appointment ID', 'Patient Name', 'Phone Number'],
        ['3000021', 'Same Name', '9876543210'],
        ['3000022', ' same   name ', '9123456780'],
      ]);

      expect(patients, hasLength(2));
      expect(patients.keys, containsAll(<String>[
        'phone:9876543210',
        'phone:9123456780',
      ]));
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

    test('does not replace an Appointments folder with a different Visits folder', () {
      final patients = SheetsService.resolvePatientsFromAppointments([
        ['Appointment ID', 'Patient Name', 'Phone Number', 'Photos (Drive)'],
        ['2000011', 'Abhijit Gaikwad', '9373264424', 'folder-appointment-12345'],
      ]);

      SheetsService.enrichPatientsFromVisitsFolders(patients, [
        ['Patient ID', 'Patient Name', 'Phone Number', 'Photos (Drive)'],
        ['1000048', 'Abhijit Gaikwad', '9373264424', 'folder-visits-12345'],
      ]);

      expect(patients['phone:9373264424']!.driveFolderId, isNull);
      expect(patients['phone:9373264424']!.folderStatus, FolderStatus.conflict);
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
