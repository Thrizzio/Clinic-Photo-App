import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../models/patient.dart';
import '../services/upload_queue.dart';
import '../widgets/upload_status.dart';

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
  FlashMode _flashMode = FlashMode.auto;
  String? _errorMessage;

  bool get _isUnassigned => widget.sessionId != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cameraController = _controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
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

      if (mounted) {
        setState(() {
          _controller = controller;
          _isCameraInitialized = true;
          _errorMessage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Camera initialization failed: $e';
        });
      }
    }
  }

  Future<void> _toggleFlash() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    final nextMode = switch (_flashMode) {
      FlashMode.auto => FlashMode.always,
      FlashMode.always => FlashMode.off,
      FlashMode.off => FlashMode.auto,
      _ => FlashMode.auto,
    };

    try {
      await _controller!.setFlashMode(nextMode);
      setState(() {
        _flashMode = nextMode;
      });
    } catch (_) {}
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

      if (_isUnassigned) {
        debugPrint('CAPTURE: enqueuing unassigned photo for session ${widget.sessionId}');
        await widget.queueService.enqueueUnassignedPhoto(
          sessionId: widget.sessionId!,
          capturedTempPath: xFile.path,
        );
      } else {
        debugPrint('CAPTURE: enqueuing photo for patient ${widget.patient!.id}');
        await widget.queueService.enqueuePhoto(
          patient: widget.patient!,
          capturedTempPath: xFile.path,
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
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
    );
  }

  Widget _buildHeader() {
    final title = _isUnassigned ? 'New / Unassigned Patient' : widget.patient!.name;
    final subtitle = _isUnassigned ? 'Unassigned Photo Session' : 'ID: ${widget.patient!.id}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.black87,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(_sessionPhotoCount),
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
              ],
            ),
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

    return ClipRect(
      child: AspectRatio(
        aspectRatio: _controller!.value.aspectRatio,
        child: CameraPreview(_controller!),
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
          // Minimal non-intrusive upload status pill
          UploadStatusPill(queueService: widget.queueService, isDarkBackground: true),
          const SizedBox(height: 16),

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
                onPressed: () => Navigator.of(context).pop(_sessionPhotoCount),
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
