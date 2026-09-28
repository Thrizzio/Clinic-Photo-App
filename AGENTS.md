# Clinic Photos (Doctor Clinical Photo Capture App)

## What this is
A lightweight, reliable Android application for a single doctor in a single clinic to select a patient from their clinic Google Sheet, rapidly capture clinical photographs, and automatically upload them to that patient's Google Drive folder.

## Stack
- Framework: Flutter (Android-first)
- Language: Dart
- Persistence: SQLite (`sqflite`), `shared_preferences`
- APIs: Google Sheets API v4 (`googleapis`), Google Drive API v3 (`googleapis`), Google Sign-In (`google_sign_in` 7.x)
- Camera: `camera` plugin (CameraX on Android)
- Offline & Network: `connectivity_plus`, local file storage (`path_provider`)

## Commands
- Dependencies: `flutter pub get`
- Test: `flutter test`
- Analyze: `flutter analyze`
- Run: `flutter run`
- Build APK: `flutter build apk`

## Conventions
- Architecture: Simple modular services + Flutter state (no unnecessary BLoC, Riverpod, or repository abstractions).
- Private app storage: captured photos saved in app private directory (`photo_queue/`), never in public device gallery.
- Safe reconfiguration: new Sheet configurations are verified 100% before replacing existing working configuration.
- Drive Routing: Google Sheet is the deterministic routing layer (`Patient ID | Patient Name | Drive Folder ID`).
- Non-blocking shutter: camera UI never waits for network upload.

## Treat as high-stakes (explain before implementing)
- Google OAuth credentials and scopes (`https://www.googleapis.com/auth/drive`).
- Patient photo file deletion: NEVER delete local image file until Google Drive API confirms successful file creation.
- Startup crash recovery: always reset `uploading` records to `waiting` on startup.
- Safe patient validation: never permit photo capture for patients missing a valid Drive Folder ID.