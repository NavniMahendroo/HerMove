# HERMOVE

HERMOVE is a hybrid safety application composed of:

- A Flutter mobile client for emergency monitoring and SOS interaction.
- A native Android background service for Bluetooth-triggered alerts.
- A Python FastAPI backend for emergency intake and dispatch orchestration.

This repository currently contains the mobile app code under `lib/`, the Android service under `android/`, the Flutter entrypoint at `lib/main.dart`, and the backend entrypoint as `main.py` at the project root.

## What the project does

- Listens for emergency triggers from the mobile UI and the native Android service.
- Stores emergency telemetry locally for offline-first delivery.
- Sends alerts to an operator / dispatcher backend.
- Matches incoming emergencies against nearby volunteer locations using a mock proximity matcher.
- Sends SMS notifications through Twilio.

## Repository Layout

- `lib/` - Flutter app screens and services.
- `lib/services/hardware_bridge.dart` - Flutter bridge to the native Android background service.
- `lib/services/local_queue_service.dart` - Local offline queue for emergency telemetry.
- `lib/safety_dashboard.dart` - Main safety dashboard UI.
- `android/` - Native Android implementation.
- `android/app/src/main/kotlin/.../AmbientGuardianService.kt` - Foreground service and Bluetooth receiver.
- `main.py` - FastAPI backend for emergency dispatch.

## Prerequisites

- Flutter SDK 3.19+.
- Dart 3.3+.
- Python 3.11+.
- Android Studio or the Android command-line tools.
- A Twilio account for production SMS delivery.

## Flutter Setup

Install the Flutter dependencies:

```bash
flutter pub get
```

Then run the app:

```bash
flutter run
```

On this workspace the Windows desktop target is available, so you can also run:

```bash
flutter run -d windows
```

If you are targeting Android, make sure the Android permissions in the manifest are present and runtime permissions are granted when the app requests them.

## Android Native Service

The Android service is implemented in:

- `android/app/src/main/kotlin/com/hermove/app/AmbientGuardianService.kt`

It runs as a foreground service and listens for Bluetooth ACL disconnect events. Those native triggers are forwarded into Flutter through:

- MethodChannel: `hermove/ambient_guardian/methods`
- EventChannel: `hermove/ambient_guardian/events`

## Backend Setup

The backend is a single-file FastAPI application:

- `main.py`

Install the Python dependencies first. A minimal set is:

```bash
pip install fastapi uvicorn twilio pydantic
```

Run the API with Uvicorn:

```bash
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

Health check:

```bash
GET http://127.0.0.1:8000/health
```

## Emergency Intake Endpoint

### `POST /api/v1/emergency/trigger`

This endpoint accepts either a single event or a list of queued offline events.

### Request body

Single event:

```json
{
  "user_id": "user-123",
  "latitude": 19.076,
  "longitude": 72.8777,
  "trigger_type": "bluetooth_acl_disconnected",
  "timestamp": 1710000000000
}
```

Batch payload:

```json
[
  {
    "user_id": "user-123",
    "latitude": 19.076,
    "longitude": 72.8777,
    "trigger_type": "high_g_burst",
    "timestamp": 1710000000000
  },
  {
    "user_id": "user-123",
    "latitude": 19.0759,
    "longitude": 72.878,
    "trigger_type": "bluetooth_acl_disconnected",
    "timestamp": 1710000005000
  }
]
```

### Response shape

```json
{
  "accepted": 1,
  "dispatched": 1,
  "matched_volunteers": [
    {
      "volunteer_id": "v-1001",
      "name": "Asha",
      "distance_meters": 120.45
    }
  ],
  "sms_sent": true,
  "processed_at": "2026-06-15T10:00:00Z"
}
```

## Twilio Configuration

Set these environment variables before running the backend in production:

- `TWILIO_ACCOUNT_SID`
- `TWILIO_AUTH_TOKEN`
- `TWILIO_FROM_NUMBER`
- `TWILIO_TO_NUMBER`

Example on macOS / Linux:

```bash
export TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export TWILIO_AUTH_TOKEN=your_auth_token
export TWILIO_FROM_NUMBER=+15551234567
export TWILIO_TO_NUMBER=+919999999999
```

Example on Windows PowerShell:

```powershell
$env:TWILIO_ACCOUNT_SID="ACxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
$env:TWILIO_AUTH_TOKEN="your_auth_token"
$env:TWILIO_FROM_NUMBER="+15551234567"
$env:TWILIO_TO_NUMBER="+919999999999"
```

If the Twilio variables are missing, the backend will still start in development mode and log that SMS dispatch is skipped.

## Offline Queue Behavior

The Flutter client stores emergency telemetry locally in an encrypted Hive-backed queue before upload.

The queue service provides:

- `enqueueTelemetry(lat, lng, trigger)`
- `getQueuedItems()`
- `deleteItems(ids)`

Queued items can be flushed once connectivity returns and the upload path succeeds.

In this workspace the offline queue is backed by encrypted Hive storage so it can run on Windows and mobile targets without a platform-specific SQLite encryption plugin.

## Flutter Channels

The bridge layer uses:

- `MethodChannel` for start / stop / status control.
- `EventChannel` for native emergency events.

Channel names:

- `hermove/ambient_guardian/methods`
- `hermove/ambient_guardian/events`

## Safety Dashboard

The main app screen is:

- `lib/safety_dashboard.dart`

It includes:

- A deliberate slide-to-SOS gesture.
- A high-visibility nighttime safety theme.
- A countdown-style cancel dialog.
- A hardware-trigger listener for Bluetooth disconnect and high-G motion events.

## Typical End-to-End Flow

1. The user swipes the SOS control or the native service raises a Bluetooth disconnect trigger.
2. Flutter receives the trigger through the hardware bridge.
3. Emergency telemetry is queued locally if the network is unavailable.
4. The backend receives the trigger at `/api/v1/emergency/trigger`.
5. The backend matches nearby volunteers within 500 meters.
6. Twilio sends an SMS alert with a live Google Maps link.

## Notes

- The Redis proximity matcher is currently mocked in Python and uses a local volunteer list plus haversine distance.
- For a production deployment, replace the mock volunteer list with real Redis-backed geo lookups and persist dispatch records in a database.
- For production mobile builds, ensure all Android foreground service, Bluetooth, vibration, and notification permissions are declared and requested appropriately.

## Recommended Next Steps

1. Add a `requirements.txt` for the backend.
2. Add a `.env.example` for Twilio variables.
3. Wire the Flutter app to call the backend API from the emergency callback.
4. Replace the mock volunteer matcher with a real Redis geo index.
