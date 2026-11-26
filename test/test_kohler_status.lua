-- kohler.status: what a generator's record, alerts and events say, read from the states the mock
-- writes to test/fixtures/kohler (make kohler-fixtures), and what changed between two reads.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_kohler_status.lua

local T = require("testlib")

require("c4_shim")
local JSON = require("JSON")
local Generator = require("kohler.generator")
local Status = require("kohler.status")

local FIXTURES = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/kohler/"

--- @param name string
--- @return table
local function fixture(name)
  local file = assert(io.open(FIXTURES .. name, "r"))
  local body = file:read("*a")
  file:close()
  return JSON:decode(body)
end

--- The mock's fixed clock, when the fixtures were taken.
local NOW = 1790000000

--- @param name string
--- @param scale? string
--- @return KohlerStatus
local function state(name, scale)
  return Status.fromRecord(fixture("state-" .. name .. ".json"), NOW, scale or "F")
end

--- @param s KohlerStatus
--- @return table
local function flags(s)
  return {
    utilityOut = s.utilityOut,
    running = s.running,
    exercising = s.exercising,
    inAuto = s.inAuto,
    maintenanceDue = s.maintenanceDue,
  }
end

T.section("a generator in standby")
local standby = state("standby")
T.eq("online", standby.online, true)
T.eq("its status as words", standby.status, "Ready To Run")
T.eq("its engine state as the app names it", standby.engineState, "Standby")
T.eq("on utility power", standby.powerSource, "Utility")
T.eq("not on generator power", standby.onGeneratorPower, false)
T.eq("utility not out", standby.utilityOut, false)
T.eq("not running", standby.running, false)
T.eq("not exercising", standby.exercising, false)
T.eq("in Auto", standby.inAuto, true)
T.eq("the switch position", standby.switchPosition, "Auto")
T.eq("not shut down", standby.shutDown, false)
T.eq("the utility voltage", standby.readings["Utility Voltage"], 241.6)
local listed = {}
for _, name in ipairs(Status.READINGS) do
  listed[name] = true
end
for name in pairs(standby.readings) do
  T.truthy("a listed reading: " .. name, listed[name])
