import asyncio
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import firebase_admin
from fastapi.testclient import TestClient

import main


def test_firebase_initialization_sets_project_id_for_adc(monkeypatch):
    expected_app = object()
    captured = {}

    def get_uninitialized_app():
        raise ValueError("not initialized")

    monkeypatch.setattr(main, "firebase_app", None)
    monkeypatch.setattr(main, "FIREBASE_PROJECT_ID", "test-firebase-project")
    monkeypatch.setattr(main.firebase_admin, "get_app", get_uninitialized_app)
    monkeypatch.setattr(main.credentials, "ApplicationDefault", lambda: "adc")

    def initialize_app(credential, options):
        captured["credential"] = credential
        captured["options"] = options
        return expected_app

    monkeypatch.setattr(firebase_admin, "initialize_app", initialize_app)

    assert main.initialize_firebase() is expected_app
    assert captured == {
        "credential": "adc",
        "options": {"projectId": "test-firebase-project"},
    }


def test_reminder_crud_and_dismiss(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "test.sqlite3")
    monkeypatch.setattr(main, "API_KEY", "test-secret")
    with TestClient(main.app) as client:
        headers = {"X-API-Key": "test-secret"}
        scheduled = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
        response = client.post(
            "/api/reminders",
            headers=headers,
            json={
                "message_text": "Take pills",
                "scheduled_time": {"kind": "timestamp", "at": scheduled},
                "is_active": True,
                "duration_seconds": 45,
            },
        )
        assert response.status_code == 201
        reminder = response.json()
        reminder_id = reminder["id"]
        assert reminder["status"] == "pending"
        assert reminder["message_text"] == "Take pills"

        assert client.get("/api/reminders", headers=headers).json()[0]["id"] == reminder_id
        patched = client.patch(
            f"/api/reminders/{reminder_id}",
            headers=headers,
            json={"message_text": "Take the pills"},
        )
        assert patched.status_code == 200
        assert patched.json()["message_text"] == "Take the pills"

        dismissed = client.post(f"/api/dismiss/{reminder_id}", headers=headers)
        assert dismissed.status_code == 200
        assert dismissed.json()["status"] == "dismissed"

        assert client.delete(f"/api/reminders/{reminder_id}", headers=headers).status_code == 204
        assert client.get(f"/api/reminders/{reminder_id}", headers=headers).status_code == 404


def test_auth_required(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "test.sqlite3")
    monkeypatch.setattr(main, "API_KEY", "test-secret")
    with TestClient(main.app) as client:
        assert client.get("/api/reminders").status_code == 401


def test_dashboard_push_url_preserves_path_prefix():
    with TestClient(main.app) as client:
        response = client.get("/")

    assert response.status_code == 200
    assert "const path=window.location.pathname;const apiPath=(path.endsWith('/')?path.slice(0,-1):path)+'/api/push'" in response.text


def test_immediate_push_creates_due_reminder(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "test.sqlite3")
    monkeypatch.setattr(main, "API_KEY", "test-secret")
    with TestClient(main.app) as client:
        response = client.post(
            "/api/push",
            headers={"X-API-Key": "test-secret"},
            json={"message_text": "Hello display", "duration_seconds": 20},
        )
        assert response.status_code == 201
        reminder = response.json()
        assert reminder["message_text"] == "Hello display"
        assert reminder["scheduled_time"]["kind"] == "timestamp"
        assert reminder["is_active"] is True


