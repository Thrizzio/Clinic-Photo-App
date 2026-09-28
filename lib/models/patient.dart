class Patient {
  final String id;
  final String name;
  final String driveFolderId;

  const Patient({
    required this.id,
    required this.name,
    required this.driveFolderId,
  });

  /// Creates a Patient from a parsed row map, or returns null if any required
  /// field is missing, empty, or whitespace-only.
  ///
  /// This enforces the Drive Folder ID validation rule:
  /// Patients without a valid Drive Folder ID are skipped during sync and
  /// cannot be selected for photo capture.
  static Patient? fromRow({
    required Map<String, dynamic> rowMap,
    required String idCol,
    required String nameCol,
    required String folderCol,
  }) {
    final rawId = rowMap[idCol]?.toString().trim() ?? '';
    final rawName = rowMap[nameCol]?.toString().trim() ?? '';
    final rawFolder = rowMap[folderCol]?.toString().trim() ?? '';

    if (rawId.isEmpty || rawName.isEmpty || rawFolder.isEmpty) {
      return null;
    }

    return Patient(
      id: rawId,
      name: rawName,
      driveFolderId: rawFolder,
    );
  }

  /// Convert to SQLite map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'drive_folder_id': driveFolderId,
    };
  }

  /// Create from SQLite map
  factory Patient.fromMap(Map<String, dynamic> map) {
    return Patient(
      id: map['id'] as String,
      name: map['name'] as String,
      driveFolderId: map['drive_folder_id'] as String,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Patient &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          driveFolderId == other.driveFolderId;

  @override
  int get hashCode => id.hashCode ^ name.hashCode ^ driveFolderId.hashCode;

  @override
  String toString() => 'Patient(id: $id, name: $name, driveFolderId: $driveFolderId)';
}
