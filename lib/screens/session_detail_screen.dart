import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/capture_session.dart';
import '../models/upload_item.dart';
import '../services/database.dart';
import '../services/upload_queue.dart';
import '../widgets/patient_assignment_sheet.dart';

class SessionDetailScreen extends StatefulWidget {
  final CaptureSession session;
  final AppDatabase database;
  final UploadQueueService queueService;

  const SessionDetailScreen({
    super.key,
    required this.session,
    required this.database,
    required this.queueService,
  });

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  List<UploadItem> _photos = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    final photos = await widget.database.getUploadsForSession(widget.session.id);
    if (mounted) {
      setState(() {
        _photos = photos;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleAssign() async {
    final assigned = await PatientAssignmentSheet.show(
      context,
      sessionId: widget.session.id,
      database: widget.database,
      queueService: widget.queueService,
    );

    if (assigned == true && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateFormatted = DateFormat('MMM d, yyyy • h:mm a').format(widget.session.createdAt);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Session Photos'),
        actions: [
          TextButton.icon(
            onPressed: _handleAssign,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('Assign'),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dateFormatted,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_photos.length} ${_photos.length == 1 ? 'photo' : 'photos'} captured in this session',
                        style: TextStyle(
                          fontSize: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _photos.isEmpty
                      ? const Center(child: Text('No photos in this session.'))
                      : GridView.builder(
                          padding: const EdgeInsets.all(12),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                          itemCount: _photos.length,
                          itemBuilder: (context, index) {
                            final photo = _photos[index];
                            final file = File(photo.localPath);
                            return ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: file.existsSync()
                                  ? Image.file(
                                      file,
                                      fit: BoxFit.cover,
                                    )
                                  : Container(
                                      color: Colors.grey.shade300,
                                      child: const Icon(Icons.broken_image),
                                    ),
                            );
                          },
                        ),
                ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _handleAssign,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('Assign to Patient'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
      ),
    );
  }
}
