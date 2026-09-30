# Wall Reminder API

Small FastAPI service for remote management and timed delivery of reminders to a Flutter display. SQLite is the durable source of truth; APScheduler polls it, and WebSocket sends notification events to connected clients.

## Run

Requires Python 3.10+.

```sh
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export REMINDER_API_KEY='replace-with-a-long-random-secret'
uvicorn main:app --host 0.0.0.0 --port 8000
```

The API refuses protected operations and WebSocket sessions until `REMINDER_API_KEY` is configured. Optionally set `REMINDER_DB_PATH` to choose the SQLite file, `REMINDER_POLL_SECONDS` (default 1) for scheduler polling, and `REMINDER_RETRY_SECONDS` (default 30) for unacknowledged WebSocket resend interval. Keep the database on durable storage. Use HTTPS/WSS via a trusted reverse proxy when accessed outside a trusted LAN; do not expose the unauthenticated health endpoint as an operational status feed if that matters to your deployment.

### Enable Firebase Cloud Messaging (FCM)

In Firebase Console, open **Project settings → Service accounts → Firebase Admin SDK** and generate a private key for the server. Store the downloaded JSON outside the repository, then configure its absolute path before starting FastAPI:

```sh
export GOOGLE_APPLICATION_CREDENTIALS="/absolute/secure/path/firebase-admin-key.json"
```

The backend initializes Firebase Admin at startup using Application Default Credentials. Without credentials, REST/WebSocket scheduling still runs, but FCM sending is disabled and a warning is logged. Never put the Admin SDK key in Flutter, `google-services.json`, source control, or a public directory. In production, prefer the host's workload identity/secret manager rather than a downloaded key file. Rotate/revoke a key immediately if it is exposed.

The Flutter app requests notification permission, obtains its installation-specific FCM token, and registers it with `POST /api/devices/fcm-token` using `X-API-Key`. The endpoint stores token registrations in SQLite. On due reminders, the scheduler sends an FCM notification and data payload to registered tokens as well as sending the WebSocket event to connected clients. FCM send acceptance is not a user/display acknowledgement; the delivery remains pending until the app acknowledges it over WebSocket or the user dismisses it via REST. FCM has per-installation token refresh and transient send retries; invalid/unregistered tokens are removed.

FCM requires the Android device to have Google Play services and internet access. A notification can appear while the app is backgrounded, but Android does not guarantee that a push wakes the display or launches the app. Tapping the notification opens the app and passes the reminder payload to Flutter. Test on the target Mi A3 with notification permission enabled and battery restrictions understood.

Open `http://localhost:8000/` for the simple push dashboard. Enter the configured API key and a message. The key is held in the page's `sessionStorage` for that browser tab and sent as `X-API-Key`.

## REST API

All `/api/*` endpoints require `X-API-Key: <secret>`.

- `POST /api/reminders` — create a reminder (201).
- `GET /api/reminders` — list reminders.
- `GET /api/reminders/{id}` — read a reminder.
- `PUT /api/reminders/{id}` — replace its configurable fields.
- `PATCH /api/reminders/{id}` — update provided configurable fields.
- `DELETE /api/reminders/{id}` — delete it (204).
- `POST /api/devices/fcm-token` — register/update the Flutter installation's FCM token.
- `POST /api/dismiss/{id}` — confirm dismissal on the device and acknowledge pending deliveries.
- `POST /api/push` — create an immediate one-shot reminder (201).

Create body example:

```json
{
  "message_text": "Take pills at 14:00",
  "scheduled_time": {"kind": "timestamp", "at": "2026-09-29T14:00:00-07:00"},
  "is_active": true,
  "duration_seconds": 30
}
```

Recurring example: `"scheduled_time": {"kind": "cron", "expression": "0 9 * * *", "time_zone": "America/Los_Angeles"}`. Cron is five-field syntax interpreted in the supplied IANA time zone. Timestamp values must include an offset. The response DTO adds the server-generated `id` and current `status` (`pending`, `displayed`, `dismissed`). `is_active` controls future scheduling and becomes false after a one-off fires; recurring schedules remain active.

## WebSocket protocol

Connect to `/ws` with the `X-API-Key` handshake header (for Flutter mobile, `IOWebSocketChannel.connect(Uri.parse('wss://host/ws'), headers: {'X-API-Key': apiKey})`). Use WSS outside a trusted local network and do not log authorization headers.

On connect, the server sends `{"type":"connected","server_time":"...Z"}`. A scheduled event is sent as:

```json
{
  "type": "reminder.trigger",
  "delivery_id": "server-generated-uuid",
  "reminder_id": "server-generated-uuid",
  "message_text": "Take pills at 14:00",
  "duration_seconds": 30,
  "scheduled_time": {"kind": "timestamp", "at": "2026-09-29T21:00:00Z"},
  "occurrence_at": "2026-09-29T21:00:00+00:00"
}
```

After the client has accepted/displayed the trigger, acknowledge it with `{"type":"ack","delivery_id":"..."}`. The server records status `displayed`. The Android tap/dismiss action should call `POST /api/dismiss/{reminder_id}`. `{"type":"ping"}` receives a `pong`; reconnecting causes unacknowledged events to be sent again. Client code should deduplicate by `delivery_id`, send acknowledgements only after handling the event, and retry dismissal requests safely.

## Delivery and limitations

A due occurrence is first persisted in SQLite, then sent to currently connected WebSocket clients. Pending events survive server restart and are retried to a connected client until acknowledged; this is **at-least-once**, not exactly-once. There is a small duplicate window around send/ack, so clients must deduplicate. WebSocket is not a durable connection or push notification service: offline devices receive pending work only after they reconnect. For production multi-instance deployments, use a shared database plus coordination/queueing; this simple single-process scheduler assumes one service instance owns the SQLite database. Cron misfire behavior coalesces missed repeated occurrences to the next upcoming run rather than replaying every historical occurrence.
