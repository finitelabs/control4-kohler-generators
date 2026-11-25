-- kohler.controls: each command's request as the mock takes it, and each guard the KOHLER app
-- applies refusing a command before anything is sent, from the mock's records.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_kohler_controls.lua

local T = require("testlib")

local JSON = require("JSON")
local Controls = require("kohler.controls")

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

local standby = fixture("state-standby.json")

T.section("Start Exercise")
local request, refusal = Controls.request({ action = "start", mode = "Unloaded Full Speed" }, standby, NOW)
T.eq("not refused", refusal, nil)
T.eq("a POST", request.method, "POST")
T.eq("to exercise/start", request.path, "/devices/58001/exercise/start")
T.eq("with the mode as the cloud names it", request.body, { mode = "UnloadedFullSpeed" })
_, refusal = Controls.request({ action = "start" }, standby, NOW)
T.eq("needs a mode", refusal, "Choose an exercise mode")
_, refusal = Controls.request({ action = "start", mode = "Eco" }, standby, NOW)
T.eq("only the modes the command offers", refusal, "Choose an exercise mode")

T.section("Start Exercise is refused as the app refuses it")
local cases = {
  { "with no record yet", nil, "Waiting for the generator's first reading" },
  { "while offline", fixture("device-58004.json"), "The generator is offline" },
  { "while the utility is out", fixture("state-outage.json"), "Utility power is out" },
  { "while an exercise runs", fixture("state-exercise.json"), "The generator is already running" },
  { "with the switch off", fixture("state-switch-off.json"), "The generator's switch is not in Auto" },
  { "while shut down by a fault", fixture("state-fault.json"), "The generator is not ready to run (Shutdown)" },
}
for _, case in ipairs(cases) do
  local r, why = Controls.request({ action = "start", mode = "Unloaded" }, case[2], NOW)
  T.eq(case[1], why, case[3])
  T.eq(case[1] .. ": nothing to send", r, nil)
end

T.section("Stop Exercise")
request, refusal = Controls.request({ action = "stop" }, fixture("state-exercise.json"), NOW)
T.eq("while an exercise runs", refusal, nil)
T.eq("POST exercise/stop", request.method .. " " .. request.path, "POST /devices/58001/exercise/stop")
T.eq("with no body", request.body, nil)
_, refusal = Controls.request({ action = "stop" }, standby, NOW)
T.eq("refused with none running", refusal, "No exercise is running")
_, refusal = Controls.request({ action = "stop" }, fixture("state-outage.json"), NOW)
T.eq("refused during an outage, which is no exercise", refusal, "No exercise is running")

T.section("Set Exercise Schedule")
local schedule = {
  action = "schedule",
  frequency = "Every Other Week",
  day = "Tuesday",
  time = "2:30 PM",
  mode = "Unloaded",
  minutes = "25",
}
request, refusal = Controls.request(schedule, standby, NOW)
T.eq("not refused", refusal, nil)
T.eq("PUT exercise", request.method .. " " .. request.path, "PUT /devices/58001/exercise")
T.eq("frequency as the cloud names it", request.body.frequency, "EveryOtherWeek")
T.eq("mode", request.body.mode, "Unloaded")
T.eq("minutes as a whole number", request.body.durationMinutes, 25)
local start = Controls.nextStart("Tuesday", 14, 30, NOW)
T.eq(
  "the next Tuesday at 14:30, with Z as the record wrote it",
  request.body.nextStartTimestamp,
  os.date("!%Y-%m-%dT%H:%M:%SZ", start)
)
T.eq("which is a Tuesday", os.date("%A %H:%M", start), "Tuesday 14:30")
T.truthy("after now", start > NOW and start <= NOW + 7 * 86400)

