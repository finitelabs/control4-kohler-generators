import re
from datetime import datetime, timedelta, timezone

from conftest import (
    API,
    BLUE,
    LIQUID,
    OFFLINE,
    OFFLINE_ID,
    REDGREEN,
    SINGLE,
    Api,
    headers,
    sign_in,
)

FRACTION7 = r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}\+00:00$"


async def test_me(signed_in):
    _, _, api = await signed_in()
    me = await api.get("/homeowner/me")
    assert me["email"] == "demo@example.com"
    assert me["id"] == 91001
    assert sorted(me["deviceSerialNumbers"]) == [
        "DEMO000001",
        "DEMO000002",
        "DEMO000003",
    ]


async def test_homes_hold_their_generators(signed_in):
    _, _, api = await signed_in()
    homes = await api.get("/homeowner/homes")
    assert [h["name"] for h in homes] == ["Demo Home", "Demo Cabin"]
    assert [d["id"] for d in homes[0]["devices"]] == [BLUE, LIQUID]
    assert [d["id"] for d in homes[1]["devices"]] == [REDGREEN]
    dev = homes[0]["devices"][0]
    assert dev["serialNumber"] == "DEMO000001"
    assert dev["status"] == "ReadyToRun"
    assert dev["isConnected"] is True
    assert dev["dealerOrgs"][0]["name"] == "Example Power Co."
    assert dev["address"] == homes[0]["address"]
    assert "latestParameterUpdateTimestamp" not in dev


async def test_device_record(signed_in):
    _, _, api = await signed_in()
    rec = await api.record(BLUE)
    dev = rec["device"]
    assert dev["id"] == BLUE
    assert dev["controllerType"] == "RDC2 (Blue Board)"
    assert dev["modelDisplayName"] == "20 KW"
    assert dev["deviceHost"] == "Oncue"
    assert rec["powerSource"] == "Utility"
    assert rec["switchState"] == "Auto"
    assert rec["engineState"] == "Standby"
    assert rec["fuelType"] == "NaturalGas"
    assert rec["utilityVoltageV"] > 200
    assert rec["exercise"]["frequency"] == "Weekly"
    assert rec["exercise"]["runningMode"] is None
    assert [p["displayName"] for p in rec["loadShed"]["parameters"]] == [
        "HVAC A",
        "HVAC B",
        "Load A",
        "Load B",
        "Load C",
        "Load D",
    ]
    assert rec["loadShed"]["isConnected"] is True
    assert len(rec["pim"]["parameters"]) == 6
    assert rec["associatedUsers"] == ["demo@example.com"]


async def test_source_device_host(signed_in):
    _, client, api = await signed_in()
    assert (await api.get(f"/devices/{BLUE}"))["device"]["id"] == BLUE
    resp = await api.call("GET", f"/devices/{BLUE}?sourceDeviceHost=Hub")
    assert resp.status == 404


async def test_unknown_devices(signed_in):
    _, client, api = await signed_in()
    for path in (
        f"/devices/{OFFLINE_ID}",
        "/devices/abc",
        f"/devices/{OFFLINE_ID}/alerts",
    ):
        resp = await api.call("GET", path)
        assert resp.status == 404, path


async def test_lists_start_empty(signed_in):
    _, _, api = await signed_in()
    assert await api.get(f"/devices/{BLUE}/alerts") == []
    assert await api.get(f"/devices/{BLUE}/events") == []
    assert await api.get(f"/devices/{BLUE}/maintenance_notes") == []
    assert await api.get("/notifications") == []


async def test_every_read_needs_auth(signed_in):
    _, client, _ = await signed_in()
    for path in (
        "/homeowner/me",
        "/homeowner/homes",
        "/notifications",
        f"/devices/{BLUE}",
        f"/devices/{BLUE}/alerts",
        f"/devices/{BLUE}/events",
        f"/devices/{BLUE}/maintenance_notes",
    ):
        resp = await client.get(API + path, headers={"ApiKey": "mock-api-key"})
        assert resp.status == 401, path


# ─── Quirks ───────────────────────────────────────────────────────────────


async def test_mac_address_is_byte_reversed(signed_in):
    _, _, api = await signed_in()
    rec = await api.record(BLUE)
    assert rec["device"]["macAddress"] == "01:A1:00:00:00:02"
    homes = await api.get("/homeowner/homes")
    assert homes[0]["devices"][0]["macAddress"] == "01:A1:00:00:00:02"


async def test_timestamps_with_offset(signed_in):
    _, _, api = await signed_in()
    rec = await api.record(BLUE)
    assert rec["exercise"]["nextStartTimestamp"].endswith("Z")
    assert rec["device"]["lastMaintenanceTimestamp"].endswith("+00:00")
    assert rec["device"]["nextMaintenanceTimestamp"].endswith("+00:00")
    # The controller clock is local wall time on every controller.
    assert "+" not in rec["controllerClockTimestamp"]


async def test_naive_local_timestamps(signed_in):
    _, _, api = await signed_in()
    rec = await api.record(REDGREEN)
    nxt = rec["exercise"]["nextStartTimestamp"]
    assert "+" not in nxt and not nxt.endswith("Z")
    local = datetime.fromisoformat(nxt)
    # The profile schedules Tuesday 13:30 at UTC-7.
    assert (local.weekday(), local.hour, local.minute) == (1, 13, 30)
    for key in ("lastMaintenanceTimestamp", "nextMaintenanceTimestamp"):
        assert datetime.fromisoformat(rec["device"][key]).tzinfo is None
    aware = local.replace(tzinfo=timezone(timedelta(hours=-7)))
    assert aware.timestamp() > 1_790_000_000


async def test_seven_digit_fractions(signed_in):
    _, _, api = await signed_in()
    blue = await api.record(BLUE)
    assert re.match(FRACTION7, blue["device"]["statusUpdateTimestamp"])
    red = await api.record(REDGREEN)
    assert "." not in red["device"]["statusUpdateTimestamp"]


async def test_nullable_telemetry_by_model(signed_in):
    _, _, api = await signed_in()
    air = await api.record(BLUE)
    assert air["engineCoolantTempF"] is None
    assert air["engineOilPressurePsi"] is None
    assert air["lubeOilTempF"] is not None
    liquid = await api.record(LIQUID)
    assert liquid["coolingType"] == "Liquid"
    assert isinstance(liquid["engineCoolantTempF"], float)
    assert liquid["engineOilPressurePsi"] == 0
    assert liquid["lubeOilTempF"] is None


async def test_offline_profile(make_cloud):

    _, client = await make_cloud(OFFLINE)
    api = Api(client, (await sign_in(client))["access_token"])
    rec = await api.record(OFFLINE_ID)
    assert rec["device"]["isConnected"] is False
    assert rec["device"]["status"] == "Offline"
    assert rec["device"]["alertCount"] == 1
    alerts = await api.get(f"/devices/{OFFLINE_ID}/alerts")
    assert alerts[0]["event"] == "Not Connected"
    assert alerts[0]["level"] == "None"
    assert alerts[0]["id"] < 0
    resp = await client.get(f"{API}/homeowner/homes", headers=headers(api.token))
    assert (await resp.json())[0]["devices"][0]["status"] == "Offline"


async def test_single_instance(make_cloud):
    _, client = await make_cloud(SINGLE)
    api = Api(client, (await sign_in(client))["access_token"])
    homes = await api.get("/homeowner/homes")
    assert [[d["id"] for d in h["devices"]] for h in homes] == [[BLUE]]
