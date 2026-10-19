import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum CollageLayout {
  auto,
  horizontalComparison, // 2 images side-by-side
  grid,                 // 3-6 images in balanced grid
}

class CollageItem {
  final Uint8List bytes;
  final String? label;
  final DateTime? capturedAt;

  const CollageItem({
    required this.bytes,
    this.label,
    this.capturedAt,
  });
}

class CollageResult {
  final Uint8List bytes;
  final String filePath;
  final int width;
  final int height;

  const CollageResult({
    required this.bytes,
    required this.filePath,
    required this.width,
    required this.height,
  });
}

class CollageService {
  final int targetMaxDimension;
  final int gapSize;
  final img.ColorRgb8 backgroundColor;

  CollageService({
    this.targetMaxDimension = 2048,
    this.gapSize = 8,
    img.ColorRgb8? backgroundColor,
  }) : backgroundColor = backgroundColor ?? img.ColorRgb8(245, 245, 245);

  /// Creates a clinical collage from a list of 2 to 6 items.
  ///
  /// - For 2 images: generates a side-by-side horizontal comparison matching height.
  /// - For 3-6 images: generates a balanced grid layout preserving aspect ratios.
  /// Corrects EXIF orientation on every input image.
  Future<CollageResult> createCollage({
    required List<CollageItem> items,
    CollageLayout layout = CollageLayout.auto,
    String? outputFileName,
    Directory? outputDirectory,
  }) async {
    if (items.length < 2 || items.length > 6) {
      throw ArgumentError('Collage requires between 2 and 6 images. Received: ${items.length}');
    }

    // Decode and bake orientation off the UI thread via compute
    final result = await compute(_processCollageInIsolate, _CollageIsolateParams(
      items: items.map((e) => e.bytes).toList(),
      layout: layout,
      targetMaxDimension: targetMaxDimension,
      gapSize: gapSize,
      bgR: backgroundColor.r.toInt(),
      bgG: backgroundColor.g.toInt(),
      bgB: backgroundColor.b.toInt(),
    ));

    // Save to temp cache directory
    final baseDir = outputDirectory ?? await getTemporaryDirectory();
    final collageDir = Directory(p.join(baseDir.path, 'collages'));
    if (!collageDir.existsSync()) {
      collageDir.createSync(recursive: true);
    }

    final fileName = outputFileName ??
        'collage_${DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '_')}.jpg';
    final outFile = File(p.join(collageDir.path, fileName));
    await outFile.writeAsBytes(result.bytes, flush: true);

    return CollageResult(
      bytes: result.bytes,
      filePath: outFile.path,
      width: result.width,
      height: result.height,
    );
  }
}

class _CollageIsolateParams {
  final List<Uint8List> items;
  final CollageLayout layout;
  final int targetMaxDimension;
  final int gapSize;
  final int bgR;
  final int bgG;
  final int bgB;

  _CollageIsolateParams({
    required this.items,
    required this.layout,
    required this.targetMaxDimension,
    required this.gapSize,
    required this.bgR,
    required this.bgG,
    required this.bgB,
  });
}

class _IsolateResult {
  final Uint8List bytes;
  final int width;
  final int height;

  _IsolateResult({required this.bytes, required this.width, required this.height});
}

_IsolateResult _processCollageInIsolate(_CollageIsolateParams params) {
  final bg = img.ColorRgb8(params.bgR, params.bgG, params.bgB);

  // 1. Decode each image and bake EXIF orientation
  final List<img.Image> decodedImages = [];
  for (final raw in params.items) {
    final decoded = img.decodeImage(raw);
    if (decoded == null) {
      throw StateError('Failed to decode image for collage');
    }
    decodedImages.add(img.bakeOrientation(decoded));
  }

  img.Image canvas;

  final isTwoImages = decodedImages.length == 2;
  final useHorizontal = (params.layout == CollageLayout.horizontalComparison) ||
      (params.layout == CollageLayout.auto && isTwoImages);

  if (useHorizontal && isTwoImages) {
    // 2-image horizontal comparison
    canvas = _createSideBySide(
      img1: decodedImages[0],
      img2: decodedImages[1],
      targetMaxDimension: params.targetMaxDimension,
      gap: params.gapSize,
      bgColor: bg,
    );
  } else {
    // 3 to 6 images balanced grid
    canvas = _createGrid(
      images: decodedImages,
      targetMaxDimension: params.targetMaxDimension,
      gap: params.gapSize,
      bgColor: bg,
    );
  }

  final encodedBytes = Uint8List.fromList(img.encodeJpg(canvas, quality: 92));
  return _IsolateResult(
    bytes: encodedBytes,
    width: canvas.width,
    height: canvas.height,
  );
}

