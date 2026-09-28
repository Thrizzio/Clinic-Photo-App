enum UploadStatus {
  waiting,
  uploading,
  failed;

  static UploadStatus fromString(String value) {
    return switch (value.toLowerCase()) {
      'uploading' => UploadStatus.uploading,
      'failed' => UploadStatus.failed,
      _ => UploadStatus.waiting,
    };
  }
}

class UploadItem {
  final String id;
  final String patientId;
  final String driveFolderId;
  final String localPath;
  final String fileName;
  final UploadStatus status;
  final int retryCount;
  final String? lastError;
  final String? driveFileId;
  final DateTime createdAt;

  const UploadItem({
    required this.id,
    required this.patientId,
    required this.driveFolderId,
    required this.localPath,
    required this.fileName,
    this.status = UploadStatus.waiting,
    this.retryCount = 0,
    this.lastError,
    this.driveFileId,
    required this.createdAt,
  });

  UploadItem copyWith({
    String? id,
    String? patientId,
    String? driveFolderId,
    String? localPath,
    String? fileName,
    UploadStatus? status,
    int? retryCount,
    String? lastError,
    bool clearLastError = false,
    String? driveFileId,
    bool clearDriveFileId = false,
    DateTime? createdAt,
  }) {
    return UploadItem(
      id: id ?? this.id,
      patientId: patientId ?? this.patientId,
      driveFolderId: driveFolderId ?? this.driveFolderId,
      localPath: localPath ?? this.localPath,
      fileName: fileName ?? this.fileName,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      driveFileId: clearDriveFileId ? null : (driveFileId ?? this.driveFileId),
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'patient_id': patientId,
      'drive_folder_id': driveFolderId,
      'local_path': localPath,
      'file_name': fileName,
      'status': status.name,
      'retry_count': retryCount,
      'last_error': lastError,
      'drive_file_id': driveFileId,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory UploadItem.fromMap(Map<String, dynamic> map) {
    return UploadItem(
      id: map['id'] as String,
      patientId: map['patient_id'] as String,
      driveFolderId: map['drive_folder_id'] as String,
      localPath: map['local_path'] as String,
      fileName: map['file_name'] as String,
      status: UploadStatus.fromString(map['status'] as String),
      retryCount: (map['retry_count'] as num?)?.toInt() ?? 0,
      lastError: map['last_error'] as String?,
      driveFileId: map['drive_file_id'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  @override
  String toString() =>
      'UploadItem(id: $id, patient: $patientId, status: ${status.name}, retries: $retryCount)';
}
