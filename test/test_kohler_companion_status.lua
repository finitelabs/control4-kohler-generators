-- The Kohler Generator companion's status: the record and the alerts and event log the account
-- hands it become variables, conditionals, contact outputs and events, which fire on a change,
-- including one across a restart.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_kohler_companion_status.lua

local T = require("testlib")

require("c4_shim")

local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local DRIVER = root .. "/drivers/kohler_generator/driver.lua"

local JSON = require("JSON")
local constants = require("constants")

local FIXTURES = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/kohler/"

--- @param name string
--- @return string
local function fixture(name)
  local file = assert(io.open(FIXTURES .. name, "r"))
  local body = file:read("*a")
  file:close()
  return body
end

--- The mock's fixed clock, when the fixtures were taken.
local NOW = 1790000000
local realTime = os.time
local now = NOW
--- @diagnostic disable-next-line: duplicate-set-field
os.time = function(t)
  if t ~= nil then
    return realTime(t)
  end
  return now
end

local props = {}
local realUpdateProperty = C4.UpdateProperty
C4.UpdateProperty = function(self, name, value, ...)
  props[name] = value
  return realUpdateProperty(self, name, value, ...)
end

local EVENT_NAMES = {
  "Generator Online",
  "Generator Offline",
  "Utility Power Lost",
  "Utility Power Restored",
  "Engine Started",
  "Engine Stopped",
  "Exercise Started",
  "Exercise Ended",
  "Fault",
  "Warning",
  "Alerts Cleared",
  "Switch Not In Auto",
  "Switch Back In Auto",
  "Maintenance Due",
  "Low Battery",
}
local events = {}
C4.FireEventByID = function(_, id)
  events[#events + 1] = EVENT_NAMES[id]
end

local told = {}
local icons = {}
local realSendToProxy = C4.SendToProxy
C4.SendToProxy = function(self, idBinding, command, tParams, ...)
  if command == "ICON_CHANGED" then
    icons[#icons + 1] = tParams.icon
  end
  if idBinding >= 1 and idBinding <= 4 then
    told[#told + 1] = idBinding .. " " .. command
  end
  return realSendToProxy(self, idBinding, command, tParams, ...)
end

C4.RenameDevice = function() end
C4.GetDriverConfigInfo = function(_, key)
  return ({ minimum_os_version = "3.3.0", version = "20261125", model = "Kohler Generator" })[key]
end
C4.GetVersionInfo = function()
  return { version = "4.3.0" }
end
local xmlFile = assert(io.open(root .. "/drivers/kohler_generator/driver.xml", "rb"))
require("c4_fixtures").seedProperties(xmlFile:read("*a"))
xmlFile:close()
Properties["Auto Rename Driver"] = "On"
Properties["Load Control"] = "On"
Properties["Automatic Updates"] = "On"
Properties["Log Level"] = "3 - Info"
Properties["Log Mode"] = "Off"
package.preload["cloud-client-byte"] = function()
  return {}
end
require("lib.drivercentral").PRODUCT_ID = 999

local function start()
  dofile(DRIVER)
  OnDriverInit()
  ShimLateInit()
end

--- @param name string
--- @return any
local function var(name)
  local v = require("lib.values"):getValue(name)
  return v and v.value
end

--- Hand over a state's record, alerts and events.
--- @param name string
--- @param feeds? boolean Also hand over its alerts and event log.
local function handOver(name, feeds)
  RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", { JSON = fixture("state-" .. name .. ".json") })
  if feeds then
    RFP.updateFeeds(constants.GENERATOR_BINDING, "updateFeeds", {
      ALERTS = fixture("state-" .. name .. "-alerts.json"),
      EVENTS = fixture("state-" .. name .. "-events.json"),
    })
  end
end

--- Whether a conditional tests true.
--- @param name string
--- @param value string
--- @return boolean
local function test(name, value)
  return TC[name]("", { VALUE = value, LOGIC = "EQUAL" })
end

start()

T.section("every variable exists before the first record")
T.eq("Status", var("Status"), "")
T.eq("Running", var("Running"), false)
T.eq("Active Alerts", var("Active Alerts"), 0)
T.eq("a reading starts with no value", var("Utility Voltage"), nil)
T.truthy("as a variable", Variables["Utility Voltage"] ~= nil)
T.eq("no contact told yet", told, {})

T.section("the first record sets everything and fires only Generator Online")
handOver("standby", true)
T.eq("events", events, { "Generator Online" })
T.eq("Status", var("Status"), "Ready To Run")
T.eq("Engine State", var("Engine State"), "Standby")
T.eq("Power Source", var("Power Source"), "Utility")
T.eq("Utility Voltage", var("Utility Voltage"), 241.6)
T.eq("Coolant Temperature has no value: this controller doesn't report it", var("Coolant Temperature"), nil)
T.eq("In Auto", var("In Auto"), true)
T.eq("Load HVAC A", var("Load HVAC A"), false)
T.eq("Load A keeps its name", var("Load A"), false)
T.truthy("Exercise Schedule", (props["Exercise Schedule"] or ""):find("^Weekly") ~= nil, props["Exercise Schedule"])
T.truthy("Next Maintenance shows as a property too", (props["Next Maintenance"] or "") ~= "", props["Next Maintenance"])
T.eq("contacts told their state without firing", told, {
  "1 STATE_OPENED",
  "2 STATE_OPENED",
  "3 STATE_OPENED",
  "4 STATE_OPENED",
})
T.eq("Is In Auto", test("GENERATOR_IN_AUTO", "In Auto"), true)
T.eq("Is Running", test("GENERATOR_RUNNING", "Running"), false)
T.eq("Is Running, NOT_EQUAL", TC.GENERATOR_RUNNING("", { VALUE = "Running", LOGIC = "NOT_EQUAL" }), true)

T.section("an outage")
events, told = {}, {}
handOver("outage", true)
T.eq("events", events, { "Utility Power Lost", "Engine Started" })
T.eq("On Generator Power", var("On Generator Power"), true)
T.eq("Running", var("Running"), true)
T.eq("the contacts that changed", told, { "1 CLOSED", "2 CLOSED" })
T.eq("Is On Generator Power", test("ON_GENERATOR_POWER", "Generator Power"), true)

T.section("the same record again fires nothing")
events, told = {}, {}
handOver("outage", true)
T.eq("events", events, {})
T.eq("contacts", told, {})

T.section("power restored")
handOver("restored", true)
T.eq("events", events, { "Utility Power Restored", "Engine Stopped" })
T.eq("contacts", told, { "1 OPENED", "2 OPENED" })

T.section("a fault")
events, told = {}, {}
handOver("fault", true)
T.eq("Fault fires once, from the event log", events, { "Fault" })
T.eq("Fault", var("Fault"), true)
T.eq("Active Alerts", var("Active Alerts"), 1)
T.eq("Last Alert", var("Last Alert"), "Over Crank")
T.eq("Has Fault", test("GENERATOR_FAULT", "Faulted"), true)
T.eq("the Fault contact closes", told, { "3 CLOSED" })

T.section("the fault cleared")
events, told = {}, {}
handOver("standby", true)
T.eq("Alerts Cleared fires", events, { "Alerts Cleared" })
T.eq("Fault", var("Fault"), false)
T.eq("the Fault contact opens", told, { "3 OPENED" })

T.section("the switch off Auto")
events, told = {}, {}
handOver("switch-off")
T.eq("events", events, { "Switch Not In Auto" })
T.eq("the Not In Auto contact closes", told, { "4 CLOSED" })
events = {}
handOver("standby")
T.eq("and back", events, { "Switch Back In Auto" })

T.section("an exercise")
events = {}
handOver("exercise")
T.eq("events", events, { "Exercise Started", "Engine Started" })
T.eq("Is Exercising", test("GENERATOR_EXERCISING", "Exercising"), true)
events = {}
handOver("standby")
T.eq("and its end", events, { "Engine Stopped", "Exercise Ended" })

T.section("a low battery")
events = {}
handOver("low-battery", true)
T.eq("Warning and Low Battery fire", events, { "Warning", "Low Battery" })
T.eq("Battery Voltage", var("Battery Voltage"), 11.6)

T.section("maintenance falls due")
local record = JSON:decode(fixture("state-standby.json"))
record.device.nextMaintenanceTimestamp = "2026-09-21T00:00:00Z"
events = {}
RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", { JSON = JSON:encode(record) })
T.eq("Maintenance Due fires", events, { "Maintenance Due" })
T.eq("Maintenance Due", var("Maintenance Due"), true)
T.eq("Maintenance Due conditional", test("MAINTENANCE_DUE", "Due"), true)

T.section("a temperature in the project's Celsius scale")
ShimSetTemperatureScale("CELSIUS")
handOver("standby")
T.eq("Controller Temperature", var("Controller Temperature"), 23.5)
ShimResetTemperatureScale()

T.section("an outage that starts while the driver is stopped fires once on its first read")
handOver("standby", true)
ShimRestartDirector()
events, told = {}, {}
start()
handOver("outage", true)
T.eq("the transitions across the restart", events, { "Utility Power Lost", "Engine Started" })
T.eq("the contacts that changed, and the rest without firing", told, {
  "1 CLOSED",
  "2 CLOSED",
  "3 STATE_OPENED",
  "4 STATE_OPENED",
})

T.section("a restart in the middle of an outage fires nothing on its first read")
ShimRestartDirector()
events, told = {}, {}
start()
handOver("outage", true)
T.eq("no transitions", events, {})
T.eq("contacts told their state without firing", told, {
  "1 STATE_CLOSED",
  "2 STATE_CLOSED",
  "3 STATE_OPENED",
  "4 STATE_OPENED",
})
events = {}
handOver("restored", true)
T.eq("the next change fires", events, { "Utility Power Restored", "Engine Stopped" })

T.section("a restart while the generator is online shows it offline until the first record")
ShimRestartDirector()
icons = {}
start()
T.eq("Online is kept", var("Online"), true)
T.eq("the icon at start-up", icons, { "offline" })
handOver("outage", true)
T.eq("then the record's", icons, { "offline", "utility_out" })

T.section("alerts that clear while the driver is stopped fire Alerts Cleared once")
handOver("fault", true)
ShimRestartDirector()
events = {}
start()
handOver("fault", true)
T.eq("still active: nothing", events, {})
ShimRestartDirector()
events = {}
start()
handOver("standby", true)
T.eq("cleared across the restart", events, { "Alerts Cleared" })

T.section("an event logged while the driver was stopped")
ShimRestartDirector()
events = {}
start()
local log = JSON:decode(fixture("state-warning-events.json"))
local newest = log[1]
newest.id = newest.id + 1000
newest.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ", NOW - 60)
RFP.updateFeeds(constants.GENERATOR_BINDING, "updateFeeds", { ALERTS = "[]", EVENTS = JSON:encode(log) })
T.eq("fires when it is recent", events, { "Warning" })

ShimRestartDirector()
events = {}
start()
newest.id = newest.id + 1
newest.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ", NOW - 3600)
RFP.updateFeeds(constants.GENERATOR_BINDING, "updateFeeds", { ALERTS = "[]", EVENTS = JSON:encode(log) })
T.eq("not when it is an hour old", events, {})
newest.id = newest.id + 1
newest.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ", NOW - 3600)
RFP.updateFeeds(constants.GENERATOR_BINDING, "updateFeeds", { ALERTS = "[]", EVENTS = JSON:encode(log) })
T.eq("after the first read, a new one fires whatever its age", events, { "Warning" })
events = {}
RFP.updateFeeds(constants.GENERATOR_BINDING, "updateFeeds", { ALERTS = "[]", EVENTS = JSON:encode(log) })
T.eq("and never twice", events, {})

T.section("a contact that binds is told its state")
told = {}
OBC[2](2, "CONTACT_SENSOR", true)
T.eq("nothing before the first record", told, {})
handOver("outage")
told = {}
OBC[2](2, "CONTACT_SENSOR", true)
T.eq("as STATE_, which fires nothing", told, { "2 STATE_CLOSED" })

T.section("a contact that asks for its state is told it")
told = {}
ReceivedFromProxy(2, "GET_STATE", {})
T.eq("as STATE_, which fires nothing", told, { "2 STATE_CLOSED" })

T.section("a reading the generator stops reporting loses its value")
handOver("standby")
T.eq("Battery Voltage", var("Battery Voltage"), 13.6)
RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", {
  JSON = (fixture("state-standby.json"):gsub('"batteryVoltageV": *[%d.]+', '"batteryVoltageV": null')),
})
T.eq("no value", var("Battery Voltage"), nil)

T.section("an unreadable feed is ignored")
events = {}
RFP.updateFeeds(constants.GENERATOR_BINDING, "updateFeeds", { ALERTS = "{", EVENTS = "[]" })
T.eq("no event", events, {})

os.time = realTime
T.finish()
