# Wall Reminder Display (Flutter)

A full-screen Flutter Android display for reminders from the companion FastAPI server. It uses `wakelock_plus` only while a reminder is being displayed, a custom seamless marquee, and an authenticated WebSocket connection with automatic reconnect and queued triggers. Dismissal is sent through the backend REST endpoint.

## Run

Install Flutter and Android SDK. This workspace does not yet contain Flutter's generated Android/Gradle wrapper; generate the Android platform once from the project root, then fetch dependencies:

```sh
flutter create --platforms=android --project-name wall_reminder_display .
flutter pub get
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000 --dart-define=API_KEY=your-server-key
```

`10.0.2.2` is the Android Emulator alias for the host machine. On a physical Mi A3, use the backend computer's reachable LAN address instead, e.g. `http://192.168.1.20:8000`. For non-local networks, use HTTPS/WSS through a trusted TLS reverse proxy. The API key is compiled into the app; distribute builds only to trusted devices and rotate the key if the app package is exposed. Do not use the development key for a public server.

Android may block unencrypted HTTP for modern target SDKs. Prefer HTTPS/WSS; if using plain HTTP on a trusted development LAN, explicitly allow cleartext traffic in the generated Android app manifest for development only, and do not ship that setting in a public release.

The backend currently requires a WebSocket handshake header `X-API-Key`. Android Flutter `IOWebSocketChannel` provides this header. The server's `/api/dismiss/{reminder_id}` endpoint also requires the same key.

## Behavior

- Incoming `reminder.trigger` events are queued and acknowledged as `displayed` over the WebSocket when shown, stopping server retries for that delivery.
- `DISMISS / DONE` pauses the marquee, releases WakeLock, then calls `POST /api/dismiss/{reminder_id}`. On failure, the message remains visible and can be retried.
- WakeLock is disabled when the app leaves the resumed lifecycle state and re-enabled for an active reminder when resumed.
- WebSocket retries use bounded exponential backoff. Pending server deliveries are retried on reconnect, and the client deduplicates delivery IDs during its process lifetime.

The connection relies on Android keeping the app process/network alive. Android may suspend or kill a backgrounded process; this WebSocket is not an OS push-notification service. This app does not change screen brightness. `wakelock_plus` prevents normal display sleep while enabled, but kiosk/pin mode and OEM battery policies may need separate device configuration.

## Checks

Run `flutter analyze` and `flutter test` from the project root.
