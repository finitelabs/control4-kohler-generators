from datetime import datetime

from conftest import BLUE, LIQUID, REDGREEN, control, events_named


def ts(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


async def test_unloaded_exercise_timeline(signed_in, clock):
    _, _, api = await signed_in()
    before = await api.record(BLUE)
    t0 = clock.now()
    await api.call("POST", f"/devices/{BLUE}/exercise/start", {"mode": "Unloaded"})

    rec = await api.record(BLUE)
    assert rec["engineState"] == "CrankOn"
    assert ts(rec["device"]["statusUpdateTimestamp"]) > ts(
        before["device"]["statusUpdateTimestamp"]
    )
    clock.advance(5)
    rec = await api.record(BLUE)
    assert rec["engineState"] == "PerformingUnloadedExercise"
    assert rec["engineStateDisplayNameEn"] == "Performing Unloaded Exercise"
    assert rec["engineSpeedRpm"] > 3000
    assert rec["powerSource"] == "Utility"
    assert rec["generatorLoadW"] == 0

    clock.advance(20 * 60 - 5)
    rec = await api.record(BLUE)
    assert rec["engineState"] == "CoolDown"
    assert rec["device"]["status"] == "Running"
    clock.advance(120)
    rec = await api.record(BLUE)
    assert rec["engineState"] == "Standby"
    assert rec["device"]["status"] == "ReadyToRun"
    assert rec["engineSpeedRpm"] == 0
    assert ts(rec["exercise"]["lastStartTimestamp"]) == int(t0)
    assert ts(rec["exercise"]["lastEndTimestamp"]) == int(t0) + 1200
    assert ts(rec["lastRanTimestamp"]) == int(t0)
    gained = rec["totalRuntimeHours"] - before["totalRuntimeHours"]
    assert abs(gained - (1200 + 120) / 3600) < 0.06

    events = await api.get(f"/devices/{BLUE}/events")
    assert [e["event"] for e in events] == [
        "Engine Stopped",
        "Exercise Ended",
        "Engine Started",
        "Exercise Active",
    ]
    assert events[0]["id"] > events[-1]["id"]
    assert events_named(events, "Engine Started")[0]["type"] == "runningNotice"
    notes = await api.get("/notifications")
    assert [n["type"] for n in notes] == [
        "EngineStoppedNotice",
        "ExerciseEndedNotice",
        "EngineStartedNotice",
        "ExerciseStartedNotice",
    ]
    assert notes[0]["deviceId"] == BLUE
    assert notes[0]["tag"] == "homeowneruser:91001"


async def test_events_are_appended_once(signed_in, clock):
    _, _, api = await signed_in()
    await api.call("POST", f"/devices/{BLUE}/exercise/start", {"mode": "Unloaded"})
    for _ in range(30):
        clock.advance(60)
        await api.record(BLUE)
        await api.get(f"/devices/{BLUE}/events")
    events = await api.get(f"/devices/{BLUE}/events")
    assert len(events) == 4
    assert len({e["id"] for e in events}) == 4
    assert len(await api.get("/notifications")) == 4


async def test_loaded_exercise_moves_to_generator_power(signed_in, clock):
    _, _, api = await signed_in()
    await api.call("POST", f"/devices/{BLUE}/exercise/start", {"mode": "LoadedFullSpeed"})
    clock.advance(5)
    rec = await api.record(BLUE)
    assert rec["engineState"] == "PerformingLoadedExercise"
    assert rec["powerSource"] == "Utility"
    clock.advance(3)
    rec = await api.record(BLUE)
    assert rec["powerSource"] == "Generator"
    # This controller reports load as negative numbers.
    assert rec["generatorLoadW"] < 0 and rec["generatorLoadPercent"] < 0
    assert rec["generatorLoadPercent"] == -round(7850 / 20000 * 100)
    clock.advance(20 * 60)
    rec = await api.record(BLUE)
    assert rec["powerSource"] == "Utility"
    assert rec["engineState"] == "CoolDown"


async def test_outage_and_restore(signed_in, clock):
    _, client, api = await signed_in()
    await control(client, "outage", device=REDGREEN)
    rec = await api.record(REDGREEN)
    assert rec["utilityVoltageV"] == 0
    assert rec["engineState"] == "Standby"
    clock.advance(3)
    assert (await api.record(REDGREEN))["engineState"] == "CrankOn"
    clock.advance(5)
    rec = await api.record(REDGREEN)
    assert rec["engineState"] == "Running"
    assert rec["device"]["status"] == "Running"
    assert rec["powerSource"] == "Utility"
    clock.advance(3)
    rec = await api.record(REDGREEN)
    assert rec["powerSource"] == "Generator"
    # This controller reports load as positive numbers.
    assert rec["generatorLoadW"] == 5400
    assert rec["generatorLoadPercent"] == round(5400 / 14000 * 100)

    await control(client, "restore", device=REDGREEN)
    rec = await api.record(REDGREEN)
    assert rec["utilityVoltageV"] > 200
    assert rec["powerSource"] == "Generator"
    clock.advance(60)
    rec = await api.record(REDGREEN)
    assert rec["powerSource"] == "Utility"
    assert rec["engineState"] == "CoolDown"
    clock.advance(120)
    rec = await api.record(REDGREEN)
    assert rec["engineState"] == "Standby"
    assert rec["device"]["status"] == "ReadyToRun"
    events = [e["event"] for e in await api.get(f"/devices/{REDGREEN}/events")]
    assert events == [
        "Engine Stopped",
        "Utility Power Restored",
        "Engine Started",
        "Utility Power Lost",
    ]


async def test_brief_outage_never_starts_the_engine(signed_in, clock):
    _, client, api = await signed_in()
    await control(client, "outage", device=BLUE)
    clock.advance(2)
    await control(client, "restore", device=BLUE)
    clock.advance(600)
    rec = await api.record(BLUE)
    assert rec["engineState"] == "Standby"
    events = [e["event"] for e in await api.get(f"/devices/{BLUE}/events")]
    assert events == ["Utility Power Restored", "Utility Power Lost"]


async def test_outage_during_exercise(signed_in, clock):
    _, client, api = await signed_in()
    await api.call("POST", f"/devices/{BLUE}/exercise/start", {"mode": "Unloaded"})
    clock.advance(60)
    await control(client, "outage", device=BLUE)
    rec = await api.record(BLUE)
    assert rec["engineState"] == "Running"
    assert rec["device"]["status"] == "Running"
    clock.advance(3)
    assert (await api.record(BLUE))["powerSource"] == "Generator"
    # The exercise's end time passes; the engine keeps carrying the house.
    clock.advance(30 * 60)
    rec = await api.record(BLUE)
    assert rec["engineState"] == "Running"
    assert rec["powerSource"] == "Generator"


async def test_liquid_cooled_readings_while_running(signed_in, clock):
    _, client, api = await signed_in()
    await control(client, "outage", device=LIQUID)
    clock.advance(11)
    rec = await api.record(LIQUID)
    assert rec["engineSpeedRpm"] == 1801
    assert rec["engineOilPressurePsi"] > 40
    assert rec["engineCoolantTempF"] > 150
    assert rec["generatorLoadW"] == -21600


async def test_scheduled_exercise_runs_on_its_own(signed_in, clock):
    _, client, api = await signed_in()
    rec = await api.record(BLUE)
    nxt = ts(rec["exercise"]["nextStartTimestamp"])
    await control(client, "advance", seconds=nxt - clock.now() + 30)
    rec = await api.record(BLUE)
    assert rec["engineState"] == "PerformingUnloadedExercise"
    assert rec["device"]["status"] == "RunningExercise"
    assert ts(rec["exercise"]["nextStartTimestamp"]) == nxt + 7 * 86400
    assert ts(rec["exercise"]["lastStartTimestamp"]) == nxt


async def test_scheduled_exercise_catches_up_after_a_quiet_week(signed_in, clock):
    _, client, api = await signed_in()
    nxt = ts((await api.record(BLUE))["exercise"]["nextStartTimestamp"])
    await control(client, "advance", seconds=nxt - clock.now() + 86400)
    rec = await api.record(BLUE)
    assert rec["engineState"] == "Standby"
    assert ts(rec["exercise"]["lastStartTimestamp"]) == nxt
    assert ts(rec["lastRanTimestamp"]) == nxt
    events = await api.get(f"/devices/{BLUE}/events")
    assert ts(events[-1]["timestamp"]) == nxt


async def test_monthly_schedule_rolls_by_calendar_month(signed_in, clock):
    _, client, api = await signed_in()
    rec = await api.record(LIQUID)
    nxt = rec["exercise"]["nextStartTimestamp"]
    await control(client, "advance", seconds=ts(nxt) - clock.now() + 60)
    rolled = (await api.record(LIQUID))["exercise"]["nextStartTimestamp"]
    a, b = datetime.fromisoformat(nxt[:-1]), datetime.fromisoformat(rolled[:-1])
    assert (b.month - a.month) % 12 == 1
    assert (b.hour, b.minute) == (a.hour, a.minute)


async def test_operation_hours_always_accrue(signed_in, clock):
    _, client, api = await signed_in()
    before = await api.record(BLUE)
    await control(client, "advance", seconds=3600)
    after = await api.record(BLUE)
    assert round(after["totalOperationHours"] - before["totalOperationHours"], 1) == 1.0
    assert after["totalRuntimeHours"] == before["totalRuntimeHours"]


async def test_no_exercise_during_an_outage(signed_in, clock):
    _, client, api = await signed_in()
    await control(client, "outage", device=BLUE)
    clock.advance(1)
    resp = await api.call("POST", f"/devices/{BLUE}/exercise/start", {"mode": "Unloaded"})
    assert resp.status == 409
    assert "Utility power is out" in (await resp.json())["message"]
    clock.advance(60)
    rec = await api.record(BLUE)
    assert rec["engineState"] == "Running"
    assert rec["powerSource"] == "Generator"
