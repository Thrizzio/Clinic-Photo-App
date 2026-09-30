enum FolderStatus {
  available,
  missing,
  creating,
  conflict;

  static FolderStatus fromString(String value) {
    return switch (value.toLowerCase()) {
      'available' => FolderStatus.available,
      'creating' => FolderStatus.creating,
      'conflict' => FolderStatus.conflict,
      _ => FolderStatus.missing,
    };
  }
}

class Patient {
  final String id;
  final String name;
  final String? phoneNumber;
  final String? phoneNumberNormalized;
  final String? driveFolderId;
  final FolderStatus folderStatus;
  final DateTime? updatedAt;

  const Patient({
    required this.id,
    required this.name,
    this.phoneNumber,
    this.phoneNumberNormalized,
    this.driveFolderId,
    this.folderStatus = FolderStatus.available,
    this.updatedAt,
  });

  /// Alias for id matching V3 specification.
  String get patientId => id;

  /// True if photos can be captured and uploaded for this patient.
  bool get isUploadable =>
      folderStatus == FolderStatus.available &&
      driveFolderId != null &&
      driveFolderId!.isNotEmpty;

  /// Whether a genuine clinical name is recorded for this patient.
  bool get hasValidName {
    final trimmed = name.trim();
    return trimmed.isNotEmpty &&
        trimmed != 'Patient $id' &&
        trimmed != 'Patient';
  }

  /// Returns the patient's name if available, or falls back to 'Name unavailable'
  /// if the name is empty or is a synthetic placeholder like `Patient <id>`.
  String get displayName {
    if (hasValidName) {
      return name.trim();
    }
    return 'Name unavailable';
  }

  /// Normalizes a phone number for search indexing.
  /// Strips formatting characters (spaces, dashes, parens, plus, dots).
  /// Strips common national/international prefixes (+91, leading 0) so
  /// formatted variants like '+91 98765 43210', '+919876543210', and '9876543210' match identically.
  /// Rejects fake/placeholder strings like 'unknown', 'none', '-', '0000000000'.
  static String? normalizePhone(String? raw) {
    if (raw == null) return null;
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    final lower = trimmed.toLowerCase();
    if (lower == 'unknown' ||
        lower == 'none' ||
        lower == '-' ||
        lower == '--' ||
        lower == 'na' ||
        lower == 'n/a' ||
        lower == 'nil' ||
        lower == '0' ||
        RegExp(r'^0+$').hasMatch(trimmed)) {
      return null;
    }

    // Handle spreadsheet scientific notation (e.g. 9.422301214E9) or decimal floats (9422301214.0)
    if (RegExp(r'^\d+\.?\d*E\+?\d+$', caseSensitive: false).hasMatch(trimmed)) {
      final d = double.tryParse(trimmed);
      if (d != null) {
        trimmed = d.toStringAsFixed(0);
      }
    } else if (RegExp(r'^\d+\.0+$').hasMatch(trimmed)) {
      trimmed = trimmed.split('.').first;
    }

    String s = trimmed;
    if (s.startsWith('+91')) {
      s = s.substring(3);
    } else if (s.startsWith('+')) {
      s = s.substring(1);
    }

    String digits = s.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 12 && digits.startsWith('91')) {
      digits = digits.substring(2);
    } else if (digits.length == 11 && digits.startsWith('0')) {
      digits = digits.substring(1);
    }

