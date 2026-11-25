import time

from conftest import (
    API,
    BLUE,
    EMAIL,
    PASSWORD,
    REDGREEN,
    SCOPE,
    TOKEN_PATH,
    control,
    headers,
    sign_in,
    token_call,
)


async def test_index_and_state(signed_in):
    _, client, api = await signed_in()
    actions = (await (await client.get("/_mock")).json())["actions"]
    assert {"outage", "fault", "fail", "reset"} <= set(actions)
    await api.get("/homeowner/me")
    state = await (await client.get("/_mock/state")).json()
    assert state["generators"][str(BLUE)]["engine"] == "Standby"
    assert state["calls"][-1] == {"method": "GET", "path": f"{API}/homeowner/me", "status": 200}
    page = await client.get("/")
    assert "Demo Generator" in await page.text()


async def test_bad_control_calls(signed_in):
    _, client, _ = await signed_in()
    assert (await client.post("/_mock/nothing", json={})).status == 404
    assert (await client.post("/_mock/outage", json={"device": 1})).status == 400
    assert (await client.post("/_mock/switch", json={"device": BLUE})).status == 400
    bad = {"device": BLUE, "position": "Sideways"}
    assert (await client.post("/_mock/switch", json=bad)).status == 400
    assert (await client.post("/_mock/outage", data="x")).status == 400


async def test_fault_and_clear(signed_in, clock):
    _, client, api = await signed_in()
    await control(client, "outage", device=BLUE)
    clock.advance(20)
    await control(client, "fault", device=BLUE, event="Overcrank")
    rec = await api.record(BLUE)
    assert rec["device"]["status"] == "Shutdown"
    assert rec["engineState"] == "Shutdown"
    assert rec["device"]["alertCount"] == 1
    alerts = await api.get(f"/devices/{BLUE}/alerts")
    assert alerts[0]["event"] == "Overcrank"
    assert alerts[0]["level"] == "Shutdown"
    assert alerts[0]["isCriticalFault"] is True
    events = await api.get(f"/devices/{BLUE}/events")
    assert events[0]["level"] == "Shutdown" and events[0]["isCriticalFault"] is True
    assert events[1]["event"] == "Engine Stopped"
    assert (await api.get("/notifications"))[0]["type"] == "Shutdown"
    # Clearing it during the outage lets the generator start again.
    await control(client, "clear", device=BLUE)
    assert await api.get(f"/devices/{BLUE}/alerts") == []
    clock.advance(11)
    rec = await api.record(BLUE)
    assert rec["engineState"] == "Running"
    assert rec["powerSource"] == "Generator"


async def test_warning(signed_in):
    _, client, api = await signed_in()
    await control(client, "warning", device=BLUE, event="High Battery Voltage")
    rec = await api.record(BLUE)
    assert rec["device"]["status"] == "ReadyToRun"
    assert rec["device"]["alertCount"] == 1
    alert = (await api.get(f"/devices/{BLUE}/alerts"))[0]
    assert (alert["level"], alert["isCriticalFault"]) == ("Warning", False)
    assert (await api.get("/notifications"))[0]["type"] == "Warning"


async def test_low_battery(signed_in):
    _, client, api = await signed_in()
    await control(client, "battery", device=BLUE, low=True)
    rec = await api.record(BLUE)
    assert rec["batteryVoltageV"] < 12
    assert (await api.get(f"/devices/{BLUE}/alerts"))[0]["event"] == "Low Battery Voltage"
    await control(client, "battery", device=BLUE, low=False)
    assert (await api.record(BLUE))["batteryVoltageV"] > 13
    assert await api.get(f"/devices/{BLUE}/alerts") == []


