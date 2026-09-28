enum FolderStatus {
  available,
  missing,
  conflict;

  static FolderStatus fromString(String value) {
    return switch (value.toLowerCase()) {
      'available' => FolderStatus.available,
      'conflict' => FolderStatus.conflict,
      _ => FolderStatus.missing,
    };
  }
}

class Patient {
  final String id;
  final String name;
  final String? driveFolderId;
  final FolderStatus folderStatus;

  const Patient({
    required this.id,
    required this.name,
    this.driveFolderId,
    this.folderStatus = FolderStatus.available,
  });

  /// True if photos can be captured and uploaded for this patient.
  bool get isUploadable =>
      folderStatus == FolderStatus.available &&
      driveFolderId != null &&
      driveFolderId!.isNotEmpty;

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

    return Patient(
      id: incoming.id,
      name: incoming.name.isNotEmpty ? incoming.name : existing.name,
      driveFolderId: mergedFolderId,
      folderStatus: mergedStatus,
    );
  }

  /// Creates a Patient from a single row map (legacy/helper).
  static Patient? fromRow({
    required Map<String, dynamic> rowMap,
    required String idCol,
    required String nameCol,
    required String folderCol,
  }) {
    final rawId = rowMap[idCol]?.toString().trim() ?? '';
    final rawName = rowMap[nameCol]?.toString().trim() ?? '';
    final rawFolder = rowMap[folderCol]?.toString().trim() ?? '';

    if (rawId.isEmpty || rawName.isEmpty) {
      return null;
    }

    if (rawFolder.isEmpty) {
      return Patient(
        id: rawId,
        name: rawName,
        driveFolderId: null,
        folderStatus: FolderStatus.missing,
      );
    }

    return Patient(
      id: rawId,
      name: rawName,
      driveFolderId: rawFolder,
      folderStatus: FolderStatus.available,
    );
  }

  /// Convert to SQLite map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'drive_folder_id': driveFolderId,
      'folder_status': folderStatus.name,
    };
  }

  /// Create from SQLite map
  factory Patient.fromMap(Map<String, dynamic> map) {
    return Patient(
      id: map['id'] as String,
      name: map['name'] as String,
      driveFolderId: map['drive_folder_id'] as String?,
      folderStatus: FolderStatus.fromString(
        map['folder_status'] as String? ?? 'available',
      ),
    );
  }

  Patient copyWith({
    String? id,
    String? name,
    String? driveFolderId,
    FolderStatus? folderStatus,
  }) {
    return Patient(
      id: id ?? this.id,
      name: name ?? this.name,
      driveFolderId: driveFolderId ?? this.driveFolderId,
      folderStatus: folderStatus ?? this.folderStatus,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Patient &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          driveFolderId == other.driveFolderId &&
          folderStatus == other.folderStatus;

  @override
  int get hashCode =>
      id.hashCode ^ name.hashCode ^ driveFolderId.hashCode ^ folderStatus.hashCode;

  @override
  String toString() =>
      'Patient(id: $id, name: $name, driveFolderId: $driveFolderId, status: ${folderStatus.name})';
}
