import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/capture_session.dart';
import '../models/upload_item.dart';
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
  Map<String, List<UploadItem>> _sessionPhotos = {};
  bool _isLoading = true;
  final Map<String, Uint8List> _thumbnailCache = {};

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final list = await widget.database.getUnassignedSessions();
    final Map<String, List<UploadItem>> photosMap = {};
    for (final s in list) {
      photosMap[s.id] = await widget.database.getUploadsForSession(s.id);
    }

    if (mounted) {
      setState(() {
        _sessions = list;
        _sessionPhotos = photosMap;
        _isLoading = false;
      });
    }
  }

  Future<Uint8List?> _fetchThumbnailBytes(String fileId) async {
    if (_thumbnailCache.containsKey(fileId)) return _thumbnailCache[fileId];
    try {
      final client = await widget.queueService.authService.getAuthenticatedClient();
      if (client == null) return null;
      final bytes = await widget.queueService.driveService.getFileBytes(client: client, fileId: fileId);
      _thumbnailCache[fileId] = bytes;
      return bytes;
    } catch (_) {
      return null;
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

  Future<void> _handleDeleteSession(CaptureSession session) async {
    final count = session.photoCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Unassigned Session?'),
        content: Text(
          'Permanently delete this session and its $count ${count == 1 ? 'photo' : 'photos'} from Google Drive and device storage?\n\n'
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete Session'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Deleting unassigned session...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      await widget.queueService.deleteUnassignedSession(session.id);
      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unassigned session deleted'),
            backgroundColor: Colors.green,
          ),
        );
        _loadSessions();
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete session: $e'),
            backgroundColor: Colors.red,
          ),
        );
        _loadSessions();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Unassigned Photos'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadSessions,
          ),
        ],
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
                    final photos = _sessionPhotos[session.id] ?? const [];
                    return UnassignedSessionTile(
                      session: session,
                      photos: photos,
                      fetchImageBytes: _fetchThumbnailBytes,
                      onViewPhotos: () => _handleViewPhotos(session),
                      onAssign: () => _handleAssign(session),
                      onDelete: () => _handleDeleteSession(session),
                    );
                  },
                ),
    );
  }
}