async def test_switch_positions(signed_in, clock):
    _, client, api = await signed_in()
    await control(client, "switch", device=BLUE, position="Off")
    rec = await api.record(BLUE)
    assert (rec["switchState"], rec["engineState"]) == ("Off", "Off")
    assert rec["device"]["status"] == "SwitchStateOff"
    # Off: an outage starts nothing.
    await control(client, "outage", device=BLUE)
    clock.advance(60)
    assert (await api.record(BLUE))["engineState"] == "Off"
    # Manual runs the engine and carries the house while the utility is out.
    await control(client, "switch", device=BLUE, position="Manual")
    clock.advance(10)
    rec = await api.record(BLUE)
    assert (rec["engineState"], rec["powerSource"]) == ("Running", "Generator")
    assert rec["device"]["status"] == "Running"
    # Auto during the outage keeps it running; restore brings it down.
    await control(client, "switch", device=BLUE, position="Auto")
    await control(client, "restore", device=BLUE)
    clock.advance(60 + 120)
    rec = await api.record(BLUE)
    assert (rec["engineState"], rec["powerSource"]) == ("Standby", "Utility")
    # Off while running stops it at once, without a cool-down.
    await api.call("POST", f"/devices/{BLUE}/exercise/start", {"mode": "Unloaded"})
    clock.advance(30)
    await control(client, "switch", device=BLUE, position="Off")
    rec = await api.record(BLUE)
    assert rec["engineState"] == "Off"
    assert rec["exercise"]["runningMode"] is None


async def test_offline_freezes_the_record_and_holds_events(signed_in, clock):
    _, client, api = await signed_in()
    await control(client, "online", device=BLUE, online=False)
    frozen = await api.record(BLUE)
    assert frozen["device"]["isConnected"] is False
    await control(client, "outage", device=BLUE)
    clock.advance(20)
    rec = await api.record(BLUE)
    assert rec["engineState"] == "Standby"
    assert rec["utilityVoltageV"] == frozen["utilityVoltageV"]
    assert await api.get(f"/devices/{BLUE}/events") == []
    await control(client, "online", device=BLUE, online=True)
    rec = await api.record(BLUE)
    assert rec["device"]["isConnected"] is True
    assert rec["engineState"] == "Running"
    events = [e["event"] for e in await api.get(f"/devices/{BLUE}/events")]
    assert events == ["Engine Started", "Utility Power Lost"]
    assert await api.get(f"/devices/{BLUE}/alerts") == []


async def test_account_remove_and_add(signed_in):
    _, client, api = await signed_in()
    await control(client, "account", email=EMAIL, op="remove", device=REDGREEN)
    resp = await api.call("GET", f"/devices/{REDGREEN}")
    assert resp.status == 404
    homes = await api.get("/homeowner/homes")
    assert homes[1]["devices"] == []
    await control(client, "account", email=EMAIL, op="add", device=REDGREEN)
    assert (await api.record(REDGREEN))["device"]["id"] == REDGREEN
    await control(
        client, "account", email=EMAIL, op="add", device=58010, profile="air-20kw-blue-ng", home=1
    )
    homes = await api.get("/homeowner/homes")
    assert [d["id"] for d in homes[1]["devices"]] == [REDGREEN, 58010]
    assert homes[1]["devices"][1]["serialNumber"] == "DEMO058010"
    resp = await client.post("/_mock/account", json={"email": EMAIL, "op": "add", "device": BLUE})
    assert resp.status == 400


async def test_slow_answers(signed_in):
    _, client, api = await signed_in()
    await control(client, "slow", seconds=0.2, target="api")
    start = time.monotonic()
    await api.get("/homeowner/me")
    assert time.monotonic() - start >= 0.2
    start = time.monotonic()
    await sign_in(client)
    assert time.monotonic() - start < 0.2
    await control(client, "slow", seconds=0)
    assert (await (await client.get("/_mock/state")).json())["slow"] is None


async def test_rate_limit_then_recover(signed_in):
    _, client, api = await signed_in()
    await control(client, "fail", status=429, count=2, target="api", retry_after=12)
    for _ in range(2):
        resp = await api.call("GET", "/homeowner/me")
        assert resp.status == 429
        assert resp.headers["Retry-After"] == "12"
    assert (await api.call("GET", "/homeowner/me")).status == 200


async def test_server_errors_on_token_endpoint(signed_in):
    _, client, api = await signed_in()
    await control(client, "fail", status=503, count=1, target="token")
    assert (await api.call("GET", "/homeowner/me")).status == 200
    data = {"grant_type": "password", "username": EMAIL, "password": PASSWORD, "scope": SCOPE}
    resp = await token_call(client, data)
    assert resp.status == 503
    assert (await resp.json())["error"] == "server_error"
    assert (await token_call(client, data)).status == 200
    await control(client, "fail", status=500, count=5)
    assert (await api.call("GET", "/homeowner/me")).status == 500
    await control(client, "fail", status=None)
    assert (await api.call("GET", "/homeowner/me")).status == 200
    assert (await client.post("/_mock/fail", json={"status": 404})).status == 400


