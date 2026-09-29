from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

import main


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
        assert refreshed.json()["status"] == "displayed"