local naive = fixture("device-58003.json")
request = Controls.request(schedule, naive, NOW)
T.eq(
  "local with no offset when the record wrote it so",
  request.body.nextStartTimestamp,
  os.date("%Y-%m-%dT%H:%M:%S", start)
)
local offset = fixture("state-standby.json")
offset.exercise.nextStartTimestamp = "2026-09-26T10:00:00.1234567-05:00"
request = Controls.request(schedule, offset, NOW)
T.truthy(
  "with an offset when the record wrote one",
  request.body.nextStartTimestamp:match(
    "^" .. os.date("%Y-%m-%dT%H:%M:%S", start):gsub("%-", "%%-") .. "[%+%-]%d%d:%d%d$"
  )
)
T.eq("an offset that names the same moment", require("kohler.generator").time(request.body.nextStartTimestamp), start)

for _, case in ipairs({
  { "frequency", nil, "Choose how often the generator exercises" },
  { "mode", "Eco", "Choose an exercise mode" },
  { "time", "25:00", "Enter the time as 10:00 or 10:00 AM" },
  { "time", "13:00 PM", "Enter the time as 10:00 or 10:00 AM" },
  { "minutes", "4", "Exercise for 5 to 60 minutes" },
  { "minutes", "61", "Exercise for 5 to 60 minutes" },
  { "minutes", "12.5", "Exercise for 5 to 60 minutes" },
  { "day", "Someday", "Choose a day of the week" },
}) do
  local bad = {}
  for k, v in pairs(schedule) do
    bad[k] = v
  end
  bad[case[1]] = case[2]
  local r, why = Controls.request(bad, standby, NOW)
  T.eq(string.format("refuses %s %s", case[1], tostring(case[2])), why, case[3])
  T.eq("and sends nothing", r, nil)
end
_, refusal = Controls.request(schedule, fixture("device-58004.json"), NOW)
T.eq("refused while offline", refusal, "The generator is offline")

T.section("a time of day")
T.eq("24-hour", { Controls.timeOfDay("14:05") }, { 14, 5 })
T.eq("PM", { Controls.timeOfDay("2:05 pm") }, { 14, 5 })
T.eq("12 AM is midnight", { Controls.timeOfDay("12:00 AM") }, { 0, 0 })
T.eq("12 PM is noon", { Controls.timeOfDay("12:00PM") }, { 12, 0 })
T.eq("minutes past 59", Controls.timeOfDay("10:60"), nil)

T.section("the next start rolls to next week once today's time has passed")
local today = os.date("%A", NOW)
local t = os.date("*t", NOW)
local earlier = Controls.nextStart(today, 0, 0, NOW)
T.eq("today at midnight has passed: next week", os.date("%Y-%m-%d", earlier), os.date("%Y-%m-%d", NOW + 7 * 86400))
if t.hour < 23 then
  local later = Controls.nextStart(today, 23, 59, NOW)
  T.eq("today at 23:59 has not", os.date("%Y-%m-%d", later), os.date("%Y-%m-%d", NOW))
end

T.section("Set Load")
request, refusal = Controls.request({ action = "load", load = "HVAC A", on = false }, standby, NOW)
T.eq("not refused", refusal, nil)
local loads = Controls.loads(standby)
T.truthy("the record lists loads", #loads > 0)
T.eq(
  "POST its definition's set_value",
  request.method .. " " .. request.path,
  "POST /devices/58001/peripherals/" .. loads[1].id .. "/set_value"
)
T.eq("with the value", request.body, { value = false })
request = Controls.request({ action = "load", load = "HVAC A", on = true }, standby, NOW)
T.eq("on is true", request.body, { value = true })
_, refusal = Controls.request({ action = "load", load = "Hot Tub", on = true }, standby, NOW)
T.eq("refuses a load it doesn't have", refusal, "The generator has no load named Hot Tub")
_, refusal = Controls.request({ action = "load", load = "HVAC A", on = true }, fixture("device-58002.json"), NOW)
T.eq("refuses without a load control module", refusal, "The generator has no load control module")
T.eq("which lists no loads", Controls.loads(fixture("device-58002.json")), {})
T.eq("hasLoadControl", Controls.hasLoadControl(standby), true)

T.finish()
