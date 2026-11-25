from datetime import datetime, timedelta, timezone

from conftest import BLUE, LIQUID, REDGREEN, control


async def write(api, method, path, body=None, status=204):
    resp = await api.call(method, path, body)
    assert resp.status == status, f"{method} {path}: {resp.status} {await resp.text()}"
    return None if status == 204 else await resp.json()


async def test_exercise_start_and_stop(signed_in, clock):
    _, _, api = await signed_in()
    await write(api, "POST", f"/devices/{BLUE}/exercise/start", {"mode": "Unloaded"})
    rec = await api.record(BLUE)
    assert rec["device"]["status"] == "RunningExercise"
    assert rec["engineState"] == "CrankOn"
    assert rec["exercise"]["runningMode"] == "Unloaded"
    clock.advance(10)
    assert (await api.record(BLUE))["engineState"] == "PerformingUnloadedExercise"
    await write(api, "POST", f"/devices/{BLUE}/exercise/stop")
    rec = await api.record(BLUE)
    assert rec["engineState"] == "CoolDown"
    assert rec["exercise"]["runningMode"] is None
    await write(api, "POST", f"/devices/{BLUE}/exercise/stop", status=409)


async def test_exercise_start_guards(signed_in, clock):
    cloud, client, api = await signed_in()
    path = f"/devices/{BLUE}/exercise/start"
    body = await write(api, "POST", path, {"mode": "EcoExercise"}, status=400)
    assert "not supported" in body["message"]
    await write(api, "POST", path, {"mode": None}, status=400)
    resp = await api.client.post(
        "/kem/api/v3" + path,
        data="nope",
        headers={"Authorization": f"bearer {api.token}", "ApiKey": "mock-api-key"},
    )
    assert resp.status == 400

    await control(client, "online", device=BLUE, online=False)
    body = await write(api, "POST", path, {"mode": "Unloaded"}, status=409)
    assert "offline" in body["message"]
    await control(client, "online", device=BLUE, online=True)

    await control(client, "switch", device=BLUE, position="Off")
    body = await write(api, "POST", path, {"mode": "Unloaded"}, status=409)
    assert "SwitchStateOff" in body["message"]
    await control(client, "switch", device=BLUE, position="Manual")
    body = await write(api, "POST", path, {"mode": "Unloaded"}, status=409)
    assert "not ready to run (Running)" in body["message"]
    await control(client, "switch", device=BLUE, position="Auto")
    clock.advance(600)

    await control(client, "fault", device=BLUE)
    body = await write(api, "POST", path, {"mode": "Unloaded"}, status=409)
    assert "Shutdown" in body["message"]
    await control(client, "clear", device=BLUE)

    await write(api, "POST", path, {"mode": "Unloaded"})
    body = await write(api, "POST", path, {"mode": "Unloaded"}, status=409)
    assert "already running" in body["message"]


async def test_exercise_schedule_write(signed_in, clock):
    _, _, api = await signed_in()
    start = datetime.fromtimestamp(clock.now() + 3 * 86400, timezone.utc).replace(microsecond=0)
    body = {
        "frequency": "Monthly",
        "nextStartTimestamp": start.isoformat().replace("+00:00", "Z"),
        "mode": "LoadedFullSpeed",
        "durationMinutes": 15,
    }
    await write(api, "PUT", f"/devices/{BLUE}/exercise", body)
    ex = (await api.record(BLUE))["exercise"]
    assert ex["frequency"] == "Monthly"
    assert ex["mode"] == "LoadedFullSpeed"
    assert ex["durationMinutes"] == 15
    assert ex["nextStartTimestamp"] == body["nextStartTimestamp"]


async def test_schedule_write_naive_local(signed_in, clock):
    _, _, api = await signed_in()
    local = datetime.fromtimestamp(clock.now() + 86400, timezone(timedelta(hours=-7)))
    text = local.replace(tzinfo=None, microsecond=0).isoformat()
    body = {
        "frequency": "Weekly",
        "nextStartTimestamp": text,
        "mode": "Unloaded",
        "durationMinutes": 20,
    }
    await write(api, "PUT", f"/devices/{REDGREEN}/exercise", body)
    assert (await api.record(REDGREEN))["exercise"]["nextStartTimestamp"] == text


