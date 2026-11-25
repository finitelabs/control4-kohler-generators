-- The Kohler Generator companion's commands: each sends the account its command, Set Load is
-- refused and offers no loads while Load Control is off, the account's answer shows in Driver
-- Status, and the first record chooses Load Control once, after which the integrator's choice holds.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_kohler_companion_controls.lua

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

local props = {}
local realUpdateProperty = C4.UpdateProperty
-- Director's Properties table takes the new value, which the shim's UpdateProperty leaves alone.
C4.UpdateProperty = function(self, name, value, ...)
  props[name] = value
  Properties[name] = value
  return realUpdateProperty(self, name, value, ...)
end

local sent = {}
local realSendToProxy = C4.SendToProxy
C4.SendToProxy = function(self, idBinding, command, tParams, ...)
  if command == constants.CMD.GENERATOR_COMMAND then
    sent[#sent + 1] = JSON:decode(tParams.JSON)
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
Properties["Log Level"] = "3 - Info"
Properties["Log Mode"] = "Off"
Properties["Auto Rename Driver"] = "On"
Properties["Load Control"] = "On"
package.preload["cloud-client-byte"] = function()
  return {}
end
require("lib.drivercentral").PRODUCT_ID = 999

local values = require("lib.values")
local persist = require("lib.persist")

dofile(DRIVER)
OnDriverInit()
ShimLateInit()

--- @param name string
--- @return boolean
local function exists(name)
  local v = values:getValue(name)
  return v ~= nil and not v.deleted
end

--- @param name string
local function record(name)
  RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", { JSON = fixture(name) })
end

--- The integrator picks a value in Composer.
--- @param value string
local function setLoadControl(value)
  Properties["Load Control"] = value
  OnPropertyChanged("Load Control")
end

T.section("a first record with no load control module turns Load Control off")
record("device-58002.json")
T.eq("Load Control", Properties["Load Control"], "Off")
T.eq("Set Load offers nothing", GCPL.Set_Load("Load"), {})

T.section("the integrator turns it on, and a later record keeps that")
setLoadControl("On")
record("device-58001.json")
T.eq("Load Control kept", Properties["Load Control"], "On")
T.eq("a variable per load", exists("Load HVAC A"), true)
T.eq("Set Load offers the loads", GCPL.Set_Load("Load")[1], "HVAC A")
T.eq("only for the Load parameter", GCPL.Set_Load("State"), {})

T.section("each command sends the account its command")
sent = {}
EC.Start_Exercise({ Mode = "Unloaded Full Speed" })
T.eq("Start Exercise", sent[1], { action = "start", mode = "Unloaded Full Speed" })
T.eq("Driver Status while it goes", props["Driver Status"], "Sending Start Exercise...")
EC.Stop_Exercise()
T.eq("Stop Exercise", sent[2], { action = "stop" })
EC.Set_Exercise_Schedule({
  Frequency = "Monthly",
  Day = "Friday",
  Time = "9:15 AM",
  Mode = "Unloaded",
  Minutes = "30",
})
T.eq(
  "Set Exercise Schedule",
  sent[3],
  { action = "schedule", frequency = "Monthly", day = "Friday", time = "9:15 AM", mode = "Unloaded", minutes = "30" }
)
EC.Set_Load({ Load = "HVAC A", State = "Off" })
T.eq("Set Load off", sent[4], { action = "load", load = "HVAC A", on = false })
EC.Set_Load({ Load = "HVAC B", State = "On" })
T.eq("Set Load on", sent[5], { action = "load", load = "HVAC B", on = true })
local status = props["Driver Status"]
EC.Refresh()
T.eq("Refresh", sent[6], { action = "refresh" })
T.eq("Refresh leaves Driver Status", props["Driver Status"], status)

T.section("the account's answer shows in Driver Status")
RFP.commandResult(constants.GENERATOR_BINDING, "commandResult", { ACTION = "start", OK = "true", MESSAGE = "Sent" })
T.eq("sent", props["Driver Status"], "Start Exercise sent")
RFP.commandResult(
  constants.GENERATOR_BINDING,
  "commandResult",
  { ACTION = "stop", OK = "false", MESSAGE = "No exercise is running" }
)
T.eq("refused", props["Driver Status"], "Stop Exercise not sent: No exercise is running")

T.section("Load Control off removes the loads")
setLoadControl("Off")
T.eq("the load variables go", exists("Load HVAC A") or exists("Load HVAC B"), false)
T.eq("Set Load offers nothing", GCPL.Set_Load("Load"), {})
sent = {}
EC.Set_Load({ Load = "HVAC A", State = "On" })
T.eq("Set Load sends nothing", sent, {})
T.eq("and says why", props["Driver Status"], "Load Control is off")
record("device-58001.json")
T.eq("a record with loads keeps it off", Properties["Load Control"], "Off")
T.eq("and adds no variable", exists("Load HVAC A"), false)

T.section("a load variable a restart restored goes while Load Control is off")
values:update("Load HVAC A", true, "BOOL")
record("device-58001.json")
T.eq("removed", exists("Load HVAC A"), false)

T.section("a first record with a load control module turns Load Control on")
persist:delete("LoadControlSet")
Properties["Load Control"] = "Off"
record("device-58001.json")
T.eq("Load Control", Properties["Load Control"], "On")
T.eq("with the load variables", exists("Load HVAC A"), true)

T.section("a tap runs nothing")
sent = {}
RFP.SELECT(5001)
T.eq("nothing sent", sent, {})

T.finish()
