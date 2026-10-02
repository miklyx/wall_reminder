FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    REMINDER_DB_PATH=/data/reminders.sqlite3

WORKDIR /app

# tzdata is needed by ZoneInfo for cron schedules using IANA time zones.
RUN apt-get update \
    && apt-get install -y --no-install-recommends tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /data

COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py reminder_models.py ./

EXPOSE 8000

# Keep one process: APScheduler and the in-memory WebSocket hub are single-process.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