async def test_schedule_write_validation(signed_in, clock):
    _, _, api = await signed_in()
    future = datetime.fromtimestamp(clock.now() + 86400, timezone.utc).isoformat()
    past = datetime.fromtimestamp(clock.now() - 86400, timezone.utc).isoformat()
    good = {"frequency": "Weekly", "nextStartTimestamp": future, "mode": "Unloaded"}
    good["durationMinutes"] = 20
    for bad in (
        {"frequency": "Daily"},
        {"mode": "EcoExercise"},
        {"durationMinutes": 0},
        {"durationMinutes": 61},
        {"durationMinutes": "20"},
        {"nextStartTimestamp": "tomorrow"},
        {"nextStartTimestamp": None},
        {"nextStartTimestamp": past},
    ):
        await write(api, "PUT", f"/devices/{BLUE}/exercise", {**good, **bad}, status=400)
    await write(api, "PUT", f"/devices/{BLUE}/exercise", good)


async def test_schedule_delete(signed_in, clock):
    _, client, api = await signed_in()
    await write(api, "DELETE", f"/devices/{BLUE}/exercise")
    ex = (await api.record(BLUE))["exercise"]
    assert ex["mode"] == "None"
    assert ex["frequency"] is None and ex["nextStartTimestamp"] is None
    # Nothing starts on its own any more.
    await control(client, "advance", seconds=30 * 86400)
    assert (await api.record(BLUE))["engineState"] == "Standby"
    await control(client, "online", device=BLUE, online=False)
    await write(api, "DELETE", f"/devices/{BLUE}/exercise", status=409)


async def test_load_shed_set_value(signed_in):
    _, _, api = await signed_in()
    await write(api, "POST", f"/devices/{BLUE}/peripherals/3/set_value", {"value": True})
    rec = await api.record(BLUE)
    load_a = next(p for p in rec["loadShed"]["parameters"] if p["definitionId"] == 3)
    assert load_a["value"] is True
    await write(api, "POST", f"/devices/{BLUE}/peripherals/3/set_value", {"value": False})
    rec = await api.record(BLUE)
    assert not any(p["value"] for p in rec["loadShed"]["parameters"])


async def test_set_value_guards(signed_in):
    _, client, api = await signed_in()
    # PIM outputs are read only, whatever their isReadOnly flag says.
    for pid in (7, 9):
        body = await write(
            api, "POST", f"/devices/{BLUE}/peripherals/{pid}/set_value", {"value": True}, 400
        )
        assert "read only" in body["message"]
    await write(api, "POST", f"/devices/{BLUE}/peripherals/99/set_value", {"value": True}, 404)
    await write(api, "POST", f"/devices/{BLUE}/peripherals/x/set_value", {"value": True}, 404)
    await write(api, "POST", f"/devices/{BLUE}/peripherals/1/set_value", {"value": 1}, 400)
    # No load module connected on this one.
    await write(api, "POST", f"/devices/{REDGREEN}/peripherals/1/set_value", {"value": True}, 409)
    await control(client, "online", device=BLUE, online=False)
    await write(api, "POST", f"/devices/{BLUE}/peripherals/1/set_value", {"value": True}, 409)


async def test_rename_peripheral(signed_in):
    _, _, api = await signed_in()
    await write(api, "PUT", f"/devices/{LIQUID}/peripherals/1", {"displayName": " Pool Pump "})
    await write(api, "PUT", f"/devices/{LIQUID}/peripherals/8", {"displayName": "Gate Light"})
    rec = await api.record(LIQUID)
    assert rec["loadShed"]["parameters"][0]["displayName"] == "Pool Pump"
    assert rec["pim"]["parameters"][1]["displayName"] == "Gate Light"
    for bad in ("", "x" * 51, None, 5):
        await write(api, "PUT", f"/devices/{LIQUID}/peripherals/1", {"displayName": bad}, 400)
    await write(api, "PUT", f"/devices/{LIQUID}/peripherals/50", {"displayName": "A"}, 404)


async def test_writes_need_auth_and_own_device(signed_in):
    _, client, api = await signed_in()
    resp = await client.post(
        f"/kem/api/v3/devices/{BLUE}/exercise/start",
        json={"mode": "Unloaded"},
        headers={"ApiKey": "mock-api-key"},
    )
    assert resp.status == 401
    await write(api, "POST", "/devices/12345/exercise/start", {"mode": "Unloaded"}, 404)