img.Image _createSideBySide({
  required img.Image img1,
  required img.Image img2,
  required int targetMaxDimension,
  required int gap,
  required img.ColorRgb8 bgColor,
}) {
  // Normalize both images to a shared height
  final int targetHeight = (targetMaxDimension * 0.75).round().clamp(800, targetMaxDimension);

  final double scale1 = targetHeight / img1.height;
  final int w1 = (img1.width * scale1).round();
  final resized1 = img.copyResize(img1, width: w1, height: targetHeight, interpolation: img.Interpolation.linear);

  final double scale2 = targetHeight / img2.height;
  final int w2 = (img2.width * scale2).round();
  final resized2 = img.copyResize(img2, width: w2, height: targetHeight, interpolation: img.Interpolation.linear);

  final int totalWidth = w1 + gap + w2;
  final canvas = img.Image(width: totalWidth, height: targetHeight);
  img.fill(canvas, color: bgColor);

  img.compositeImage(canvas, resized1, dstX: 0, dstY: 0);
  img.compositeImage(canvas, resized2, dstX: w1 + gap, dstY: 0);

  return canvas;
}

img.Image _createGrid({
  required List<img.Image> images,
  required int targetMaxDimension,
  required int gap,
  required img.ColorRgb8 bgColor,
}) {
  final count = images.length;
  int cols;
  int rows;

  if (count <= 3) {
    // Check if images are mostly portrait (height > width)
    final portraitCount = images.where((img) => img.height >= img.width).length;
    if (portraitCount >= 2) {
      cols = count;
      rows = 1;
    } else {
      cols = 2;
      rows = 2; // 1 top spanning or 2x2 with last empty
    }
  } else if (count == 4) {
    cols = 2;
    rows = 2;
  } else if (count == 5 || count == 6) {
    cols = 3;
    rows = 2;
  } else {
    cols = 3;
    rows = 2;
  }

  // Calculate cell dimension
  final int cellW = ((targetMaxDimension - (cols - 1) * gap) / cols).round().clamp(300, 1200);
  // Default 4:3 or 1:1 cell aspect ratio based on average aspect ratio
  double avgAspect = 0;
  for (final im in images) {
    avgAspect += im.width / im.height;
  }
  avgAspect /= count;

  final int cellH = (cellW / avgAspect).round().clamp(300, 1600);

  final int totalWidth = (cols * cellW) + ((cols - 1) * gap);
  final int totalHeight = (rows * cellH) + ((rows - 1) * gap);

  final canvas = img.Image(width: totalWidth, height: totalHeight);
  img.fill(canvas, color: bgColor);

  for (int i = 0; i < count; i++) {
    final c = i % cols;
    final r = i ~/ cols;

    final cellX = c * (cellW + gap);
    final cellY = r * (cellH + gap);

    final raw = images[i];
    // Scale image to fit within cell preserving aspect ratio (BoxFit.contain)
    final double scale = (cellW / raw.width).clamp(0.0, cellH / raw.height);
    final int fitW = (raw.width * scale).round();
    final int fitH = (raw.height * scale).round();

    final resized = img.copyResize(raw, width: fitW, height: fitH, interpolation: img.Interpolation.linear);

    // Center in cell
    final offsetX = cellX + ((cellW - fitW) ~/ 2);
    final offsetY = cellY + ((cellH - fitH) ~/ 2);

    img.compositeImage(canvas, resized, dstX: offsetX, dstY: offsetY);
  }

  return canvas;
}
