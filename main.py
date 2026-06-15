from __future__ import annotations

import asyncio
import math
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field, field_validator
from twilio.rest import Client

app = FastAPI(
    title="HERMOVE Emergency Dispatch API",
    version="1.0.0",
    description="Async backend infrastructure for emergency intake and dispatch handling.",
)


@dataclass(frozen=True)
class Volunteer:
    volunteer_id: str
    name: str
    latitude: float
    longitude: float
    radius_meters: int = 500


MOCK_VOLUNTEERS: list[Volunteer] = [
    Volunteer("v-1001", "Asha", 19.0760, 72.8777),
    Volunteer("v-1002", "Meera", 19.0725, 72.8822),
    Volunteer("v-1003", "Riya", 19.0701, 72.8793),
    Volunteer("v-1004", "Anika", 19.0804, 72.8741),
]


class EmergencyTrigger(BaseModel):
    user_id: str = Field(..., min_length=1)
    latitude: float
    longitude: float
    trigger_type: str = Field(..., min_length=1)
    timestamp: int

    @field_validator("user_id", "trigger_type")
    @classmethod
    def strip_strings(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("must not be empty")
        return normalized


class EmergencyTriggerBatch(BaseModel):
    items: list[EmergencyTrigger]


class DispatchMatch(BaseModel):
    volunteer_id: str
    name: str
    distance_meters: float


class DispatchResponse(BaseModel):
    accepted: int
    dispatched: int
    matched_volunteers: list[DispatchMatch]
    sms_sent: bool
    processed_at: str


class SmsConfig(BaseModel):
    account_sid: str
    auth_token: str
    from_number: str
    to_number: str


class SmsDispatcher:
    def __init__(self, config: SmsConfig) -> None:
        self._config = config
        self._client = Client(config.account_sid, config.auth_token)

    async def send_alert(self, latitude: float, longitude: float) -> None:
        message = (
            "URGENT: Commuter needs help! Live Tracking Link: "
            f"https://maps.google.com/?q={latitude},{longitude}"
        )
        await asyncio.to_thread(
            self._client.messages.create,
            body=message,
            from_=self._config.from_number,
            to=self._config.to_number,
        )


_sms_dispatcher: SmsDispatcher | None = None


@app.get("/health")
async def health_check() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/api/v1/emergency/trigger", response_model=DispatchResponse)
async def trigger_emergency(payload: EmergencyTrigger | list[EmergencyTrigger]) -> DispatchResponse:
    events = _normalize_payload(payload)
    if not events:
        raise HTTPException(status_code=400, detail="No emergency events supplied")

    dispatcher = _get_sms_dispatcher()
    sms_sent = False
    all_matches: list[DispatchMatch] = []
    for event in events:
        matches = _find_volunteers_within_radius(event.latitude, event.longitude)
        all_matches.extend(matches)
        _print_matches(event, matches)
        if dispatcher is not None:
            await dispatcher.send_alert(event.latitude, event.longitude)
            sms_sent = True
        else:
            print(
                "[HERMOVE] Twilio not configured; skipping SMS dispatch",
                {"user_id": event.user_id, "trigger_type": event.trigger_type},
            )

    return DispatchResponse(
        accepted=len(events),
        dispatched=len(events),
        matched_volunteers=all_matches,
        sms_sent=sms_sent,
        processed_at=datetime.now(timezone.utc).isoformat(),
    )


def _normalize_payload(payload: EmergencyTrigger | list[EmergencyTrigger]) -> list[EmergencyTrigger]:
    if isinstance(payload, list):
        return payload
    return [payload]


def _find_volunteers_within_radius(latitude: float, longitude: float) -> list[DispatchMatch]:
    matches: list[DispatchMatch] = []
    for volunteer in MOCK_VOLUNTEERS:
        distance = _haversine_distance_meters(latitude, longitude, volunteer.latitude, volunteer.longitude)
        if distance <= volunteer.radius_meters:
            matches.append(
                DispatchMatch(
                    volunteer_id=volunteer.volunteer_id,
                    name=volunteer.name,
                    distance_meters=round(distance, 2),
                )
            )
    return matches


def _print_matches(event: EmergencyTrigger, matches: Iterable[DispatchMatch]) -> None:
    match_list = list(matches)
    print(
        "[HERMOVE] Emergency trigger received",
        {
            "user_id": event.user_id,
            "trigger_type": event.trigger_type,
            "latitude": event.latitude,
            "longitude": event.longitude,
            "timestamp": event.timestamp,
            "matched_volunteers": [match.model_dump() for match in match_list],
        },
    )


def _haversine_distance_meters(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    earth_radius_meters = 6_371_000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = math.radians(lat2 - lat1)
    delta_lambda = math.radians(lon2 - lon1)

    a = (
        math.sin(delta_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2) ** 2
    )
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return earth_radius_meters * c


def _build_sms_dispatcher() -> SmsDispatcher:
    account_sid = os.getenv("TWILIO_ACCOUNT_SID")
    auth_token = os.getenv("TWILIO_AUTH_TOKEN")
    from_number = os.getenv("TWILIO_FROM_NUMBER")
    to_number = os.getenv("TWILIO_TO_NUMBER")

    missing = [
        name
        for name, value in [
            ("TWILIO_ACCOUNT_SID", account_sid),
            ("TWILIO_AUTH_TOKEN", auth_token),
            ("TWILIO_FROM_NUMBER", from_number),
            ("TWILIO_TO_NUMBER", to_number),
        ]
        if not value
    ]

    if missing:
        raise RuntimeError(
            "Missing Twilio environment variables: " + ", ".join(missing)
        )

    return SmsDispatcher(
        SmsConfig(
            account_sid=account_sid,
            auth_token=auth_token,
            from_number=from_number,
            to_number=to_number,
        )
    )


def _get_sms_dispatcher() -> SmsDispatcher | None:
    global _sms_dispatcher

    if _sms_dispatcher is not None:
        return _sms_dispatcher

    try:
        _sms_dispatcher = _build_sms_dispatcher()
    except RuntimeError as exc:
        print(f"[HERMOVE] {exc}")
        _sms_dispatcher = None

    return _sms_dispatcher
