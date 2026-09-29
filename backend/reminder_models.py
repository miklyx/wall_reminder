"""Pydantic DTOs for reminder scheduling and display status (Pydantic v2)."""

from datetime import datetime
from enum import Enum
from typing import Annotated, Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, field_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class TimestampSchedule(StrictModel):
    kind: Literal["timestamp"]
    at: datetime

    @field_validator("at")
    @classmethod
    def require_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("at must include a UTC offset")
        return value


class CronSchedule(StrictModel):
    kind: Literal["cron"]
    expression: str = Field(min_length=1)
    time_zone: str = Field(min_length=1)

    @field_validator("expression")
    @classmethod
    def require_five_fields(cls, value: str) -> str:
        value = value.strip()
        if len(value.split()) != 5:
            raise ValueError("expression must use a five-field cron format")
        return value

    @field_validator("time_zone")
    @classmethod
    def require_iana_time_zone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except ZoneInfoNotFoundError as exc:
            raise ValueError("time_zone must be a valid IANA time-zone name") from exc
        return value


ScheduledTime = Annotated[
    TimestampSchedule | CronSchedule,
    Field(discriminator="kind"),
]


class ReminderStatus(str, Enum):
    pending = "pending"
    displayed = "displayed"
    dismissed = "dismissed"


class ReminderDTO(StrictModel):
    id: UUID
    message_text: str = Field(min_length=1)
    scheduled_time: ScheduledTime
    is_active: bool
    duration_seconds: int = Field(gt=0)
    status: ReminderStatus
