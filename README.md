# Wall Reminder Display (Flutter)

A full-screen Flutter Android display for reminders from the companion FastAPI server. It uses `wakelock_plus` only while a reminder is being displayed, a custom seamless marquee, authenticated WebSocket delivery, and Firebase Cloud Messaging (FCM) notifications when the app is backgrounded. Dismissal is sent through the backend REST endpoint.

## Run

Install Flutter and Android SDK, then from the project root:

```sh
flutter pub get
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000 --dart-define=API_KEY=your-server-key
```

`10.0.2.2` is the Android Emulator alias for the host machine. On a physical Mi A3, use the backend computer's reachable LAN address instead, e.g. `http://192.168.1.20:8000`. For non-local networks, use HTTPS/WSS through a trusted TLS reverse proxy. The API key is compiled into the app; distribute builds only to trusted devices and rotate the key if the app package is exposed. Do not use the development key for a public server.

Android may block unencrypted HTTP for modern target SDKs. Prefer HTTPS/WSS; if using plain HTTP on a trusted development LAN, explicitly allow cleartext traffic in the generated Android app manifest for development only, and do not ship that setting in a public release.

The Firebase project is configured through FlutterFire. The server requires the `X-API-Key` header for WebSocket, token registration, and dismissal.

## Enable backend push delivery

1. In Firebase Console, generate a private key under **Project settings → Service accounts → Firebase Admin SDK**. Keep the downloaded Admin SDK JSON outside the repository.
2. In a backend terminal, set both credentials and start the server (replace paths and secret):

	```sh
	cd backend
	export REMINDER_API_KEY='your-long-random-secret'
	export GOOGLE_APPLICATION_CREDENTIALS='/absolute/path/to/firebase-admin-key.json'
	.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000
	```

3. Run the app with the same API key. Use `10.0.2.2` for Android Emulator; for Mi A3 use the host computer's reachable LAN IP:

	```sh
	flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000 --dart-define=API_KEY=your-long-random-secret
	```

4. Accept notification permission on Android 13+. The app obtains its FCM token and registers it with `POST /api/devices/fcm-token`; backend startup logs confirm whether Firebase Admin initialized. Then send a test from `http://<backend-host>:8000/` or create a due reminder. When app is backgrounded, Android shows an FCM notification; tap it to open the reminder display.

FCM provides delivery notifications but Android does not guarantee that a push turns on the display or launches the app automatically. For that behavior use a foreground/kiosk display configuration; test lock-screen visibility and battery settings on the actual Mi A3. Keep the Admin SDK key server-only; `google-services.json` is the Android app configuration, not the Admin credential.

## Behavior

- Incoming reminders, the active queue, and pending completion syncs are persisted on-device. The app acknowledges a delivery only after saving it locally.
- `DISMISS / DONE` pauses the marquee, releases WakeLock, saves completion locally, and immediately advances to the next reminder. Backend dismissal sync runs separately with retries and does not block the display.
- The display is locked to landscape. The active reminder uses large text; queued reminders appear beneath it as smaller message previews.
- WakeLock is disabled when the app leaves the resumed lifecycle state and re-enabled for an active reminder when resumed.
- WebSocket retries use bounded exponential backoff. FCM notification taps and foreground pushes are also handled; the client deduplicates recently received delivery IDs across restarts.

FCM is the fallback when Android suspends the WebSocket. The OS displays a notification while the app is in the background; the user generally needs to tap it to open the full-screen message. This app does not change screen brightness. `wakelock_plus` prevents normal display sleep while enabled, but kiosk/pin mode and OEM battery policies may need separate device configuration.

## Checks

Run `flutter analyze` and `flutter test` from the project root.
