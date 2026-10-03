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

enum PatientSource {
  clinicSheet,
  doctorCreated,
  merged;

  static PatientSource fromString(String value) {
    return switch (value.toLowerCase()) {
      'doctor_created' || 'doctorcreated' => PatientSource.doctorCreated,
      'merged' => PatientSource.merged,
      _ => PatientSource.clinicSheet,
    };
  }

  String get dbValue => switch (this) {
        PatientSource.clinicSheet => 'clinic_sheet',
        PatientSource.doctorCreated => 'doctor_created',
        PatientSource.merged => 'merged',
      };
}

class Patient {
  /// Unique local UUID primary key.
  final String id;

  final String _name;
  final String _normalizedName;
  final String? _phoneDisplay;
  final String? _normalizedPhone;

  /// Optional clinic spreadsheet Patient ID (e.g. '1000001'), retained strictly for legacy/import compatibility.
  final String? legacyPatientId;

  /// Source of the record: clinic_sheet, doctor_created, or merged.
  final PatientSource source;

  /// Google Drive folder ID for storing patient clinical photos.
  final String? driveFolderId;

  /// Status of the patient's Google Drive folder.
  final FolderStatus folderStatus;

  /// Record creation timestamp.
  final DateTime? createdAt;

  /// Record last update timestamp.
  final DateTime? updatedAt;

  /// Local sync status: 'synced', 'pending_cloud', or 'failed_cloud'.
  final String syncStatus;

  const Patient({
    required this.id,
    String? name,
    String? displayName,
    String normalizedName = '',
    String? phoneNumber,
    String? phoneDisplay,
    String? phoneNumberNormalized,
    String? normalizedPhone,
    this.legacyPatientId,
    this.source = PatientSource.clinicSheet,
    this.driveFolderId,
    this.folderStatus = FolderStatus.available,
    this.createdAt,
    this.updatedAt,
    this.syncStatus = 'synced',
  })  : _name = displayName ?? name ?? '',
        // ignore: prefer_initializing_formals
        _normalizedName = normalizedName,
        _phoneDisplay = phoneDisplay ?? phoneNumber,
        _normalizedPhone = normalizedPhone ?? phoneNumberNormalized;

  /// Raw or stored name value (empty if unpopulated).
  String get name => _name;

  /// Clinical display name with original casing (e.g. 'Anil Jain').
  String get displayName => hasValidName ? _name.trim() : 'Name unavailable';

  /// Trimmed, lowercased, whitespace-collapsed name for indexing and matching.
  String get normalizedName => _normalizedName.isNotEmpty
      ? _normalizedName
      : normalizeName(hasValidName ? _name.trim() : '');

  /// Display phone number formatted as entered or imported (e.g. '+91 94223 01214').
  String? get phoneDisplay => cleanPhone(_phoneDisplay);

  /// Clean 10-digit phone string for indexing and matching (e.g. '9422301214').
  String? get normalizedPhone => _normalizedPhone ?? normalizePhone(_phoneDisplay);

  /// Backward-compatible alias for phoneDisplay.
  String? get phoneNumber => phoneDisplay;

  /// Backward-compatible alias for normalizedPhone.
  String? get phoneNumberNormalized => normalizedPhone;

  /// Backward-compatible alias for id.
  String get patientId => id;

  /// True if photos can be captured and uploaded for this patient.
  bool get isUploadable =>
      folderStatus == FolderStatus.available &&
      driveFolderId != null &&
      driveFolderId!.isNotEmpty;

  static final RegExp _uuidRegex = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// Checks whether a given string is a valid standard UUID (v4) format.
  static bool isValidUuid(String? id) => id != null && _uuidRegex.hasMatch(id.trim());

  /// Checks whether a name represents a genuine clinical patient name
  /// and is not a missing, placeholder, or synthetic token (e.g. 'Name unavailable', 'Patient 1000001').
  static bool isUsableName(String? name, [String? id, String? legacyId]) {
    if (name == null) return false;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final lower = trimmed.toLowerCase();
    if (lower == 'name unavailable' ||
        lower == 'none' ||
        lower == 'null' ||
        lower == 'na' ||
        lower == 'n/a' ||
        lower == 'nil' ||
        lower == 'unknown' ||
        lower == '-' ||
        lower == '--' ||
        lower == 'patient' ||
        lower.startsWith('#')) {
      return false;
    }
    if (RegExp(r'^patient\s*(\d+)?$', caseSensitive: false).hasMatch(trimmed)) {
      return false;
    }
    if (id != null && (trimmed == 'Patient $id' || lower == 'patient ${id.toLowerCase()}')) {
      return false;
    }
    if (legacyId != null && (trimmed == 'Patient $legacyId' || lower == 'patient ${legacyId.toLowerCase()}')) {
      return false;
    }
    return true;
  }

