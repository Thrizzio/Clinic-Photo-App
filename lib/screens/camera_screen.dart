import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../models/patient.dart';
import '../models/upload_item.dart';
import '../services/upload_queue.dart';
import '../widgets/reference_overlay.dart';

class CameraScreen extends StatefulWidget {
  final Patient? patient;
  final String? sessionId;
  final UploadQueueService queueService;

  const CameraScreen({
    super.key,
    this.patient,
    this.sessionId,
    required this.queueService,
  }) : assert(patient != null || sessionId != null, 'Either patient or sessionId must be provided');

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  bool _isCameraInitialized = false;
  bool _isTakingPhoto = false;
  int _sessionPhotoCount = 0;
  int _sequenceNumber = 0;
  FlashMode _flashMode = FlashMode.auto;
  String? _errorMessage;
  bool _isPopping = false;
  bool _exitRequested = false;
  bool _isInitializingCamera = false;
  int _cameraGeneration = 0;
  bool _isAppResumed = true;
  Patient? _currentPatient;
  Uint8List? _referenceBytes;
  double _referenceOpacity = 0.35;

  bool get _isUnassigned => widget.sessionId != null;

  Future<void> _handleExit() async {
    if (_isPopping) return;
    if (_isTakingPhoto) {
      _exitRequested = true;
      return;
    }
    _isPopping = true;
    Navigator.of(context).pop(_sessionPhotoCount);
  }

  @override
  void initState() {
    super.initState();
    _currentPatient = widget.patient;
    widget.queueService.addListener(_onQueueUpdated);
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void dispose() {
    widget.queueService.removeListener(_onQueueUpdated);
    WidgetsBinding.instance.removeObserver(this);
    _isAppResumed = false;
    _cameraGeneration++;
    final controller = _controller;
    _controller = null;
    unawaited(controller?.dispose());
    super.dispose();
  }

  Future<void> _onQueueUpdated() async {
    if (!mounted || _isUnassigned || _currentPatient == null) return;
    if (_currentPatient!.driveFolderId != null &&
        _currentPatient!.driveFolderId!.trim().isNotEmpty) {
      return;
    }
    final updated = await widget.queueService.database.getPatient(_currentPatient!.id);
    if (updated != null &&
        updated.driveFolderId != null &&
        updated.driveFolderId!.trim().isNotEmpty &&
        mounted) {
      setState(() {
        _currentPatient = updated;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _isAppResumed = true;
      unawaited(_initializeCamera());
    } else {
      // Flutter can report inactive -> hidden -> paused while the app is
      // backgrounded. Dispose for every non-resumed state and invalidate any
      // in-flight initialization so a stale controller is never installed.
      _isAppResumed = false;
      _cameraGeneration++;
      final cameraController = _controller;
      _isCameraInitialized = false;
      _controller = null;
      if (cameraController != null) unawaited(cameraController.dispose());
    }
  }

  Future<void> _initializeCamera() async {
    if (_isInitializingCamera || _isPopping || !_isAppResumed) return;
    _isInitializingCamera = true;
    final generation = ++_cameraGeneration;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted && generation == _cameraGeneration && _isAppResumed) {
          setState(() {
            _errorMessage = 'No camera found on this device.';
          });
        }
        return;
      }

      // Select back camera
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();
      try {
        await controller.setFlashMode(_flashMode);
      } catch (_) {}

       if (!mounted ||
           generation != _cameraGeneration ||
           !_isAppResumed ||
           _isPopping) {
         await controller.dispose();
         return;
       }

       final previous = _controller;
       if (mounted) {
        setState(() {
          _controller = controller;
          _isCameraInitialized = true;
          _errorMessage = null;
        });
      }
      if (previous != null && !identical(previous, controller)) {
        unawaited(previous.dispose());
      }
    } catch (e) {
      if (mounted && generation == _cameraGeneration && _isAppResumed) {
        setState(() {
          _errorMessage = 'Camera initialization failed: $e';
        });
      }
    } finally {
      _isInitializingCamera = false;
      // If resume arrived while an initialization invalidated by pause was
      // still unwinding, the resume callback saw _isInitializingCamera and
      // returned. Start the fresh generation now instead of leaving the
      // camera permanently uninitialized.
      if (mounted &&
          _isAppResumed &&
          !_isPopping &&
          generation != _cameraGeneration &&
          _controller == null) {
        unawaited(_initializeCamera());
      }
    }
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final nextMode = switch (_flashMode) {
      FlashMode.auto => FlashMode.always,
      FlashMode.always => FlashMode.off,
      FlashMode.off => FlashMode.auto,
      _ => FlashMode.auto,
    };

    try {
      await controller.setFlashMode(nextMode);
      if (!mounted || !identical(_controller, controller)) return;
      setState(() {
        _flashMode = nextMode;
      });
    } catch (_) {}
  }

