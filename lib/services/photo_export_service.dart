import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class PhotoExportService {
  /// Saves an image to the device's public photo gallery using scoped MediaStore.
  ///
  /// Returns `true` if saved successfully. Throws on permanent failure or denied permissions.
  Future<bool> saveToGallery({
    String? filePath,
    Uint8List? bytes,
    String? fileName,
    String album = 'Clinic Photos',
  }) async {
    String resolvedPath = filePath ?? '';

    // If only bytes provided or path is empty, save to temporary cache file first
    if (resolvedPath.isEmpty || !File(resolvedPath).existsSync()) {
      if (bytes == null || bytes.isEmpty) {
        throw ArgumentError('Either valid filePath or non-empty bytes must be provided');
      }
      final tempDir = await getTemporaryDirectory();
      final exportDir = Directory(p.join(tempDir.path, 'gallery_export'));
      if (!exportDir.existsSync()) {
        exportDir.createSync(recursive: true);
      }
      final name = fileName ?? 'export_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final tempFile = File(p.join(exportDir.path, name));
      await tempFile.writeAsBytes(bytes, flush: true);
      resolvedPath = tempFile.path;
    }

    // Check permissions
    final hasAccess = await Gal.hasAccess(toAlbum: true);
    if (!hasAccess) {
      final granted = await Gal.requestAccess(toAlbum: true);
      if (!granted) {
        throw Exception('Permission to access gallery was denied. Please grant gallery permissions in device settings.');
      }
    }

    await Gal.putImage(resolvedPath, album: album);
    return true;
  }

  /// Shares a single photo via the standard Android share sheet (ACTION_SEND / Content URI).
  Future<ShareResult> shareSinglePhoto({
    String? filePath,
    Uint8List? bytes,
    required String fileName,
    String? text,
    String? subject,
  }) async {
    final xFile = await _resolveXFile(
      filePath: filePath,
      bytes: bytes,
      fileName: fileName,
    );

    return await SharePlus.instance.share(
      ShareParams(
        files: [xFile],
        text: text,
        subject: subject,
      ),
    );
  }

  /// Shares multiple photos via the standard Android share sheet (ACTION_SEND_MULTIPLE).
  Future<ShareResult> shareMultiplePhotos({
    required List<({String? filePath, Uint8List? bytes, String fileName})> photos,
    String? text,
    String? subject,
  }) async {
    if (photos.isEmpty) {
      throw ArgumentError('Cannot share an empty list of photos');
    }

    final List<XFile> xFiles = [];
    for (final photo in photos) {
      final xFile = await _resolveXFile(
        filePath: photo.filePath,
        bytes: photo.bytes,
        fileName: photo.fileName,
      );
      xFiles.add(xFile);
    }

    return await SharePlus.instance.share(
      ShareParams(
        files: xFiles,
        text: text,
        subject: subject,
      ),
    );
  }

  Future<XFile> _resolveXFile({
    String? filePath,
    Uint8List? bytes,
    required String fileName,
  }) async {
    if (filePath != null && filePath.isNotEmpty && File(filePath).existsSync()) {
      return XFile(filePath, name: fileName, mimeType: 'image/jpeg');
    }

    if (bytes != null && bytes.isNotEmpty) {
      final tempDir = await getTemporaryDirectory();
      final sharedDir = Directory(p.join(tempDir.path, 'shared_photos'));
      if (!sharedDir.existsSync()) {
        sharedDir.createSync(recursive: true);
      }
      final tempFile = File(p.join(sharedDir.path, fileName));
      await tempFile.writeAsBytes(bytes, flush: true);
      return XFile(tempFile.path, name: fileName, mimeType: 'image/jpeg');
    }

    throw ArgumentError('Unable to resolve photo file: both filePath and bytes were invalid.');
  }
}
