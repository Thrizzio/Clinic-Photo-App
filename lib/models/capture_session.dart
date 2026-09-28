class CaptureSession {
  final String id;
  final String? patientId;
  final DateTime createdAt;
  final String status; // 'unassigned', 'assigned', 'completed'
  final int photoCount;

  const CaptureSession({
    required this.id,
    this.patientId,
    required this.createdAt,
    this.status = 'unassigned',
    this.photoCount = 0,
  });

  bool get isUnassigned => status == 'unassigned';

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'patient_id': patientId,
      'created_at': createdAt.toIso8601String(),
      'status': status,
    };
  }

  factory CaptureSession.fromMap(Map<String, dynamic> map, {int photoCount = 0}) {
    return CaptureSession(
      id: map['id'] as String,
      patientId: map['patient_id'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      status: map['status'] as String? ?? 'unassigned',
      photoCount: (map['photo_count'] as num?)?.toInt() ?? photoCount,
    );
  }

  CaptureSession copyWith({
    String? id,
    String? patientId,
    DateTime? createdAt,
    String? status,
    int? photoCount,
  }) {
    return CaptureSession(
      id: id ?? this.id,
      patientId: patientId ?? this.patientId,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      photoCount: photoCount ?? this.photoCount,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CaptureSession &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          patientId == other.patientId &&
          createdAt == other.createdAt &&
          status == other.status &&
          photoCount == other.photoCount;

  @override
  int get hashCode =>
      id.hashCode ^
      patientId.hashCode ^
      createdAt.hashCode ^
      status.hashCode ^
      photoCount.hashCode;

  @override
  String toString() =>
      'CaptureSession(id: $id, patient: $patientId, status: $status, photos: $photoCount)';
}