  Future<void> _openReferencePicker() async {
    final patient = _currentPatient ?? widget.patient;
    if (_isUnassigned || patient == null) return;

    final uploads = await widget.queueService.database.getUploadsForPatient(patient.id);
    final candidates = uploads
        .where((item) =>
            (item.localPath.isNotEmpty && File(item.localPath).existsSync()) ||
            (item.driveFileId != null && item.driveFileId!.isNotEmpty))
        .toList()
      ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));

    if (!mounted) return;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No previous local or Drive photos are available as a reference.')),
      );
      return;
    }

    final selected = await showModalBottomSheet<UploadItem>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.7,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Choose reference photo',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: candidates.length,
                  itemBuilder: (_, index) {
                    final item = candidates[index];
                    final local = item.localPath.isNotEmpty ? File(item.localPath) : null;
                    return ListTile(
                      leading: SizedBox(
                        width: 56,
                        height: 56,
                        child: local != null && local.existsSync()
                            ? Image.file(local, fit: BoxFit.cover)
                            : const Icon(Icons.cloud_outlined),
                      ),
                      title: Text(item.fileName),
                      subtitle: Text('Captured ${item.capturedAt.toLocal()}'),
                      onTap: () => Navigator.of(sheetContext).pop(item),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (selected != null) await _loadReference(selected);
  }

  Future<void> _loadReference(UploadItem item) async {
    Uint8List? bytes;
    final localFile = item.localPath.isNotEmpty ? File(item.localPath) : null;
    if (localFile != null && localFile.existsSync()) {
      bytes = await localFile.readAsBytes();
    } else if (item.driveFileId != null && item.driveFileId!.isNotEmpty) {
      final client = await widget.queueService.authService.getAuthenticatedClient();
      if (client != null) {
        try {
          bytes = await widget.queueService.driveService.getFileBytes(
            client: client,
            fileId: item.driveFileId!,
          );
        } catch (e) {
          debugPrint('Reference image download failed: $e');
        }
      }
    }

    if (!mounted) return;
    if (bytes == null || bytes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The selected reference photo is no longer available.')),
      );
      return;
    }
    setState(() {
      _referenceBytes = bytes;
      _referenceOpacity = 0.35;
    });
  }

  void _clearReference() {
    if (!mounted) return;
    setState(() {
      _referenceBytes = null;
    });
  }

  /// Rapid shutter press operation.
  ///
  /// CRITICAL REQUIREMENT: Persists image locally and enqueues upload without
  /// waiting for Google Drive. Upload work must never block the camera UI.
  Future<void> _capturePhoto() async {
    final controller = _controller;
    debugPrint('CAPTURE: shutter pressed');

    if (controller == null) {
      debugPrint('CAPTURE BLOCKED: controller is null');
      return;
    }
    if (!controller.value.isInitialized) {
      debugPrint('CAPTURE BLOCKED: controller is not initialized');
      return;
    }
    if (_isTakingPhoto) {
      debugPrint('CAPTURE BLOCKED: already capturing photo');
      return;
    }

    setState(() {
      _isTakingPhoto = true;
    });

    try {
      debugPrint('CAPTURE: calling controller.takePicture()');
      final xFile = await controller.takePicture();
      debugPrint('CAPTURE: takePicture returned ${xFile.path}');

      _sequenceNumber++;
      final capturedAt = DateTime.now();

      if (_isUnassigned) {
        debugPrint('CAPTURE: enqueuing unassigned photo for session ${widget.sessionId}');
        await widget.queueService.enqueueUnassignedPhoto(
          sessionId: widget.sessionId!,
          capturedTempPath: xFile.path,
          capturedAt: capturedAt,
          sequenceNumber: _sequenceNumber,
        );
      } else {
        final target = _currentPatient ?? widget.patient!;
        debugPrint('CAPTURE: enqueuing photo for patient ${target.id}');
        await widget.queueService.enqueuePhoto(
          patient: target,
          capturedTempPath: xFile.path,
          sessionId: widget.sessionId,
          capturedAt: capturedAt,
          sequenceNumber: _sequenceNumber,
        );
      }

      debugPrint('CAPTURE: photo successfully persisted and enqueued');

      if (mounted) {
        setState(() {
          _sessionPhotoCount++;
        });
      }
    } catch (e, stackTrace) {
      debugPrint('CAPTURE ERROR: $e\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save photo: $e'),
            backgroundColor: Colors.red.shade800,
            duration: const Duration(seconds: 4),
          ),
        );
      }
      } finally {
        if (mounted) {
          setState(() {
            _isTakingPhoto = false;
          });
          if (_exitRequested) {
            _exitRequested = false;
            unawaited(_handleExit());
          }
        }
      }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleExit());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              // Top Header: Patient Context & Controls
              _buildHeader(),

              // Camera Viewport
              Expanded(
                child: _buildCameraViewport(),
              ),

              // Bottom Shutter & Status Controls
              _buildBottomControls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final effectivePatient = _currentPatient ?? widget.patient;
    final title = _isUnassigned ? 'Unassigned Session' : (effectivePatient?.displayName ?? 'Patient Photos');
    final subtitle = _isUnassigned
        ? 'Unassigned Photo Session'
        : (effectivePatient?.phoneDisplay != null && effectivePatient!.phoneDisplay!.isNotEmpty
            ? effectivePatient.phoneDisplay!
            : 'Clinical Photos');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.black87,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _handleExit,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (!_isUnassigned &&
                    effectivePatient != null &&
                    (effectivePatient.driveFolderId == null ||
                        effectivePatient.driveFolderId!.trim().isEmpty)) ...[
                  const SizedBox(height: 2),
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome, size: 12, color: Colors.lightBlueAccent),
                      SizedBox(width: 4),
                      Text(
                        'Folder auto-creates on photo capture',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.lightBlueAccent,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.layers_outlined, color: Colors.white),
            tooltip: 'Reference photo',
            onPressed: _isUnassigned ? null : _openReferencePicker,
          ),
          IconButton(
            icon: Icon(
              switch (_flashMode) {
                FlashMode.auto => Icons.flash_auto,
                FlashMode.always => Icons.flash_on,
                FlashMode.off => Icons.flash_off,
                _ => Icons.flash_auto,
              },
              color: Colors.white,
            ),
            onPressed: _toggleFlash,
          ),
        ],
      ),
    );
  }

  Widget _buildCameraViewport() {
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _initializeCamera,
                child: const Text('Retry Camera'),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isCameraInitialized || _controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    final controller = _controller!;
    final isFrontCamera = controller.description.lensDirection == CameraLensDirection.front;

    return ClipRect(
      child: CameraPreview(
        controller,
        // CameraPreview owns the aspect-ratio and rotation transform. Keeping
        // the reference as its child makes both layers use the same displayed
        // viewport; the overlay remains Flutter-only and is never captured by
        // CameraController.takePicture().
        child: _referenceBytes == null
            ? null
            : ReferenceOverlay(
                imageBytes: _referenceBytes!,
                opacity: _referenceOpacity,
                mirror: isFrontCamera,
                onOpacityChanged: (value) => setState(() => _referenceOpacity = value),
                onClear: _clearReference,
              ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Photo Counter Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white24, width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.photo_camera, size: 16, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(
                      '$_sessionPhotoCount taken',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),

              // Tactical High-Responsiveness Shutter Button
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _capturePhoto,
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                  ),
                  child: Center(
                    child: Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isTakingPhoto ? Colors.grey : Colors.white,
                      ),
                    ),
                  ),
                ),
              ),

              // Done Button
              TextButton(
                onPressed: _handleExit,
                style: TextButton.styleFrom(
                  backgroundColor: Colors.white12,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: const Text(
                  'Done',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
