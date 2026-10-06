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
  /// Strictly verifies that returned folders are located within [parentFolderId].
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
      $fields: 'files(id, name, parents)',
    );

    final rawFiles = fileList.files ?? <drive.File>[];
    return rawFiles.where((f) {
      if (f.parents != null && f.parents!.isNotEmpty) {
        return f.parents!.contains(parentFolderId);
      }
      return true;
    }).toList();
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
      $fields: 'id, name, parents',
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

  /// Moves a file between folders on Drive server-side without re-downloading or re-uploading.
  Future<void> moveFile({
    required AuthClient client,
    required String fileId,
    required String sourceFolderId,
    required String targetFolderId,
  }) async {
    final driveApi = drive.DriveApi(client);
    await driveApi.files.update(
      drive.File(),
      fileId,
      addParents: targetFolderId,
      removeParents: sourceFolderId,
    );
    debugPrint('Moved Drive file $fileId from $sourceFolderId to $targetFolderId');
  }

  /// Deletes a file permanently from Google Drive.
  /// If permanent deletion fails (e.g. 403 because the current user is an editor
  /// but not the owner of a file in personal Drive), falls back to removing the
  /// file from the patient's parent folder, ensuring the photo is completely
  /// removed from the clinic patient folder for all clinic users.
  Future<void> deleteFile({
    required AuthClient client,
    required String fileId,
    String? parentFolderId,
  }) async {
    final driveApi = drive.DriveApi(client);
    try {
      await driveApi.files.delete(fileId, supportsAllDrives: true);
      debugPrint('Deleted Drive file $fileId permanently');
      return;
    } catch (e) {
      if (e is drive.DetailedApiRequestError && e.status == 404) {
        debugPrint('Drive file $fileId was already deleted/not found');
        return;
      }
      debugPrint('Permanent delete failed for $fileId ($e), attempting removal from parent folder');
    }

    try {
      String? folderToRemove = parentFolderId;
      if (folderToRemove == null || folderToRemove.isEmpty) {
        final fileMeta = await driveApi.files.get(
          fileId,
          $fields: 'parents',
          supportsAllDrives: true,
        ) as drive.File;
        final parents = fileMeta.parents;
        if (parents != null && parents.isNotEmpty) {
          folderToRemove = parents.join(',');
        }
      }

      if (folderToRemove != null && folderToRemove.isNotEmpty) {
        await driveApi.files.update(
          drive.File(),
          fileId,
          removeParents: folderToRemove,
          supportsAllDrives: true,
        );
        debugPrint('Removed Drive file $fileId from parent folder(s) $folderToRemove');
      }

      // Also attempt to move to trash if allowed
      try {
        await driveApi.files.update(
          drive.File()..trashed = true,
          fileId,
          supportsAllDrives: true,
        );
      } catch (_) {}
    } catch (e) {
      if (e is drive.DetailedApiRequestError && e.status == 404) {
        debugPrint('Drive file $fileId was already deleted/not found');
        return;
      }
      debugPrint('Fallback removal from parent folder failed for $fileId: $e');
      rethrow;
    }
  }

  /// Gets or creates the "Unassigned Photos" root folder under [parentFolderId].
  Future<String> getOrCreateUnassignedRootFolder({
    required AuthClient client,
    required String parentFolderId,
  }) async {
    const rootName = 'Unassigned Photos';
    final existing = await findFoldersByName(
      client: client,
      parentFolderId: parentFolderId,
      folderName: rootName,
    );
    if (existing.isNotEmpty) {
      return existing.first.id!;
    }
    return await createFolder(
      client: client,
      parentFolderId: parentFolderId,
      folderName: rootName,
    );
  }

  /// Gets or creates a session folder `session_YYYYMMDD_HHMMSS` under [unassignedRootId].
  Future<String> getOrCreateUnassignedSessionFolder({
    required AuthClient client,
    required String unassignedRootId,
    required String sessionFolderTimestamp,
  }) async {
    final sessionFolderName = 'session_$sessionFolderTimestamp';
    final existing = await findFoldersByName(
      client: client,
      parentFolderId: unassignedRootId,
      folderName: sessionFolderName,
    );
    if (existing.isNotEmpty) {
      return existing.first.id!;
    }
    return await createFolder(
      client: client,
      parentFolderId: unassignedRootId,
      folderName: sessionFolderName,
    );
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