async def test_revoke_and_expire(make_cloud):
    _, client = await make_cloud()
    tok = await sign_in(client)
    await control(client, "expire", email=EMAIL)
    resp = await client.get(f"{API}/homeowner/me", headers=headers(tok["access_token"]))
    assert resp.status == 401
    resp = await token_call(
        client, {"grant_type": "refresh_token", "refresh_token": tok["refresh_token"]}
    )
    assert resp.status == 200
    fresh = await resp.json()
    await control(client, "revoke")
    resp = await token_call(
        client, {"grant_type": "refresh_token", "refresh_token": fresh["refresh_token"]}
    )
    assert resp.status == 400
    # The access token from before the revoke still works until it expires.
    resp = await client.get(f"{API}/homeowner/me", headers=headers(fresh["access_token"]))
    assert resp.status == 200


async def test_password_change(make_cloud):
    _, client = await make_cloud()
    tok = await sign_in(client)
    await control(client, "password", email=EMAIL, password="new-demo-password")
    data = {"grant_type": "password", "username": EMAIL, "password": PASSWORD, "scope": SCOPE}
    assert (await token_call(client, data)).status == 400
    resp = await token_call(
        client, {"grant_type": "refresh_token", "refresh_token": tok["refresh_token"]}
    )
    assert resp.status == 400
    await sign_in(client, password="new-demo-password")


async def test_advance_and_exercise_now(signed_in):
    _, client, api = await signed_in()
    before = await api.record(BLUE)
    await control(client, "advance", seconds=7200)
    after = await api.record(BLUE)
    assert round(after["totalOperationHours"] - before["totalOperationHours"], 1) == 2.0
    await control(client, "exercise_now", device=BLUE)
    rec = await api.record(BLUE)
    assert rec["exercise"]["runningMode"] == "Unloaded"
    assert rec["exercise"]["nextStartTimestamp"] == before["exercise"]["nextStartTimestamp"]
    resp = await client.post("/_mock/exercise_now", json={"device": BLUE})
    assert resp.status == 400


async def test_reset(signed_in, clock):
    _, client, api = await signed_in()
    await control(client, "fault", device=BLUE)
    await control(client, "account", email=EMAIL, op="remove", device=REDGREEN)
    await control(client, "reset")
    rec = await api.record(BLUE)
    assert rec["device"]["status"] == "ReadyToRun"
    assert (await api.record(REDGREEN))["device"]["id"] == REDGREEN
    # The token from before the reset still works.
    assert await api.get(f"/devices/{BLUE}/events") == []


async def test_unknown_paths(signed_in):
    _, client, api = await signed_in()
    assert (await api.call("GET", "/nothing")).status == 404
    assert (await client.get(TOKEN_PATH)).status == 405


async def test_reset_keeps_ids_moving(signed_in):
    _, client, api = await signed_in()
    await control(client, "warning", device=BLUE)
    first = (await api.get(f"/devices/{BLUE}/events"))[0]["id"]
    await control(client, "reset")
    await control(client, "warning", device=BLUE)
    second = (await api.get(f"/devices/{BLUE}/events"))[0]["id"]
    assert second > first


async def test_readded_generator_joins_the_named_home(signed_in):
    _, client, api = await signed_in()
    await control(client, "account", email=EMAIL, op="remove", device=REDGREEN)
    await control(client, "account", email=EMAIL, op="add", device=REDGREEN, home=0)
    homes = await api.get("/homeowner/homes")
    assert REDGREEN in [d["id"] for d in homes[0]["devices"]]
    assert REDGREEN not in [d["id"] for d in homes[1]["devices"]]


async def test_fail_count_must_be_positive(signed_in):
    _, client, api = await signed_in()
    resp = await client.post("/_mock/fail", json={"status": 503, "count": 0})
    assert resp.status == 400
    await api.record(BLUE)
