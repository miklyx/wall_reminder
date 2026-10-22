# Wall Reminder API

Small FastAPI service for remote management and timed delivery of reminders to a Flutter display. SQLite is the durable source of truth; APScheduler polls it, and WebSocket sends notification events to connected clients.

## Run

Requires Python 3.10+.

```sh
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# Edit .env and set a strong REMINDER_API_KEY.
uvicorn main:app --env-file .env --host 0.0.0.0 --port 8000
```

The API refuses protected operations and WebSocket sessions until `REMINDER_API_KEY` is configured. Local startup reads settings from `backend/.env`; `.env` is git-ignored. Configure `REMINDER_DB_PATH` to choose the SQLite file, `REMINDER_POLL_SECONDS` (default 1) for scheduler polling, and `REMINDER_RETRY_SECONDS` (default 30) for unacknowledged WebSocket resend interval. Keep the database on durable storage. Use HTTPS/WSS via a trusted reverse proxy when accessed outside a trusted LAN; do not expose the unauthenticated health endpoint as an operational status feed if that matters to your deployment.

## Docker deployment (VPS or Docker host)

This backend uses a continuously running APScheduler, SQLite, and an in-memory WebSocket hub. It is designed as a single long-lived process, not as a Vercel serverless function. **Vercel does not deploy this Dockerfile/Compose service as a persistent container**; its serverless runtime can suspend between requests, does not provide durable local SQLite storage, and is not suitable for this scheduler/WebSocket hub. Use a VPS or container host with persistent disk and inbound HTTPS/WSS. For Vercel, the backend would need an architectural redesign (external database/queue, externally invoked scheduled jobs, and a separate supported push delivery path).

On a Docker host, copy `.env.example` to `.env`, set a strong API key and the absolute host path to the Firebase Admin SDK JSON, then start the container:

```sh
cd backend
cp .env.example .env
# Edit .env and set REMINDER_API_KEY and FIREBASE_ADMIN_KEY_FILE.
docker compose up --build -d
docker compose logs -f reminder-api
```

The compose file mounts the Firebase key read-only and stores SQLite in the persistent `reminder_data` Docker volume. Do not commit `.env` or the service-account JSON. The API listens on port 8000; put a TLS reverse proxy in front for public access so Flutter can use HTTPS/WSS. Run exactly one replica: multiple server processes would each run a scheduler and maintain separate in-memory WebSocket connections. Stop with `docker compose down`; the named database volume remains. To remove data too, explicitly remove the volume (`docker compose down -v`).

## Raspberry Pi Kubernetes ingress

The Raspberry Pi runs Pi-hole natively, with its web server on port `8081`; DNS remains served by Pi-hole on port `53`. `pihole-ingress.yaml` exposes only the web UI through Traefik at `http://192.168.178.29/pi-hole/` and redirects the short path to the Pi-hole admin UI. It uses a static Kubernetes EndpointSlice for the Pi's LAN address, so keep that address reserved in the router and update the EndpointSlice if it changes.

For Pi-hole v6, keep `webserver.paths.webhome` at `/admin/` and set `webserver.paths.prefix` to `/pi-hole`. Traefik strips `/pi-hole` before forwarding requests. On the Pi, the settings can be applied with:

```sh
sudo pihole-FTL --config webserver.paths.webhome "/admin/"
sudo pihole-FTL --config webserver.paths.prefix "/pi-hole"
```

Apply the ingress manifest from a machine with the cluster's `kubectl` context:

```sh
kubectl apply -f backend/pihole-ingress.yaml
```

This route does not expose DNS over Traefik or change the router's DNS configuration.

### Enable Firebase Cloud Messaging (FCM)

In Firebase Console, open **Project settings → Service accounts → Firebase Admin SDK** and generate a private key for the server. Store the downloaded JSON outside the repository. For a local FastAPI run, set `GOOGLE_APPLICATION_CREDENTIALS` to its absolute path in `backend/.env`. Also set `GOOGLE_CLOUD_PROJECT` to the Firebase Console Project ID (the configured project for this app is `wall-reminder-161`); this is required when Application Default Credentials do not provide a project ID. For Docker Compose, set `FIREBASE_ADMIN_KEY_FILE` to its absolute host path in the same file; Compose mounts it read-only and passes the container path to the SDK:

```dotenv
GOOGLE_APPLICATION_CREDENTIALS=/absolute/secure/path/firebase-admin-key.json
FIREBASE_ADMIN_KEY_FILE=/absolute/secure/path/firebase-admin-key.json
GOOGLE_CLOUD_PROJECT=wall-reminder-161
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
- `POST /api/deliveries/{delivery_id}/dismiss` — idempotently dismiss one delivery (204).
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

Recurring example: `"scheduled_time": {"kind": "cron", "expression": "0 9 * * *", "time_zone": "America/Los_Angeles"}`. Cron is five-field syntax interpreted in the supplied IANA time zone. Timestamp values must include an offset. The response DTO adds the server-generated `id` and current `status` (`pending`, `received`, `displayed`, `dismissed`). `received` means the client durably queued the delivery; `displayed` remains available for older clients. `is_active` controls future scheduling and becomes false after a one-off fires; recurring schedules remain active.

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

After the client has durably stored the trigger on the device, acknowledge it with `{"type":"ack","delivery_id":"..."}`. The server records status `received`; this stops WebSocket retries, while the device's local queue remains responsible for displaying and completing it. The Android tap/dismiss action should call `POST /api/dismiss/{reminder_id}`. `{"type":"ping"}` receives a `pong`; reconnecting causes unacknowledged events to be sent again. Client code should deduplicate by `delivery_id`, acknowledge only after local persistence, and retry dismissal requests safely.

## Delivery and limitations

A due occurrence is first persisted in SQLite, then sent to currently connected WebSocket clients. Pending events survive server restart and are retried to a connected client until acknowledged; this is **at-least-once**, not exactly-once. There is a small duplicate window around send/ack, so clients must deduplicate. WebSocket is not a durable connection or push notification service: offline devices receive pending work only after they reconnect. For production multi-instance deployments, use a shared database plus coordination/queueing; this simple single-process scheduler assumes one service instance owns the SQLite database. Cron misfire behavior coalesces missed repeated occurrences to the next upcoming run rather than replaying every historical occurrence.
