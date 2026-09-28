import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';

class DriveService {
  /// Uploads a local photo to the specified patient Google Drive folder.
  ///
  /// Returns the Drive file ID of the uploaded photo.
  Future<String> uploadPhoto({
    required AuthClient client,
    required File file,
    required String folderId,
    required String fileName,
  }) async {
    final driveApi = drive.DriveApi(client);

    final fileMetadata = drive.File()
      ..name = fileName
      ..parents = [folderId];

    final media = drive.Media(
      file.openRead(),
      file.lengthSync(),
      contentType: 'image/jpeg',
    );

    try {
      final response = await driveApi.files.create(
        fileMetadata,
        uploadMedia: media,
        $fields: 'id, name',
      );

      final fileId = response.id;
      if (fileId == null || fileId.isEmpty) {
        throw drive.DetailedApiRequestError(
          500,
          'Google Drive file creation succeeded but returned no file ID.',
        );
      }

      debugPrint('Photo uploaded successfully to Drive folder $folderId: $fileId');
      return fileId;
    } catch (e) {
      debugPrint('Drive upload error for $fileName to folder $folderId: $e');
      rethrow;
    }
  }
}
