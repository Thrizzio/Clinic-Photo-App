import 'dart:typed_data';

import 'package:flutter/material.dart';

/// A camera-only reference layer. It is rendered by Flutter above the live
/// preview and is therefore never included in CameraController.takePicture().
class ReferenceOverlay extends StatelessWidget {
  final Uint8List imageBytes;
  final double opacity;
  final ValueChanged<double> onOpacityChanged;
  final VoidCallback onClear;

  const ReferenceOverlay({
    super.key,
    required this.imageBytes,
    required this.opacity,
    required this.onOpacityChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: Opacity(
            opacity: opacity,
            child: Image.memory(
              imageBytes,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
            ),
          ),
        ),
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: Material(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.layers, color: Colors.white, size: 18),
                  const SizedBox(width: 6),
                  const Text(
                    'Reference',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                  Expanded(
                    child: Slider(
                      key: const Key('reference_opacity_slider'),
                      value: opacity,
                      min: 0.05,
                      max: 0.9,
                      onChanged: onOpacityChanged,
                    ),
                  ),
                  IconButton(
                    key: const Key('clear_reference_button'),
                    tooltip: 'Clear reference',
                    onPressed: onClear,
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