    return digits.isNotEmpty ? digits : null;
  }

  /// Cleans a phone number for storage and display, rejecting fake placeholders.
  static String? cleanPhone(String? raw) {
    if (raw == null) return null;
    var trimmed = raw.trim();
    if (normalizePhone(trimmed) == null) return null;

    if (RegExp(r'^\d+\.?\d*E\+?\d+$', caseSensitive: false).hasMatch(trimmed)) {
      final d = double.tryParse(trimmed);
      if (d != null) {
        return d.toStringAsFixed(0);
      }
    } else if (RegExp(r'^\d+\.0+$').hasMatch(trimmed)) {
      return trimmed.split('.').first;
    }

    return trimmed;
  }

  /// Merges an existing cached Patient with an incoming Patient from a new visit row.
  static Patient merge(Patient existing, Patient incoming) {
    FolderStatus mergedStatus = incoming.folderStatus;
    String? mergedFolderId = incoming.driveFolderId;

    if (existing.folderStatus == FolderStatus.conflict ||
        incoming.folderStatus == FolderStatus.conflict) {
      mergedStatus = FolderStatus.conflict;
      mergedFolderId = null;
    } else if (existing.folderStatus == FolderStatus.available &&
        incoming.folderStatus == FolderStatus.available) {
      if (existing.driveFolderId != incoming.driveFolderId) {
        mergedStatus = FolderStatus.conflict;
        mergedFolderId = null;
      } else {
        mergedFolderId = existing.driveFolderId;
        mergedStatus = FolderStatus.available;
      }
    } else if (existing.folderStatus == FolderStatus.available &&
        incoming.folderStatus == FolderStatus.missing) {
      mergedStatus = FolderStatus.available;
      mergedFolderId = existing.driveFolderId;
    } else if (existing.folderStatus == FolderStatus.missing &&
        incoming.folderStatus == FolderStatus.available) {
      mergedStatus = FolderStatus.available;
      mergedFolderId = incoming.driveFolderId;
    } else {
      mergedStatus = FolderStatus.missing;
      mergedFolderId = null;
    }

    // Preserve valid clinical name: incoming name overwrites only if genuine.
    final mergedName = incoming.hasValidName
        ? incoming.name.trim()
        : (existing.hasValidName ? existing.name.trim() : (incoming.name.trim().isNotEmpty ? incoming.name.trim() : existing.name.trim()));

    // Preserve valid phone number: incoming non-empty/valid phone overwrites; otherwise retain existing.
    final incomingPhoneClean = cleanPhone(incoming.phoneNumber);
    final existingPhoneClean = cleanPhone(existing.phoneNumber);
    final mergedPhone = incomingPhoneClean ?? existingPhoneClean;
    final mergedNormPhone = normalizePhone(mergedPhone);

    return Patient(
      id: incoming.id,
      name: mergedName,
      phoneNumber: mergedPhone,
      phoneNumberNormalized: mergedNormPhone,
      driveFolderId: mergedFolderId,
      folderStatus: mergedStatus,
      updatedAt: DateTime.now(),
    );
  }

  /// Creates a Patient from a single row map (legacy/helper).
  static Patient? fromRow({
    required Map<String, dynamic> rowMap,
    required String idCol,
    required String nameCol,
    required String folderCol,
    String? phoneCol,
  }) {
    final rawId = rowMap[idCol]?.toString().trim() ?? '';
    final rawName = rowMap[nameCol]?.toString().trim() ?? '';
    final rawFolder = rowMap[folderCol]?.toString().trim() ?? '';
    final rawPhone = phoneCol != null ? rowMap[phoneCol]?.toString() : null;

    if (rawId.isEmpty || rawName.isEmpty) {
      return null;
    }

    final cleanPhoneNumber = cleanPhone(rawPhone);
    final normPhone = normalizePhone(cleanPhoneNumber);

    if (rawFolder.isEmpty) {
      return Patient(
        id: rawId,
        name: rawName,
        phoneNumber: cleanPhoneNumber,
        phoneNumberNormalized: normPhone,
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
        updatedAt: DateTime.now(),
      );
    }

    return Patient(
      id: rawId,
      name: rawName,
      phoneNumber: cleanPhoneNumber,
      phoneNumberNormalized: normPhone,
      driveFolderId: rawFolder,
      folderStatus: FolderStatus.available,
      updatedAt: DateTime.now(),
    );
  }

  /// Convert to SQLite map
  Map<String, dynamic> toMap() {
    final cleanP = cleanPhone(phoneNumber);
    final normP = phoneNumberNormalized ?? normalizePhone(cleanP);
    return {
      'id': id,
      'name': name,
      'phone_number': cleanP,
      'phone_number_normalized': normP,
      'drive_folder_id': driveFolderId,
      'folder_status': folderStatus.name,
      'updated_at': (updatedAt ?? DateTime.now()).toIso8601String(),
    };
  }

  /// Create from SQLite map
  factory Patient.fromMap(Map<String, dynamic> map) {
    final rawPhone = map['phone_number'] as String?;
    final cleanP = cleanPhone(rawPhone);
    final normP = (map['phone_number_normalized'] as String?) ?? normalizePhone(cleanP);

    return Patient(
      id: ((map['patient_id'] ?? map['id']) as String?) ?? '',
      name: (map['name'] as String?) ?? '',
      phoneNumber: cleanP,
      phoneNumberNormalized: normP,
      driveFolderId: map['drive_folder_id'] as String?,
      folderStatus: FolderStatus.fromString(
        map['folder_status'] as String? ?? 'available',
      ),
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'] as String)
          : null,
    );
  }

  Patient copyWith({
    String? id,
    String? name,
    String? phoneNumber,
    String? phoneNumberNormalized,
    String? driveFolderId,
    FolderStatus? folderStatus,
    DateTime? updatedAt,
  }) {
    return Patient(
      id: id ?? this.id,
      name: name ?? this.name,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      phoneNumberNormalized: phoneNumberNormalized ?? this.phoneNumberNormalized,
      driveFolderId: driveFolderId ?? this.driveFolderId,
      folderStatus: folderStatus ?? this.folderStatus,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Patient &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          phoneNumber == other.phoneNumber &&
          driveFolderId == other.driveFolderId &&
          folderStatus == other.folderStatus;

  @override
  int get hashCode =>
      id.hashCode ^
      name.hashCode ^
      (phoneNumber?.hashCode ?? 0) ^
      (driveFolderId?.hashCode ?? 0) ^
      folderStatus.hashCode;

  @override
  String toString() =>
      'Patient(id: $id, name: $name, phone: $phoneNumber, driveFolderId: $driveFolderId, status: ${folderStatus.name})';
}