  /// Whether a genuine clinical name is recorded for this patient.
  bool get hasValidName => isUsableName(_name, id, legacyPatientId);

  /// Normalizes a name string: trims, lowercases, collapses multi-spaces.
  static String normalizeName(String raw) {
    return raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Normalizes a phone number for indexing and exact business deduplication.
  /// Handles Indian prefixes (+91, 91, leading 0), scientific notation (9.422E9), decimal floats.
  /// Returns null for empty, placeholder, or invalid inputs.
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

    if (digits.length == 10) {
      return digits;
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

  /// Exact business identity check: requires identical normalized names AND matching, non-null normalized phones.
  /// Incomplete records (missing phone) never match.
  bool matchesBusinessIdentity(String otherNormName, String? otherNormPhone) {
    if (normalizedName != otherNormName) return false;
    if (normalizedPhone == null || otherNormPhone == null) return false;
    if (normalizedPhone!.isEmpty || otherNormPhone.isEmpty) return false;
    return normalizedPhone == otherNormPhone;
  }

  /// Merges an existing cached Patient with an incoming Patient.
  /// Hard Invariant: If doctor-created patient matches an incoming Sheet patient,
  /// retains existing UUID, Drive folder, and sets legacyPatientId with source = merged.
  static Patient merge(Patient existing, Patient incoming) {
    FolderStatus mergedStatus = incoming.folderStatus;
    String? mergedFolderId = incoming.driveFolderId;

    if (existing.folderStatus == FolderStatus.conflict ||
        incoming.folderStatus == FolderStatus.conflict) {
      mergedStatus = FolderStatus.conflict;
      mergedFolderId = null;
    } else if (existing.folderStatus == FolderStatus.available &&
        incoming.folderStatus == FolderStatus.available) {
      if (existing.driveFolderId != incoming.driveFolderId &&
          existing.driveFolderId != null &&
          incoming.driveFolderId != null) {
        mergedStatus = FolderStatus.conflict;
        mergedFolderId = null;
      } else {
        mergedFolderId = existing.driveFolderId ?? incoming.driveFolderId;
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
      mergedStatus = existing.driveFolderId != null ? existing.folderStatus : incoming.folderStatus;
      mergedFolderId = existing.driveFolderId ?? incoming.driveFolderId;
    }

    // Preserve valid clinical name: incoming name overwrites only if genuine.
    final mergedName = incoming.hasValidName
        ? incoming.displayName.trim()
        : (existing.hasValidName ? existing.displayName.trim() : (incoming.name.trim().isNotEmpty ? incoming.name.trim() : existing.name.trim()));

    // Preserve valid phone number: incoming non-empty/valid phone overwrites; otherwise retain existing.
    final incomingPhoneClean = cleanPhone(incoming.phoneDisplay);
    final existingPhoneClean = cleanPhone(existing.phoneDisplay);
    final mergedPhone = incomingPhoneClean ?? existingPhoneClean;

    // Source determination: if either was doctorCreated or already merged, result is merged.
    PatientSource mergedSource = existing.source;
    if ((existing.source == PatientSource.doctorCreated && incoming.source == PatientSource.clinicSheet) ||
        (existing.source == PatientSource.clinicSheet && incoming.source == PatientSource.doctorCreated)) {
      mergedSource = PatientSource.merged;
    } else if (incoming.source == PatientSource.merged) {
      mergedSource = PatientSource.merged;
    }

    final mergedLegacyId = incoming.legacyPatientId ?? existing.legacyPatientId;

    return Patient(
      id: existing.id, // Always retain existing local UUID
      name: mergedName,
      displayName: mergedName,
      normalizedName: normalizeName(mergedName),
      phoneDisplay: mergedPhone,
      normalizedPhone: normalizePhone(mergedPhone),
      legacyPatientId: mergedLegacyId,
      source: mergedSource,
      driveFolderId: mergedFolderId,
      folderStatus: mergedStatus,
      createdAt: existing.createdAt,
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
    String? generatedId,
  }) {
    final rawId = rowMap[idCol]?.toString().trim() ?? '';
    final rawName = rowMap[nameCol]?.toString().trim() ?? '';
    final rawFolder = rowMap[folderCol]?.toString().trim() ?? '';
    final rawPhone = phoneCol != null ? rowMap[phoneCol]?.toString() : null;

    if (rawId.isEmpty || !isUsableName(rawName, rawId)) {
      return null;
    }

    final cleanPhoneNumber = cleanPhone(rawPhone);
    final normPhone = normalizePhone(cleanPhoneNumber);

    return Patient(
      id: generatedId ?? rawId,
      name: rawName,
      displayName: rawName,
      normalizedName: normalizeName(rawName),
      phoneDisplay: cleanPhoneNumber,
      normalizedPhone: normPhone,
      legacyPatientId: rawId,
      source: PatientSource.clinicSheet,
      driveFolderId: rawFolder.isNotEmpty ? rawFolder : null,
      folderStatus: rawFolder.isNotEmpty ? FolderStatus.available : FolderStatus.missing,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  /// Convert to SQLite map
  Map<String, dynamic> toMap() {
    final cleanP = cleanPhone(phoneDisplay);
    final normP = normalizedPhone ?? normalizePhone(cleanP);
    final createdIso = (createdAt ?? DateTime.now()).toIso8601String();
    final updatedIso = (updatedAt ?? DateTime.now()).toIso8601String();
    return {
      'id': id,
      'display_name': displayName,
      'normalized_name': normalizedName,
      'phone_display': cleanP,
      'normalized_phone': normP,
      'legacy_patient_id': legacyPatientId,
      'source': source.dbValue,
      'drive_folder_id': driveFolderId,
      'folder_status': folderStatus.name,
      'created_at': createdIso,
      'updated_at': updatedIso,
      'sync_status': syncStatus,
      // Legacy backward-compatibility columns
      'name': _name,
      'phone_number': cleanP,
      'phone_number_normalized': normP,
    };
  }

  /// Create from SQLite map
  factory Patient.fromMap(Map<String, dynamic> map) {
    final rawName = (map['name'] ?? map['display_name'] ?? '') as String;
    final rawDisplayName = (map['display_name'] ?? map['name'] ?? '') as String;
    final rawNormName = (map['normalized_name'] as String?) ?? normalizeName(rawDisplayName);
    final rawPhoneDisplay = (map['phone_display'] ?? map['phone_number']) as String?;
    final cleanP = cleanPhone(rawPhoneDisplay);
    final normP = (map['normalized_phone'] ?? map['phone_number_normalized']) as String? ?? normalizePhone(cleanP);
    final rawSource = (map['source'] as String?) ?? 'clinic_sheet';
    final legacyId = (map['legacy_patient_id'] as String?) ??
        ((map['id'] != null && !map['id'].toString().contains('-')) ? map['id'].toString() : null);
    final syncStat = (map['sync_status'] as String?) ?? 'synced';

    return Patient(
      id: ((map['id'] ?? map['patient_id']) as String?) ?? '',
      name: rawName,
      displayName: rawDisplayName,
      normalizedName: rawNormName,
      phoneDisplay: cleanP,
      normalizedPhone: normP,
      legacyPatientId: legacyId,
      source: PatientSource.fromString(rawSource),
      driveFolderId: map['drive_folder_id'] as String?,
      folderStatus: FolderStatus.fromString(map['folder_status'] as String? ?? 'available'),
      createdAt: map['created_at'] != null ? DateTime.tryParse(map['created_at'] as String) : null,
      updatedAt: map['updated_at'] != null ? DateTime.tryParse(map['updated_at'] as String) : null,
      syncStatus: syncStat,
    );
  }

  Patient copyWith({
    String? id,
    String? name,
    String? displayName,
    String? normalizedName,
    String? phoneDisplay,
    String? normalizedPhone,
    String? legacyPatientId,
    PatientSource? source,
    String? driveFolderId,
    FolderStatus? folderStatus,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? syncStatus,
    // Legacy parameter aliases
    String? phoneNumber,
    String? phoneNumberNormalized,
  }) {
    final effectiveName = name ?? displayName ?? _name;
    final effectivePhoneDisplay = phoneDisplay ?? phoneNumber ?? _phoneDisplay;
    return Patient(
      id: id ?? this.id,
      name: effectiveName,
      displayName: displayName ?? effectiveName,
      normalizedName: normalizedName ?? normalizeName(effectiveName),
      phoneDisplay: effectivePhoneDisplay,
      normalizedPhone: normalizedPhone ?? normalizePhone(effectivePhoneDisplay),
      legacyPatientId: legacyPatientId ?? this.legacyPatientId,
      source: source ?? this.source,
      driveFolderId: driveFolderId ?? this.driveFolderId,
      folderStatus: folderStatus ?? this.folderStatus,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      syncStatus: syncStatus ?? this.syncStatus,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Patient &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          _name == other._name &&
          normalizedPhone == other.normalizedPhone &&
          driveFolderId == other.driveFolderId &&
          folderStatus == other.folderStatus;

  @override
  int get hashCode =>
      id.hashCode ^
      _name.hashCode ^
      (normalizedPhone?.hashCode ?? 0) ^
      (driveFolderId?.hashCode ?? 0) ^
      folderStatus.hashCode;

  @override
  String toString() =>
      'Patient(id: $id, name: $displayName, phone: $phoneDisplay, legacyId: $legacyPatientId, source: ${source.dbValue}, driveFolderId: $driveFolderId, status: ${folderStatus.name})';
}
