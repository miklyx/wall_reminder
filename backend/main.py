"""FastAPI server for durable reminder scheduling and WebSocket delivery.

Configure REMINDER_API_KEY before starting the server. SQLite stores reminders
and unacknowledged deliveries, so scheduled work survives process restarts.
"""

from __future__ import annotations

import asyncio
import hmac
import json
import logging
import os
import sqlite3
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from uuid import UUID, uuid4

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from fastapi import Depends, FastAPI, Header, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, ConfigDict, Field
import firebase_admin
from firebase_admin import credentials, messaging

from reminder_models import (
    CronSchedule,
    ReminderDTO,
    ReminderStatus,
    ScheduledTime,
    TimestampSchedule,
)

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = Path(os.getenv("REMINDER_DB_PATH", str(BASE_DIR / "reminders.sqlite3")))
API_KEY = os.getenv("REMINDER_API_KEY", "")
POLL_SECONDS = max(1, int(os.getenv("REMINDER_POLL_SECONDS", "1")))
RETRY_SECONDS = max(5, int(os.getenv("REMINDER_RETRY_SECONDS", "30")))
FCM_RETRY_SECONDS = max(30, int(os.getenv("FCM_RETRY_SECONDS", "300")))
FIREBASE_PROJECT_ID = os.getenv("GOOGLE_CLOUD_PROJECT", "wall-reminder-161")
BEGIN_IMMEDIATE = "BEGIN IMMEDIATE"
REMINDER_NOT_FOUND = "Reminder not found"
# Uvicorn configures this logger for console output; using a module logger here
# can hide INFO-level startup messages because the root logger defaults to WARNING.
logger = logging.getLogger("uvicorn.error")
firebase_app: firebase_admin.App | None = None


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def to_utc_iso(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("datetime must include a timezone")
    return value.astimezone(timezone.utc).isoformat()


def parse_datetime(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def connect_db() -> sqlite3.Connection:
    connection = sqlite3.connect(DB_PATH, timeout=10, check_same_thread=False)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA journal_mode = WAL")
    return connection


def initialize_db() -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with connect_db() as db:
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS reminders (
                id TEXT PRIMARY KEY,
                message_text TEXT NOT NULL,
                scheduled_time_json TEXT NOT NULL,
                is_active INTEGER NOT NULL,
                duration_seconds INTEGER NOT NULL,
                status TEXT NOT NULL,
                next_run_at TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS ix_reminders_due
                ON reminders(is_active, next_run_at);
            CREATE TABLE IF NOT EXISTS deliveries (
                delivery_id TEXT PRIMARY KEY,
                reminder_id TEXT NOT NULL REFERENCES reminders(id) ON DELETE CASCADE,
                occurrence_at TEXT NOT NULL,
                created_at TEXT NOT NULL,
                last_sent_at TEXT,
                acknowledged_at TEXT,
                UNIQUE(reminder_id, occurrence_at)
            );
            CREATE INDEX IF NOT EXISTS ix_deliveries_pending
                ON deliveries(acknowledged_at, last_sent_at);
            CREATE TABLE IF NOT EXISTS device_tokens (
                token TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS delivery_push_targets (
                delivery_id TEXT NOT NULL REFERENCES deliveries(delivery_id) ON DELETE CASCADE,
                token TEXT NOT NULL REFERENCES device_tokens(token) ON DELETE CASCADE,
                sent_at TEXT,
                failed_at TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_at TEXT NOT NULL,
                PRIMARY KEY(delivery_id, token)
            );
            CREATE INDEX IF NOT EXISTS ix_push_targets_retry
                ON delivery_push_targets(sent_at, failed_at, next_attempt_at);
            """
        )


def initialize_firebase() -> firebase_admin.App | None:
    """Initialize Firebase Admin using ADC or GOOGLE_APPLICATION_CREDENTIALS."""
    global firebase_app
    if firebase_app is not None:
        return firebase_app
    try:
        firebase_app = firebase_admin.get_app()
    except ValueError:
        try:
            firebase_app = firebase_admin.initialize_app(
                credentials.ApplicationDefault(),
                options={"projectId": FIREBASE_PROJECT_ID},
            )
        except Exception as exc:
            logger.warning(
                "Firebase Admin could not initialize; FCM delivery is disabled. "
                "Configure GOOGLE_APPLICATION_CREDENTIALS or application default credentials: %s",
                exc,
            )
            return None
    logger.info("Firebase Admin initialized; FCM push delivery is enabled")
    return firebase_app


def cron_trigger(schedule: CronSchedule) -> CronTrigger:
    try:
        return CronTrigger.from_crontab(schedule.expression, timezone=schedule.time_zone)
    except (ValueError, TypeError) as exc:
        raise ValueError(f"Invalid cron expression: {exc}") from exc


def first_run(schedule: ScheduledTime, now: datetime) -> datetime:
    if isinstance(schedule, TimestampSchedule):
        return schedule.at.astimezone(timezone.utc)
    trigger = cron_trigger(schedule)
    next_run = trigger.get_next_fire_time(None, now.astimezone(trigger.timezone))
    if next_run is None:
        raise ValueError("Cron expression has no upcoming run")
    return next_run.astimezone(timezone.utc)


def reminder_from_row(row: sqlite3.Row) -> ReminderDTO:
    schedule = json.loads(row["scheduled_time_json"])
    return ReminderDTO(
        id=UUID(row["id"]),
        message_text=row["message_text"],
        scheduled_time=schedule,
        is_active=bool(row["is_active"]),
        duration_seconds=row["duration_seconds"],
        status=row["status"],
    )


def read_reminder(reminder_id: str) -> ReminderDTO | None:
    with connect_db() as db:
        row = db.execute("SELECT * FROM reminders WHERE id = ?", (reminder_id,)).fetchone()
    return reminder_from_row(row) if row else None


class ReminderWrite(BaseModel):
    model_config = ConfigDict(extra="forbid")

    message_text: str = Field(min_length=1, max_length=2000)
    scheduled_time: ScheduledTime
    is_active: bool = True
    duration_seconds: int = Field(gt=0, le=86400)


class ReminderPatch(BaseModel):
    model_config = ConfigDict(extra="forbid")

    message_text: str | None = Field(default=None, min_length=1, max_length=2000)
    scheduled_time: ScheduledTime | None = None
    is_active: bool | None = None
    duration_seconds: int | None = Field(default=None, gt=0, le=86400)


class ImmediatePush(BaseModel):
    model_config = ConfigDict(extra="forbid")

    message_text: str = Field(min_length=1, max_length=2000)
    duration_seconds: int = Field(default=30, gt=0, le=86400)


class FCMTokenRegistration(BaseModel):
    model_config = ConfigDict(extra="forbid")

    token: str = Field(min_length=20, max_length=4096)


def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
    if not API_KEY:
        raise HTTPException(status_code=503, detail="Server is not configured: set REMINDER_API_KEY")
    if x_api_key is None or not hmac.compare_digest(x_api_key, API_KEY):
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


class WebSocketHub:
    def __init__(self) -> None:
        self.connections: set[WebSocket] = set()
        self.lock = asyncio.Lock()

    async def add(self, websocket: WebSocket) -> None:
        await websocket.accept()
        async with self.lock:
            self.connections.add(websocket)

    async def remove(self, websocket: WebSocket) -> None:
        async with self.lock:
            self.connections.discard(websocket)

    async def broadcast(self, payload: dict[str, Any]) -> None:
        async with self.lock:
            clients = list(self.connections)
        if not clients:
            return
        results = await asyncio.gather(
            *(client.send_json(payload) for client in clients), return_exceptions=True
        )
        dead = [client for client, result in zip(clients, results) if isinstance(result, Exception)]
        if dead:
            async with self.lock:
                for client in dead:
                    self.connections.discard(client)


hub = WebSocketHub()
scheduler = AsyncIOScheduler(timezone=timezone.utc)


def materialize_due_reminders() -> None:
    """Persist one delivery per due occurrence before attempting WebSocket sends."""
    now = utc_now()
    now_iso = to_utc_iso(now)
    with connect_db() as db:
        db.execute(BEGIN_IMMEDIATE)
        due_rows = db.execute(
            "SELECT * FROM reminders WHERE is_active = 1 AND next_run_at <= ?",
            (now_iso,),
        ).fetchall()
        for row in due_rows:
            occurrence = parse_datetime(row["next_run_at"])
            occurrence_iso = to_utc_iso(occurrence)
            db.execute(
                "INSERT OR IGNORE INTO deliveries "
                "(delivery_id, reminder_id, occurrence_at, created_at) VALUES (?, ?, ?, ?)",
                (str(uuid4()), row["id"], occurrence_iso, now_iso),
            )
            schedule_data = json.loads(row["scheduled_time_json"])
            if schedule_data["kind"] == "cron":
                schedule = CronSchedule.model_validate(schedule_data)
                trigger = cron_trigger(schedule)
                next_run = trigger.get_next_fire_time(
                    occurrence.astimezone(trigger.timezone),
                    now.astimezone(trigger.timezone),
                )
                next_run_iso = to_utc_iso(next_run) if next_run else None
                active = 1 if next_run else 0
            else:
                next_run_iso = None
                active = 0
            db.execute(
                """UPDATE reminders
                   SET next_run_at = ?, is_active = ?, status = ?, updated_at = ?
                   WHERE id = ?""",
                (
                    next_run_iso,
                    active,
                    ReminderStatus.pending.value,
                    now_iso,
                    row["id"],
                ),
            )
        db.commit()


def stage_fcm_targets() -> None:
    """Snapshot registered installations for all unacknowledged deliveries."""
    now_iso = to_utc_iso(utc_now())
    with connect_db() as db:
        db.execute(
            """INSERT OR IGNORE INTO delivery_push_targets
               (delivery_id, token, next_attempt_at)
               SELECT d.delivery_id, t.token, ?
               FROM deliveries d CROSS JOIN device_tokens t
               WHERE d.acknowledged_at IS NULL""",
            (now_iso,),
        )


async def send_fcm_pending() -> None:
    """Send notifications to token targets, retrying transient failures later."""
    app_instance = firebase_app
    if app_instance is None:
        return

    stage_fcm_targets()
    now = utc_now()
    now_iso = to_utc_iso(now)
    retry_at = to_utc_iso(now + timedelta(seconds=FCM_RETRY_SECONDS))
    with connect_db() as db:
        db.execute(BEGIN_IMMEDIATE)
        rows = db.execute(
            """SELECT p.delivery_id, p.token, d.reminder_id, d.occurrence_at,
                      r.message_text, r.duration_seconds
               FROM delivery_push_targets p
               JOIN deliveries d ON d.delivery_id = p.delivery_id
               JOIN reminders r ON r.id = d.reminder_id
               WHERE d.acknowledged_at IS NULL AND p.sent_at IS NULL
                 AND p.failed_at IS NULL AND p.next_attempt_at <= ?
               ORDER BY d.created_at LIMIT 100""",
            (now_iso,),
        ).fetchall()
        for row in rows:
            db.execute(
                """UPDATE delivery_push_targets
                   SET attempts = attempts + 1, next_attempt_at = ?
                   WHERE delivery_id = ? AND token = ?""",
                (retry_at, row["delivery_id"], row["token"]),
            )
        db.commit()

    for row in rows:
        message = messaging.Message(
            notification=messaging.Notification(
                title="Напоминание",
                body=row["message_text"],
            ),
            data={
                "type": "reminder.trigger",
                "delivery_id": row["delivery_id"],
                "reminder_id": row["reminder_id"],
                "message_text": row["message_text"],
                "duration_seconds": str(row["duration_seconds"]),
                "occurrence_at": row["occurrence_at"],
            },
            android=messaging.AndroidConfig(priority="high"),
            token=row["token"],
        )
        try:
            await asyncio.to_thread(messaging.send, message, app=app_instance)
        except messaging.UnregisteredError:
            logger.info("Removing unregistered FCM token")
            with connect_db() as db:
                db.execute("DELETE FROM device_tokens WHERE token = ?", (row["token"],))
        except Exception:
            logger.exception("FCM send failed; target will be retried")
        else:
            logger.info("FCM notification accepted for delivery %s", row["delivery_id"])
            with connect_db() as db:
                db.execute(
                    """UPDATE delivery_push_targets SET sent_at = ?
                       WHERE delivery_id = ? AND token = ?""",
                    (to_utc_iso(utc_now()), row["delivery_id"], row["token"]),
                )


async def deliver_pending() -> None:
    now = utc_now()
    retry_before = to_utc_iso(now - timedelta(seconds=RETRY_SECONDS))
    now_iso = to_utc_iso(now)
    # Send FCM before WebSocket: a foreground client may acknowledge the
    # WebSocket event immediately, but a backgrounded display still needs its
    # operating-system notification.
    await send_fcm_pending()
    if hub.connections:
        with connect_db() as db:
            db.execute(BEGIN_IMMEDIATE)
            rows = db.execute(
                """SELECT d.delivery_id, d.reminder_id, d.occurrence_at,
                          r.message_text, r.duration_seconds, r.scheduled_time_json
                   FROM deliveries d JOIN reminders r ON r.id = d.reminder_id
                   WHERE d.acknowledged_at IS NULL
                     AND (d.last_sent_at IS NULL OR d.last_sent_at <= ?)
                   ORDER BY d.created_at LIMIT 100""",
                (retry_before,),
            ).fetchall()
            for row in rows:
                db.execute(
                    "UPDATE deliveries SET last_sent_at = ? WHERE delivery_id = ?",
                    (now_iso, row["delivery_id"]),
                )
            db.commit()
        for row in rows:
            schedule_data = json.loads(row["scheduled_time_json"])
            await hub.broadcast(
                {
                    "type": "reminder.trigger",
                    "delivery_id": row["delivery_id"],
                    "reminder_id": row["reminder_id"],
                    "message_text": row["message_text"],
                    "duration_seconds": row["duration_seconds"],
                    "scheduled_time": schedule_data,
                    "occurrence_at": row["occurrence_at"],
                }
            )


async def scheduler_tick() -> None:
    await asyncio.to_thread(materialize_due_reminders)
    await deliver_pending()


@asynccontextmanager
async def lifespan(_: FastAPI):
    initialize_db()
    initialize_firebase()
    scheduler.add_job(
        scheduler_tick,
        "interval",
        seconds=POLL_SECONDS,
        id="reminder-dispatcher",
        replace_existing=True,
        max_instances=1,
        coalesce=True,
    )
    scheduler.start()
    try:
        yield
    finally:
        scheduler.shutdown(wait=False)


app = FastAPI(title="Wall Reminder API", version="1.0.0", lifespan=lifespan)


@app.get("/", response_class=HTMLResponse, include_in_schema=False)
async def dashboard() -> str:
    return DASHBOARD_HTML


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/api/devices/fcm-token", dependencies=[Depends(require_api_key)])
async def register_fcm_token(body: FCMTokenRegistration) -> dict[str, str]:
    now_iso = to_utc_iso(utc_now())
    with connect_db() as db:
        db.execute(
            """INSERT INTO device_tokens (token, created_at, updated_at)
               VALUES (?, ?, ?)
               ON CONFLICT(token) DO UPDATE SET updated_at = excluded.updated_at""",
            (body.token, now_iso, now_iso),
        )
    return {"status": "registered"}


@app.post("/api/reminders", response_model=ReminderDTO, status_code=201, dependencies=[Depends(require_api_key)])
async def create_reminder(body: ReminderWrite) -> ReminderDTO:
    now = utc_now()
    try:
        next_run = first_run(body.scheduled_time, now) if body.is_active else None
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    reminder_id = uuid4()
    schedule_json = json.dumps(body.scheduled_time.model_dump(mode="json"))
    with connect_db() as db:
        db.execute(
            """INSERT INTO reminders
               (id, message_text, scheduled_time_json, is_active, duration_seconds,
                status, next_run_at, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                str(reminder_id), body.message_text, schedule_json, int(body.is_active),
                body.duration_seconds, ReminderStatus.pending.value,
                to_utc_iso(next_run) if next_run else None, to_utc_iso(now), to_utc_iso(now),
            ),
        )
    return read_reminder(str(reminder_id))  # type: ignore[return-value]


@app.get("/api/reminders", response_model=list[ReminderDTO], dependencies=[Depends(require_api_key)])
async def list_reminders() -> list[ReminderDTO]:
    with connect_db() as db:
        rows = db.execute("SELECT * FROM reminders ORDER BY created_at DESC").fetchall()
    return [reminder_from_row(row) for row in rows]


@app.get("/api/reminders/{reminder_id}", response_model=ReminderDTO, dependencies=[Depends(require_api_key)])
async def get_reminder(reminder_id: UUID) -> ReminderDTO:
    reminder = read_reminder(str(reminder_id))
    if reminder is None:
        raise HTTPException(status_code=404, detail=REMINDER_NOT_FOUND)
    return reminder


@app.put("/api/reminders/{reminder_id}", response_model=ReminderDTO, dependencies=[Depends(require_api_key)])
async def replace_reminder(reminder_id: UUID, body: ReminderWrite) -> ReminderDTO:
    return _update_reminder(reminder_id, body.model_dump())


@app.patch("/api/reminders/{reminder_id}", response_model=ReminderDTO, dependencies=[Depends(require_api_key)])
async def update_reminder(reminder_id: UUID, body: ReminderPatch) -> ReminderDTO:
    current = read_reminder(str(reminder_id))
    if current is None:
        raise HTTPException(status_code=404, detail=REMINDER_NOT_FOUND)
    changes = body.model_dump(exclude_unset=True)
    merged = current.model_dump(
        include={"message_text", "scheduled_time", "is_active", "duration_seconds"}
    )
    merged.update(changes)
    write = ReminderWrite.model_validate(merged)
    return _update_reminder(reminder_id, write.model_dump())


def _update_reminder(reminder_id: UUID, fields: dict[str, Any]) -> ReminderDTO:
    now = utc_now()
    write = ReminderWrite.model_validate(fields)
    try:
        next_run = first_run(write.scheduled_time, now) if write.is_active else None
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    schedule_json = json.dumps(write.scheduled_time.model_dump(mode="json"))
    with connect_db() as db:
        cursor = db.execute(
            """UPDATE reminders SET message_text = ?, scheduled_time_json = ?, is_active = ?,
               duration_seconds = ?, next_run_at = ?, status = ?, updated_at = ? WHERE id = ?""",
            (
                write.message_text, schedule_json, int(write.is_active),
                write.duration_seconds, to_utc_iso(next_run) if next_run else None,
                ReminderStatus.pending.value, to_utc_iso(now), str(reminder_id),
            ),
        )
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail=REMINDER_NOT_FOUND)
        db.execute("DELETE FROM deliveries WHERE reminder_id = ? AND acknowledged_at IS NULL", (str(reminder_id),))
    return read_reminder(str(reminder_id))  # type: ignore[return-value]


@app.delete("/api/reminders/{reminder_id}", status_code=204, dependencies=[Depends(require_api_key)])
async def delete_reminder(reminder_id: UUID) -> None:
    with connect_db() as db:
        cursor = db.execute("DELETE FROM reminders WHERE id = ?", (str(reminder_id),))
    if cursor.rowcount == 0:
        raise HTTPException(status_code=404, detail=REMINDER_NOT_FOUND)


@app.post("/api/dismiss/{reminder_id}", response_model=ReminderDTO, dependencies=[Depends(require_api_key)])
async def dismiss_reminder(reminder_id: UUID) -> ReminderDTO:
    now_iso = to_utc_iso(utc_now())
    with connect_db() as db:
        db.execute(BEGIN_IMMEDIATE)
        row = db.execute("SELECT id FROM reminders WHERE id = ?", (str(reminder_id),)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail=REMINDER_NOT_FOUND)
        db.execute(
            "UPDATE reminders SET status = ?, updated_at = ? WHERE id = ?",
            (ReminderStatus.dismissed.value, now_iso, str(reminder_id)),
        )
        db.execute(
            "UPDATE deliveries SET acknowledged_at = ? WHERE reminder_id = ? AND acknowledged_at IS NULL",
            (now_iso, str(reminder_id)),
        )
        db.commit()
    return read_reminder(str(reminder_id))  # type: ignore[return-value]


@app.post(
    "/api/deliveries/{delivery_id}/dismiss",
    status_code=204,
    dependencies=[Depends(require_api_key)],
)
async def dismiss_delivery(delivery_id: UUID) -> None:
    now_iso = to_utc_iso(utc_now())
    with connect_db() as db:
        db.execute(BEGIN_IMMEDIATE)
        row = db.execute(
            "SELECT reminder_id FROM deliveries WHERE delivery_id = ?",
            (str(delivery_id),),
        ).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Delivery not found")
        db.execute(
            "UPDATE deliveries SET acknowledged_at = ? WHERE delivery_id = ?",
            (now_iso, str(delivery_id)),
        )
        pending = db.execute(
            """SELECT 1 FROM deliveries
               WHERE reminder_id = ? AND acknowledged_at IS NULL LIMIT 1""",
            (row["reminder_id"],),
        ).fetchone()
        if pending is None:
            db.execute(
                "UPDATE reminders SET status = ?, updated_at = ? WHERE id = ?",
                (
                    ReminderStatus.dismissed.value,
                    now_iso,
                    row["reminder_id"],
                ),
            )
        db.commit()


@app.post("/api/push", response_model=ReminderDTO, status_code=201, dependencies=[Depends(require_api_key)])
async def push_immediately(body: ImmediatePush) -> ReminderDTO:
    now = utc_now()
    write = ReminderWrite(
        message_text=body.message_text,
        scheduled_time=TimestampSchedule(kind="timestamp", at=now),
        is_active=True,
        duration_seconds=body.duration_seconds,
    )
    return await create_reminder(write)


@app.websocket("/ws")
async def reminder_websocket(websocket: WebSocket) -> None:
    token = websocket.headers.get("x-api-key", "")
    if not API_KEY or not hmac.compare_digest(token, API_KEY):
        await websocket.close(code=1008, reason="Unauthorized")
        return
    await hub.add(websocket)
    try:
        await websocket.send_json({"type": "connected", "server_time": to_utc_iso(utc_now())})
        await deliver_pending()
        while True:
            message = await websocket.receive_json()
            if message.get("type") == "ack" and isinstance(message.get("delivery_id"), str):
                acknowledge_delivery(message["delivery_id"], ReminderStatus.received)
            elif message.get("type") == "ping":
                await websocket.send_json({"type": "pong", "server_time": to_utc_iso(utc_now())})
            else:
                await websocket.send_json({"type": "error", "detail": "Unsupported WebSocket message"})
    except WebSocketDisconnect:
        pass
    finally:
        await hub.remove(websocket)


def acknowledge_delivery(delivery_id: str, status: ReminderStatus) -> None:
    now_iso = to_utc_iso(utc_now())
    with connect_db() as db:
        db.execute(BEGIN_IMMEDIATE)
        row = db.execute(
            "SELECT reminder_id FROM deliveries WHERE delivery_id = ?", (delivery_id,)
        ).fetchone()
        if row:
            db.execute(
                "UPDATE deliveries SET acknowledged_at = ? WHERE delivery_id = ?",
                (now_iso, delivery_id),
            )
            db.execute(
                "UPDATE reminders SET status = ?, updated_at = ? WHERE id = ? AND status != ?",
                (status.value, now_iso, row["reminder_id"], ReminderStatus.dismissed.value),
            )
        db.commit()


DASHBOARD_HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Wall Reminder Control</title><style>
*{box-sizing:border-box}body{margin:0;background:#10151f;color:#edf2f7;font:16px system-ui,sans-serif;min-height:100vh;display:grid;place-items:center;padding:24px}
main{width:min(620px,100%);background:#1a2332;border:1px solid #2b394e;border-radius:22px;padding:30px;box-shadow:0 24px 80px #0006}h1{margin:0 0 8px;font-size:28px}.muted{color:#a9b6c9;margin:0 0 24px}label{display:block;font-size:14px;margin:16px 0 8px;color:#c7d2e2}input,textarea{width:100%;border:1px solid #35445b;border-radius:12px;background:#111a28;color:#fff;padding:13px;font:inherit}textarea{min-height:140px;resize:vertical}button{margin-top:18px;background:#70e1bd;color:#09231e;border:0;border-radius:12px;padding:13px 20px;font-weight:750;font-size:16px;cursor:pointer}button:disabled{opacity:.6;cursor:wait}pre{white-space:pre-wrap;word-break:break-word;background:#111a28;padding:12px;border-radius:10px;color:#c7d2e2;min-height:42px}.row{display:grid;grid-template-columns:1fr 150px;gap:14px}
</style></head><body><main><h1>Wall Reminder Control</h1><p class="muted">Send a message to connected reminder displays immediately.</p>
<form id="push"><label for="key">API key</label><input id="key" type="password" autocomplete="current-password" required>
<label for="message">Message</label><textarea id="message" maxlength="2000" placeholder="Take pills at 14:00" required></textarea>
<div class="row"><div><label for="duration">Display duration (seconds)</label><input id="duration" type="number" value="30" min="1" max="86400" required></div><div><button id="send" type="submit">Send now</button></div></div></form>
<label>Server response</label><pre id="result">Ready</pre></main>
<script>
const form=document.querySelector('#push'), result=document.querySelector('#result'), key=document.querySelector('#key');
key.value=sessionStorage.getItem('reminderApiKey')||'';
form.addEventListener('submit',async e=>{e.preventDefault();const button=document.querySelector('#send');button.disabled=true;result.textContent='Sending…';sessionStorage.setItem('reminderApiKey',key.value);try{const path=window.location.pathname;const apiPath=(path.endsWith('/')?path.slice(0,-1):path)+'/api/push';const response=await fetch(apiPath,{method:'POST',headers:{'Content-Type':'application/json','X-API-Key':key.value},body:JSON.stringify({message_text:document.querySelector('#message').value,duration_seconds:Number(document.querySelector('#duration').value)})});const data=await response.json();result.textContent=JSON.stringify(data,null,2);if(!response.ok)throw new Error(data.detail||response.statusText);document.querySelector('#message').value='';}catch(error){result.textContent='Error: '+error.message;}finally{button.disabled=false;}});
</script></body></html>"""
