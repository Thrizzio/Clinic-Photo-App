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
* **Durable SQLite Queue**: The `uploads` SQLite table is the source of truth for pending work (`waiting`, `uploading`, `pending`, `failed`). A local file is never deleted before Drive confirms the remote operation; confirmed uploads remain as a private offline gallery cache until the doctor safely deletes them.
* **Startup Crash Recovery**: If the app or phone restarts during an upload, any item with status `uploading` is automatically reset to `waiting` on database open.
* **Process-Resilient Worker**: Android WorkManager schedules a network-constrained one-off upload and a 15-minute periodic safety pass. The Dart worker reconstructs the SQLite/auth/Drive services in its own isolate, while persisted retry timestamps prevent tight retry loops.
* **Gentle Bounded Retries**: Automatic exponential retry backoffs (5s, 15s, 30s, 60s). Failed work remains in SQLite for a later retry; the capture and patient-list UI does not expose upload progress or success badges.
* **Safe Drive Folder ID Validation**: Existing Google Sheet folder links are validated. Patients without a link remain locally routable for lazy folder creation, but no photo is deleted or marked uploaded until Drive confirms the destination.
* **Safe Reconfiguration**: Changing the clinic Google Sheet in Settings tests and validates the new sheet before replacing the existing working configuration.
* **Reference Camera Mode**: A previous local or Drive-backed photo can be shown as a translucent, adjustable camera overlay without baking the reference into the captured image.

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

The clinic workbook is read from an `Appointments` tab when one is present. Each patient is deduplicated by normalized phone number; a unique normalized name is used only when no phone number is available. The legacy Visits/Patient ID format remains supported for existing workbooks.

For the Appointments master view, the header row should contain `Appointment ID`, `Patient Name`, and `Phone Number`. `Photos (Drive)` or `Drive Folder ID` may also be present:

| Appointment ID | Patient Name | Phone Number | Photos (Drive) |
| :--- | :--- | :--- | :--- |
| A001 | Rahul Sharma | +91 9876543210 | 1ABCxyz... |
| A002 | Ananya Patel | +91 9876543211 | 1DEFuvw... |
| A003 | Priya Verma | +91 9876543212 | 1GHIrst... |

If no `Appointments` tab exists, the configured tab must contain the legacy headers `Patient ID`, `Patient Name`, and `Photos (Drive)`/`Drive Folder ID`.

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
4. **Reference mode**: Open the reference picker from the camera, choose a previous local/Drive photo, and adjust its overlay opacity. The reference is never baked into the new capture.
5. **Background delivery**: WorkManager continues the durable queue after the app is backgrounded or the process is recreated. The app UI shows the local capture immediately and does not display upload progress or upload-success badges.

---

## 6. Development & Verification

### Prerequisites
* Flutter SDK 3.47.4 (Dart 3.13.3; see `.fvmrc`)
* Android SDK (API 34+)
* Java 17

### Dependencies
```bash
flutter pub get
```

The repository keeps `pubspec.lock`; use `flutter pub get --offline` on a
machine with the pinned packages already cached.

Copy `.env.example` to `.env` for local Supabase/doctor configuration. `.env`
is ignored by Git; pass it explicitly when running or building:

```bash
flutter run --dart-define-from-file=.env
flutter build apk --debug --dart-define-from-file=.env
```

### Static Analysis
Run static analysis to confirm zero lints or errors:
```bash
make analyze
```

### Automated Unit & Integration Tests
Run the automated test suite covering URL parsing, dynamic header detection, Drive folder validation, SQLite caching, in-memory crash recovery, and queue persistence:
```bash
make test
```

### Run Locally on Android
Ensure an Android device or emulator is connected:
```bash
make run
```

### Reproducible container build

The pinned Flutter/Android toolchain is also described by `Dockerfile`:

```bash
docker build -t clinic-photos:dev .
docker run --rm clinic-photos:dev test --no-pub
docker run --rm clinic-photos:dev build apk --debug
```

The container can build and test the Android artifact. A physical-device run
still requires a host-connected Android device or emulator:

```bash
make run
```
