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

  /// Searches for non-trashed folders with the exact given name inside the specified parent folder.
  Future<List<drive.File>> findFoldersByName({
    required AuthClient client,
    required String parentFolderId,
    required String folderName,
  }) async {
    final driveApi = drive.DriveApi(client);
    final safeName = folderName.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final query =
        "mimeType = 'application/vnd.google-apps.folder' and '$parentFolderId' in parents and name = '$safeName' and trashed = false";

    final fileList = await driveApi.files.list(
      q: query,
      $fields: 'files(id, name)',
    );

    return fileList.files ?? <drive.File>[];
  }

  /// Creates a new Google Drive folder with [folderName] inside [parentFolderId].
  Future<String> createFolder({
    required AuthClient client,
    required String parentFolderId,
    required String folderName,
  }) async {
    final driveApi = drive.DriveApi(client);
    final folderMetadata = drive.File()
      ..name = folderName
      ..mimeType = 'application/vnd.google-apps.folder'
      ..parents = [parentFolderId];

    final created = await driveApi.files.create(
      folderMetadata,
      $fields: 'id, name',
    );

    final id = created.id;
    if (id == null || id.isEmpty) {
      throw drive.DetailedApiRequestError(
        500,
        'Google Drive folder creation succeeded but returned no ID.',
      );
    }

    debugPrint('Created Drive folder "$folderName" under parent $parentFolderId: $id');
    return id;
  }

  /// Lists image files stored in a patient's Drive folder.
  Future<List<drive.File>> listPatientPhotos({
    required AuthClient client,
    required String folderId,
  }) async {
    final driveApi = drive.DriveApi(client);
    final query =
        "'$folderId' in parents and trashed = false and mimeType contains 'image/'";

    final fileList = await driveApi.files.list(
      q: query,
      $fields: 'files(id, name, createdTime, thumbnailLink, webContentLink, size)',
      orderBy: 'name asc',
      pageSize: 100,
    );

    return fileList.files ?? <drive.File>[];
  }

  /// Fetches raw file bytes for preview (thumbnail or full image).
  Future<Uint8List> getFileBytes({
    required AuthClient client,
    required String fileId,
  }) async {
    final driveApi = drive.DriveApi(client);
    final media = await driveApi.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;

    final List<int> bytes = [];
    await for (final chunk in media.stream) {
      bytes.addAll(chunk);
    }
    return Uint8List.fromList(bytes);
  }

  /// Verifies read/write access to a Drive folder (e.g. parent folder).
  Future<bool> verifyFolderAccess({
    required AuthClient client,
    required String folderId,
  }) async {
    final driveApi = drive.DriveApi(client);
    try {
      final file = await driveApi.files.get(
        folderId,
        $fields: 'id, name, mimeType',
      ) as drive.File;
      return file.id != null && file.mimeType == 'application/vnd.google-apps.folder';
    } catch (e) {
      debugPrint('verifyFolderAccess failed for $folderId: $e');
      return false;
    }
  }

  /// Lists all Google Spreadsheets accessible by the user's Google account.
  Future<List<drive.File>> listSpreadsheets({
    required AuthClient client,
  }) async {
    final driveApi = drive.DriveApi(client);
    try {
      final response = await driveApi.files.list(
        q: "mimeType = 'application/vnd.google-apps.spreadsheet' and trashed = false",
        $fields: 'files(id, name, webViewLink)',
        pageSize: 50,
      );
      return response.files ?? [];
    } catch (e) {
      debugPrint('listSpreadsheets failed: $e');
      return [];
    }
  }
}