end
T.eq("the battery", standby.readings["Battery Voltage"], 13.6)
T.eq("oil pressure OK", standby.oilPressureOk, true)
T.eq("no load at standby", standby.readings["Load Watts"], 0)
T.eq("a reading its controller doesn't report is nil, not 0", standby.readings["Coolant Temperature"], nil)
T.eq("the controller temperature in Fahrenheit", standby.readings["Controller Temperature"], 74.3)
T.eq("maintenance not due", standby.maintenanceDue, false)
T.eq(
  "the next exercise as the controller shows it",
  standby.nextExercise,
  os.date("%Y-%m-%d %H:%M", Generator.time(fixture("state-standby.json").exercise.nextStartTimestamp))
)
T.truthy(
  "the schedule names its frequency",
  standby.exerciseSchedule:find("^Weekly, ") ~= nil,
  standby.exerciseSchedule
)
T.truthy(
  "and its mode and length",
  standby.exerciseSchedule:find(", Unloaded, 20 minutes$") ~= nil,
  standby.exerciseSchedule
)
T.eq("each load-shed load, off", #standby.loads, 6)
T.eq("named as the app names it", standby.loads[1].name, "HVAC A")
T.eq("off", standby.loads[1].on, false)

local lowOil = fixture("state-standby.json")
lowOil.engineOilPressureOk = false
T.eq("low oil pressure reads false", Status.fromRecord(lowOil, NOW, "F").oilPressureOk, false)
lowOil.engineOilPressureOk = nil
T.eq("and none reported, nil", Status.fromRecord(lowOil, NOW, "F").oilPressureOk, nil)

T.section("temperatures follow the project's scale")
T.eq("Celsius, to a tenth", state("standby", "C").readings["Controller Temperature"], 23.5)
T.eq("a missing one stays nil", state("standby", "C").readings["Coolant Temperature"], nil)

T.section("an outage, with the generator carrying the house")
local outage = state("outage")
T.eq("utility out", outage.utilityOut, true)
T.eq("on generator power", outage.onGeneratorPower, true)
T.eq("running", outage.running, true)
T.eq("not exercising", outage.exercising, false)

T.truthy("load reads as a positive number", (outage.readings["Load Watts"] or 0) > 0, outage.readings["Load Watts"])
T.truthy("as does its percentage", (outage.readings["Load Percent"] or 0) > 0, outage.readings["Load Percent"])
T.eq("busy, so polled faster", Status.busy(fixture("state-outage.json")), true)
T.eq("standby is not busy", Status.busy(fixture("state-standby.json")), false)
T.eq(
  "its transitions from standby",
  Status.transitions(flags(standby), flags(outage)),
  { "Utility Power Lost", "Engine Started" }
)

T.section("a generator that doesn't sense utility voltage reports 0 volts on utility power")
local unsensed = fixture("device-58001.json")
unsensed.device.id = 59001
unsensed.utilityVoltageV = 0
unsensed.generatorVoltageAvgV = 0
T.eq("utility not out", Status.fromRecord(unsensed, NOW, "F").utilityOut, false)
T.eq("its utility voltage has no value", Status.fromRecord(unsensed, NOW, "F").readings["Utility Voltage"], nil)
T.eq("its generator voltage still reads", Status.fromRecord(unsensed, NOW, "F").readings["Generator Voltage"], 0)
T.eq("not busy", Status.busy(unsensed), false)
unsensed.powerSource = "Generator"
T.eq("on generator power, it is out", Status.fromRecord(unsensed, NOW, "F").utilityOut, true)

T.section("once it has reported a live line, 0 volts is an outage")
unsensed.powerSource = "Utility"
unsensed.utilityVoltageV = 240.1
T.eq("a live line", Status.fromRecord(unsensed, NOW, "F").utilityOut, false)
unsensed.utilityVoltageV = 0
T.eq("then 0 volts is out", Status.fromRecord(unsensed, NOW, "F").utilityOut, true)
T.eq("and reads 0 volts", Status.fromRecord(unsensed, NOW, "F").readings["Utility Voltage"], 0)

T.section("power restored")
local restored = state("restored")
T.eq("utility back", restored.utilityOut, false)
T.eq("engine stopped after cool-down", restored.running, false)
T.eq(
  "its transitions from the outage",
  Status.transitions(flags(outage), flags(restored)),
  { "Utility Power Restored", "Engine Stopped" }
)

T.section("an exercise")
local exercise = state("exercise")
T.eq("exercising", exercise.exercising, true)
T.eq("running", exercise.running, true)
T.eq("utility not out: an exercise is not an outage", exercise.utilityOut, false)
T.eq("busy", Status.busy(fixture("state-exercise.json")), true)
T.eq(
  "its transitions from standby",
  Status.transitions(flags(standby), flags(exercise)),
  { "Exercise Started", "Engine Started" }
)
T.eq("and back", Status.transitions(flags(exercise), flags(standby)), { "Engine Stopped", "Exercise Ended" })

T.section("a fault")
local fault = state("fault")
T.eq("shut down", fault.shutDown, true)
T.eq("not running", fault.running, false)
local faultAlerts = Status.alerts(fixture("state-fault-alerts.json"))
T.eq("one alert", faultAlerts.count, 1)
T.eq("a fault", faultAlerts.fault, true)
T.eq("named", faultAlerts.last, "Over Crank")

T.section("a warning and its clearing")
local warning = Status.alerts(fixture("state-warning-alerts.json"))
T.eq("one alert", warning.count, 1)
T.eq("not a fault", warning.fault, false)
T.eq("named", warning.last, "Parameter Value Abnormal")
T.eq("cleared: none", Status.alerts(fixture("state-cleared-alerts.json")).count, 0)
T.eq("Not Connected is not counted", Status.alerts({ { id = -1, level = "None", event = "Not Connected" } }).count, 0)

T.section("the switch off Auto")
local off = state("switch-off")
T.eq("not in Auto", off.inAuto, false)
T.eq("the position", off.switchPosition, "Off")
T.eq("its transition", Status.transitions(flags(standby), flags(off)), { "Switch Not In Auto" })
T.eq("and back", Status.transitions(flags(off), flags(standby)), { "Switch Back In Auto" })

T.section("maintenance")
local record = fixture("state-standby.json")
local due = Generator.time(record.device.nextMaintenanceTimestamp)
T.eq("not due the second before", Status.fromRecord(record, due - 1, "F").maintenanceDue, false)
T.eq("due from then", Status.fromRecord(record, due, "F").maintenanceDue, true)
T.eq(
  "its transition",
  Status.transitions({ maintenanceDue = false, inAuto = true }, { maintenanceDue = true, inAuto = true }),
  { "Maintenance Due" }
)

T.section("no transitions on the first read since start-up")
T.eq("none from nil", Status.transitions(nil, flags(outage)), {})

T.section("the event log")
local events = fixture("state-low-battery-events.json")
local _, first = Status.news(events, nil)
T.eq("no news the first time ever, only the cursor", first, events[1].id)
local quiet = Status.news(events, first)
T.eq("nothing new at the cursor", quiet, { fault = false, warning = false, lowBattery = false })
local news, cursor = Status.news(events, first - 1)
T.eq("a new low battery is a warning too", news, { fault = false, warning = true, lowBattery = true })
T.eq("the cursor moves to it", cursor, first)
local faultNews = Status.news(fixture("state-fault-events.json"), 0)
T.eq("a shutdown is a fault", faultNews.fault, true)
local at = Generator.time(events[1].timestamp)
T.eq("an event older than `since` is not news", Status.news(events, first - 1, at + 1).lowBattery, false)
T.eq("one at `since` is", Status.news(events, first - 1, at).lowBattery, true)

local _, empty = Status.news({}, nil)
T.eq("an empty first log saves a cursor of 0", empty, 0)
T.eq("so the first event ever logged is news", Status.news(events, empty).lowBattery, true)

local restarted, moved = Status.news(events, first + 1000)
T.eq("ids that start again below the cursor are not news", restarted.lowBattery, false)
T.eq("they become the cursor", moved, first)
T.eq("so the next one is", Status.news(events, first - 1).lowBattery, true)

T.section("the Navigator icon follows the state, highest first")
local function icon(online, s, isFault)
  local id, description = Status.icon(online, s, isFault)
  return id .. " " .. description
end
T.eq("standby", icon(true, standby, false), "standby Standby")
T.eq("an exercise runs the engine but shows as exercising", icon(true, exercise, false), "exercising Exercising")
T.eq("an outage, running on the generator", icon(true, outage, false), "utility_out Utility power out")
T.eq("running out of an exercise", icon(true, { running = true }, false), "running Running")
T.eq("a fault over everything but offline", icon(true, outage, true), "fault Fault")
T.eq("the fault fixture", icon(true, fault, fault.shutDown), "fault Fault")
T.eq("offline over a fault", icon(false, outage, true), "offline Offline")
T.eq(
  "utility out over an exercise",
  icon(true, { utilityOut = true, exercising = true, running = true }, false),
  "utility_out Utility power out"
)
T.eq("before the first record", icon(true, nil, false), "offline Offline")
T.eq("offline before the first record", icon(false, nil, false), "offline Offline")

T.section("the schedule line")
T.eq("none", Status.schedule(nil), "None")
T.eq("none without a frequency", Status.schedule({ frequency = nil }), "None")

T.section("local times read by the generator's clock, not the controller's")
-- A generator 5 hours behind UTC all year, read in December by a controller that may be on
-- standard time. Its 14:00 is 19:00 UTC.
local winter = fixture("device-58003.json")
winter.controllerClockTimestamp = "2026-12-01T09:05:37"
winter.device.latestParameterUpdateTimestamp = "2026-12-01T14:07:07+00:00"
winter.exercise.nextStartTimestamp = "2026-12-01T14:00:00"
winter.device.nextMaintenanceTimestamp = "2026-12-08T09:00:00"
local s = Status.fromRecord(winter, NOW, "F")
local exerciseAt = Generator.time("2026-12-01T19:00:00Z")
T.eq("the next exercise", s.nextExercise, Status.formatTime(exerciseAt))
T.eq("the next maintenance", s.nextMaintenance, Status.formatTime(Generator.time("2026-12-08T14:00:00Z")))
local t = os.date("*t", exerciseAt)
T.truthy(
  "the schedule line's time",
  s.exerciseSchedule:find(string.format(" %02d:%02d,", t.hour, t.min), 1, true),
  s.exerciseSchedule
)

T.finish()
