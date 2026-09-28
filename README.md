# Clinic Photos — Doctor Clinical Photo Capture App

An Android-only Flutter application purpose-built for a single doctor in a single clinic.

## 1. Product Overview

The app has one core purpose:

> Let the doctor select a patient from the clinic's existing patient list, open the camera, rapidly take one or multiple clinical photographs, and automatically upload those photographs to that patient's existing Google Drive folder.

The doctor never needs to manually interact with Google Drive or organize folders. The app acts as an automation layer on top of the clinic's existing Google Sheets and Google Drive workflow:
* **Google Sheets** serves as the authoritative patient registry and Drive folder directory.
* **Google Drive** serves as the photo storage system.
* **Direct Google OAuth** connects the doctor's phone directly to Google APIs without any custom backend, proxy server, or database server.

---

## 2. Core Architecture & Guarantees

* **Rapid Shutter (<50ms, Non-Blocking)**: The camera shutter releases immediately. Captured images are written to private application storage (`photo_queue/`) and queued in SQLite. Shutter never blocks on network or Google Drive uploads.
* **Private Storage**: Clinical photos are stored strictly in private app storage. They are never saved to the device's public photo gallery or exposed to consumer photo apps.
* **Ephemeral SQLite Queue**: The `uploads` SQLite table only tracks pending work (`waiting`, `uploading`, `failed`). Once Google Drive confirms a successful upload, the local photo file is deleted and the SQLite record is removed.
* **Startup Crash Recovery**: If the app or phone restarts during an upload, any item with status `uploading` is automatically reset to `waiting` on database open.
* **Gentle Bounded Retries**: Automatic exponential retry backoffs (5s, 15s, 30s, 60s). If uploads fail after 4 attempts, the item is marked as `failed`, and a minimal status pill (`! 1 failed · Tap to Retry`) lets the doctor retry whenever connectivity is restored.
* **Safe Drive Folder ID Validation**: Google Sheet rows missing a `Drive Folder ID` are skipped during sync to prevent taking photos for unroutable patients.
* **Safe Reconfiguration**: Changing the clinic Google Sheet in Settings tests and validates the new sheet before replacing the existing working configuration.

---

## 3. Google Cloud Console Setup

Because the app connects directly to Google Sheets and Google Drive from Android, an Android OAuth 2.0 Client ID must be configured in the Google Cloud Console.

### Step 1: Create or Select a Google Cloud Project
1. Navigate to the [Google Cloud Console](https://console.cloud.google.com/).
2. Create a new project named `Clinic Photos` (or select an existing project).

### Step 2: Enable Google APIs
Enable the following two APIs in **APIs & Services > Library**:
* **Google Sheets API** (v4)
* **Google Drive API** (v3)

### Step 3: Configure the OAuth Consent Screen
1. Go to **APIs & Services > OAuth consent screen**.
2. Select **Internal** (if using Google Workspace for the clinic) or **External** with **Testing** publishing status.
3. If using **External / Testing**, add the doctor's Google account email under **Test users**.
4. Add the requested scopes:
   * `https://www.googleapis.com/auth/spreadsheets.readonly`
   * `https://www.googleapis.com/auth/drive`

> [!NOTE]
> **Drive Scope Notice**: The broad `https://www.googleapis.com/auth/drive` scope is intentionally required because the app uploads directly into pre-existing clinic patient folders identified by folder IDs. The restricted `drive.file` scope only grants access to files created by the app itself and cannot write to pre-existing clinic folders. This application is intended strictly for private/internal clinic use.

### Step 4: Register Android OAuth Client ID
1. Go to **APIs & Services > Credentials > Create Credentials > OAuth client ID**.
2. Select Application type: **Android**.
3. Set **Package name**: `com.clinic.photoapp` (matches `android/app/build.gradle`).
4. Generate and enter your **SHA-1 certificate fingerprint**:
   * For the debug keystore on Windows/macOS/Linux:
     ```bash
     keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
     ```
   * Copy the `SHA1` fingerprint (e.g., `AA:BB:CC:...`) into Google Cloud Console.
5. Save the client ID.

---

## 4. Clinic Google Sheet Format

The clinic's Google Sheet acts as the patient index. The app requires a header row with the following three column names (case-insensitive, columns can be in any order):

| Patient ID | Patient Name | Drive Folder ID |
| :--- | :--- | :--- |
| P001 | Rahul Sharma | 1ABCxyz... |
| P002 | Ananya Patel | 1DEFuvw... |
| P003 | Priya Verma | 1GHIrst... |

### Finding the Drive Folder ID
In Google Drive, open the patient's folder in a web browser. The URL looks like:
```
https://drive.google.com/drive/folders/1ABCxyz_9876543210-abcdef
```
The string after `/folders/` (`1ABCxyz_9876543210-abcdef`) is the **Drive Folder ID**.

---

## 5. In-App Setup & Workflow

### First Launch
1. Launch the app on the doctor's Android phone.
2. Tap **Get Started** and sign in with the clinic Google account.
3. Grant permissions for Google Sheets and Google Drive access.
4. Paste the clinic Google Sheet URL.
5. Select the tab containing patient records.
6. The app validates headers, counts valid patients, and performs the initial sync.
7. Tap **Save & Start Using App**.

### Daily Workflow
1. **Search**: Search instantly by Patient ID or Name from local SQLite cache.
2. **Capture**: Tap the patient to open the camera. Tap the shutter to rapidly capture clinical photos (counter updates in real-time).
3. **Auto-Upload**: Tap **Done** to return to the patient list. The background queue automatically uploads photos to that patient's Google Drive folder.
4. **Status**: A minimal pill at the bottom displays progress (`↑ 2 uploading`, `✓ All photos uploaded`, or `! 1 failed · Tap to Retry`).

---

## 6. Development & Verification

### Prerequisites
* Flutter SDK (3.24+ / 3.27+)
* Android SDK (API 34+)

### Dependencies
```bash
flutter pub get
```

### Static Analysis
Run static analysis to confirm zero lints or errors:
```bash
flutter analyze
```

### Automated Unit & Integration Tests
Run the automated test suite covering URL parsing, dynamic header detection, Drive folder validation, SQLite caching, in-memory crash recovery, and queue persistence:
```bash
flutter test
```

### Run Locally on Android
Ensure an Android device or emulator is connected:
```bash
flutter run
```
