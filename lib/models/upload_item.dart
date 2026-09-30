enum UploadStatus {
  unassigned,
  waiting,
  uploading,
  failed;

  static UploadStatus fromString(String value) {
    return switch (value.toLowerCase()) {
      'unassigned' => UploadStatus.unassigned,
      'uploading' => UploadStatus.uploading,
      'failed' => UploadStatus.failed,
      _ => UploadStatus.waiting,
    };
  }
}

class UploadItem {
  final String id;
  final String? sessionId;
  final String? patientId;
  final String? driveFolderId;
  final String localPath;
  final String fileName;
  final UploadStatus status;
  final int retryCount;
  final String? lastError;
  final String? driveFileId;
  final DateTime createdAt;
  final DateTime capturedAt;
  final int sequenceNumber;

  UploadItem({
    required this.id,
    this.sessionId,
    this.patientId,
    String? driveFolderId,
    String? driveParentFolderId,
    required this.localPath,
    required this.fileName,
    this.status = UploadStatus.waiting,
    this.retryCount = 0,
    this.lastError,
    this.driveFileId,
    required this.createdAt,
    DateTime? capturedAt,
    this.sequenceNumber = 1,
  })  : driveFolderId = driveFolderId ?? driveParentFolderId,
        capturedAt = capturedAt ?? createdAt;

  String? get driveParentFolderId => driveFolderId;

  UploadItem copyWith({
    String? id,
    String? sessionId,
    String? patientId,
    String? driveFolderId,
    String? driveParentFolderId,
    String? localPath,
    String? fileName,
    UploadStatus? status,
    int? retryCount,
    String? lastError,
    bool clearLastError = false,
    String? driveFileId,
    bool clearDriveFileId = false,
    DateTime? createdAt,
    DateTime? capturedAt,
    int? sequenceNumber,
  }) {
    return UploadItem(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      patientId: patientId ?? this.patientId,
      driveFolderId: driveFolderId ?? driveParentFolderId ?? this.driveFolderId,
      localPath: localPath ?? this.localPath,
      fileName: fileName ?? this.fileName,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      driveFileId: clearDriveFileId ? null : (driveFileId ?? this.driveFileId),
      createdAt: createdAt ?? this.createdAt,
      capturedAt: capturedAt ?? this.capturedAt,
      sequenceNumber: sequenceNumber ?? this.sequenceNumber,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'session_id': sessionId,
      'patient_id': patientId,
      'drive_folder_id': driveFolderId,
      'drive_parent_folder_id': driveFolderId,
      'local_path': localPath,
      'file_name': fileName,
      'status': status.name,
      'retry_count': retryCount,
      'last_error': lastError,
      'drive_file_id': driveFileId,
      'created_at': createdAt.toIso8601String(),
      'captured_at': capturedAt.toIso8601String(),
      'sequence_number': sequenceNumber,
    };
  }

  factory UploadItem.fromMap(Map<String, dynamic> map) {
    final createdAt = DateTime.parse(map['created_at'] as String);
    return UploadItem(
      id: map['id'] as String,
      sessionId: map['session_id'] as String?,
      patientId: map['patient_id'] as String?,
      driveFolderId: (map['drive_folder_id'] ?? map['drive_parent_folder_id']) as String?,
      localPath: map['local_path'] as String,
      fileName: map['file_name'] as String,
      status: UploadStatus.fromString(map['status'] as String),
      retryCount: (map['retry_count'] as num?)?.toInt() ?? 0,
      lastError: map['last_error'] as String?,
      driveFileId: map['drive_file_id'] as String?,
      createdAt: createdAt,
      capturedAt: map['captured_at'] != null
          ? DateTime.parse(map['captured_at'] as String)
          : createdAt,
      sequenceNumber: (map['sequence_number'] as num?)?.toInt() ?? 1,
    );
  }

  @override
  String toString() =>
      'UploadItem(id: $id, session: $sessionId, patient: $patientId, status: ${status.name}, retries: $retryCount, seq: $sequenceNumber)';
}
