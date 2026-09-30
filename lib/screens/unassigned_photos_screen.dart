import 'package:flutter/material.dart';
import '../models/capture_session.dart';
import '../services/database.dart';
import '../services/patient_folder_service.dart';
import '../services/upload_queue.dart';
import '../widgets/patient_assignment_sheet.dart';
import '../widgets/unassigned_session_tile.dart';
import 'session_detail_screen.dart';

class UnassignedPhotosScreen extends StatefulWidget {
  final AppDatabase database;
  final UploadQueueService queueService;
  final PatientFolderService? folderService;

  const UnassignedPhotosScreen({
    super.key,
    required this.database,
    required this.queueService,
    this.folderService,
  });

  @override
  State<UnassignedPhotosScreen> createState() => _UnassignedPhotosScreenState();
}

class _UnassignedPhotosScreenState extends State<UnassignedPhotosScreen> {
  List<CaptureSession> _sessions = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final list = await widget.database.getUnassignedSessions();
    if (mounted) {
      setState(() {
        _sessions = list;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleViewPhotos(CaptureSession session) async {
    final updated = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SessionDetailScreen(
          session: session,
          database: widget.database,
          queueService: widget.queueService,
          folderService: widget.folderService,
        ),
      ),
    );

    if (updated == true) {
      _loadSessions();
    }
  }

  Future<void> _handleAssign(CaptureSession session) async {
    final assigned = await PatientAssignmentSheet.show(
      context,
      sessionId: session.id,
      database: widget.database,
      queueService: widget.queueService,
      folderService: widget.folderService,
    );

    if (assigned == true) {
      _loadSessions();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Unassigned Photos'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.inbox_outlined,
                        size: 56,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'All Photos Assigned',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'There are no pending unassigned photo sessions.',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    return UnassignedSessionTile(
                      session: session,
                      onViewPhotos: () => _handleViewPhotos(session),
                      onAssign: () => _handleAssign(session),
                    );
                  },
                ),
    );
  }
}