def test_due_reminder_is_persisted_and_acknowledged_over_websocket(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "test.sqlite3")
    monkeypatch.setattr(main, "API_KEY", "test-secret")
    with TestClient(main.app) as client:
        response = client.post(
            "/api/reminders",
            headers={"X-API-Key": "test-secret"},
            json={
                "message_text": "Due now",
                "scheduled_time": {
                    "kind": "timestamp",
                    "at": (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat(),
                },
                "is_active": True,
                "duration_seconds": 10,
            },
        )
        assert response.status_code == 201
        reminder = response.json()
        main.materialize_due_reminders()

        with client.websocket_connect(
            "/ws", headers={"X-API-Key": "test-secret"}
        ) as websocket:
            assert websocket.receive_json()["type"] == "connected"
            event = websocket.receive_json()
            assert event["type"] == "reminder.trigger"
            assert event["reminder_id"] == reminder["id"]
            websocket.send_json({"type": "ack", "delivery_id": event["delivery_id"]})

        refreshed = client.get(
            f"/api/reminders/{reminder['id']}",
            headers={"X-API-Key": "test-secret"},
        )
        assert refreshed.json()["status"] == "received"


def test_dismiss_delivery_only_completes_the_selected_occurrence(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "test.sqlite3")
    monkeypatch.setattr(main, "API_KEY", "test-secret")
    with TestClient(main.app) as client:
        headers = {"X-API-Key": "test-secret"}
        created = client.post(
            "/api/reminders",
            headers=headers,
            json={
                "message_text": "Recurring reminder",
                "scheduled_time": {
                    "kind": "timestamp",
                    "at": (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat(),
                },
                "is_active": True,
                "duration_seconds": 10,
            },
        )
        assert created.status_code == 201
        reminder_id = created.json()["id"]
        main.materialize_due_reminders()
        with main.connect_db() as db:
            first_delivery = db.execute(
                "SELECT delivery_id FROM deliveries WHERE reminder_id = ?",
                (reminder_id,),
            ).fetchone()["delivery_id"]
            second_delivery = str(uuid4())
            now = datetime.now(timezone.utc).isoformat()
            db.execute(
                """INSERT INTO deliveries
                   (delivery_id, reminder_id, occurrence_at, created_at)
                   VALUES (?, ?, ?, ?)""",
                (second_delivery, reminder_id, now, now),
            )

        dismissed = client.post(
            f"/api/deliveries/{first_delivery}/dismiss",
            headers=headers,
        )
        assert dismissed.status_code == 204
        with main.connect_db() as db:
            rows = db.execute(
                "SELECT delivery_id, acknowledged_at FROM deliveries "
                "WHERE reminder_id = ?",
                (reminder_id,),
            ).fetchall()
        acknowledgment_by_id = {
            row["delivery_id"]: row["acknowledged_at"] for row in rows
        }
        assert acknowledgment_by_id[first_delivery] is not None
        assert acknowledgment_by_id[second_delivery] is None


def test_fcm_token_registration_and_scheduled_delivery(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "test.sqlite3")
    monkeypatch.setattr(main, "API_KEY", "test-secret")
    token = "fcm-device-token-for-test-1234567890"
    sent_messages = []
    monkeypatch.setattr(main, "firebase_app", object())

    def fake_send(message, app=None):
        sent_messages.append((message, app))
        return "fcm-message-id"

    monkeypatch.setattr(main.messaging, "send", fake_send)
    with TestClient(main.app) as client:
        headers = {"X-API-Key": "test-secret"}
        registered = client.post(
            "/api/devices/fcm-token",
            headers=headers,
            json={"token": token},
        )
        assert registered.status_code == 200
        assert registered.json() == {"status": "registered"}

        created = client.post(
            "/api/reminders",
            headers=headers,
            json={
                "message_text": "FCM test reminder",
                "scheduled_time": {
                    "kind": "timestamp",
                    "at": (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat(),
                },
                "is_active": True,
                "duration_seconds": 25,
            },
        )
        assert created.status_code == 201
        main.materialize_due_reminders()
        asyncio.run(main.send_fcm_pending())

        assert len(sent_messages) == 1
        message, app = sent_messages[0]
        assert app is not None
        assert message.notification.body == "FCM test reminder"
        assert message.data["type"] == "reminder.trigger"
        assert message.data["duration_seconds"] == "25"
