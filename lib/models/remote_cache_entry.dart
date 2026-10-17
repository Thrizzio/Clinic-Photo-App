class RemoteCacheEntry {
  final String driveFileId;
  final String cacheType; // 'thumbnail' | 'full'
  final String filePath;
  final int fileSize;
  final String? patientId;
  final DateTime createdAt;
  final DateTime lastAccessedAt;

  const RemoteCacheEntry({
    required this.driveFileId,
    required this.cacheType,
    required this.filePath,
    required this.fileSize,
    this.patientId,
    required this.createdAt,
    required this.lastAccessedAt,
  });

  Map<String, dynamic> toMap() => {
        'drive_file_id': driveFileId,
        'cache_type': cacheType,
        'file_path': filePath,
        'file_size': fileSize,
        'patient_id': patientId,
        'created_at': createdAt.toIso8601String(),
        'last_accessed_at': lastAccessedAt.toIso8601String(),
      };

  factory RemoteCacheEntry.fromMap(Map<String, dynamic> map) => RemoteCacheEntry(
        driveFileId: map['drive_file_id'] as String,
        cacheType: map['cache_type'] as String,
        filePath: map['file_path'] as String,
        fileSize: (map['file_size'] as num).toInt(),
        patientId: map['patient_id'] as String?,
        createdAt: DateTime.parse(map['created_at'] as String),
        lastAccessedAt: DateTime.parse(map['last_accessed_at'] as String),
      );

  RemoteCacheEntry copyWith({
    String? driveFileId,
    String? cacheType,
    String? filePath,
    int? fileSize,
    String? patientId,
    DateTime? createdAt,
    DateTime? lastAccessedAt,
  }) {
    return RemoteCacheEntry(
      driveFileId: driveFileId ?? this.driveFileId,
      cacheType: cacheType ?? this.cacheType,
      filePath: filePath ?? this.filePath,
      fileSize: fileSize ?? this.fileSize,
      patientId: patientId ?? this.patientId,
      createdAt: createdAt ?? this.createdAt,
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
    );
  }
}
