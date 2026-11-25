-- The generator page's state and its link with the page (src/kohler/page.lua), and the Kohler
-- Generator driver's side of the page: hello and ping get the state, a page command runs the same
-- command programming runs and its answer comes back to the page, and opening the page, a ping or a
-- tap on the icon sends no command.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_kohler_page.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local DRIVER = root .. "/drivers/kohler_generator/driver.lua"

local JSON = require("JSON")
local constants = require("constants")
local Generator = require("kohler.generator")
local Page = require("kohler.page")

local FIXTURES = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/kohler/"

--- @param name string
--- @return table
local function fixture(name)
  local file = assert(io.open(FIXTURES .. name, "r"))
  local body = file:read("*a")
  file:close()
  return JSON:decode(body)
end

local NOW = Generator.time("2026-09-26T14:00:00Z")

--- @param record table
--- @param extra table|nil
--- @return table
local function stateOf(record, extra)
  local ctx = {
    identity = Generator.identity(record),
    record = record,
    alerts = {},
    events = {},
    now = NOW,
    scale = "F",
    loadControl = true,
  }
  for k, v in pairs(extra or {}) do
    ctx[k] = v
  end
  return Page.state(ctx)
end

--- @param state table
--- @return table<string, any>
local function readingsOf(state)
  local out = {}
  for _, r in ipairs(state.readings) do
    out[r.key] = r.value
  end
  return out
end

-- ─── The state ─────────────────────────────────────────────────────────────

T.section("a generator at rest: ready to start, nothing to stop")
local standby = stateOf(fixture("device-58001.json"))
T.eq("connected", standby.connected, true)
T.eq("name", standby.name, "Demo Generator")
T.eq("on utility power", standby.top.onGeneratorPower, false)
T.eq("not running", standby.top.running, false)
T.eq("no fault", standby.top.fault, false)
T.eq("reported", standby.top.reported, Generator.time("2026-09-21T13:13:20.0000000+00:00"))
T.eq("Start allowed", standby.exercise.start, nil)
T.eq("Stop refused", standby.exercise.stop, "No exercise is running")
T.eq("next exercise", standby.exercise.nextAt, Generator.time("2026-09-26T15:00:00Z"))
T.eq("last ran", standby.exercise.lastAt, Generator.time("2026-09-19T15:00:00+00:00"))
T.eq("schedule sheet starts from the schedule", standby.exercise.sheet.frequency, "Weekly")
T.eq("its mode", standby.exercise.sheet.mode, "Unloaded")
T.eq("its length", standby.exercise.sheet.minutes, 20)
T.eq("six loads", #standby.loads.items, 6)
T.eq("the first", standby.loads.items[1], { name = "HVAC A", on = false })
T.eq("dealer and serial in service", standby.service.serial ~= nil and standby.service.serial ~= "", true)

T.section("only the readings the controller reports are listed")
local liquid = stateOf(fixture("device-58002.json"))
T.eq("coolant on the liquid-cooled unit", readingsOf(liquid).coolantTemperature, 91.4)
T.eq("no coolant on the air-cooled one", readingsOf(standby).coolantTemperature, nil)
T.eq("oil pressure as a reading", readingsOf(standby).oilPressure, true)
T.eq(
  "in Celsius when the project is",
  readingsOf(stateOf(fixture("device-58002.json"), { scale = "C" })).coolantTemperature,
  33
)

T.section("an outage: on generator power, Start refused")
local outage = stateOf(fixture("state-outage.json"))
T.eq("on generator power", outage.top.onGeneratorPower, true)
T.eq("running", outage.top.running, true)
T.eq("Start refused with the reason", outage.exercise.start, "Utility power is out")

T.section("an exercise: Stop allowed, Start refused")
local exercise = stateOf(fixture("state-exercise.json"))
T.eq("exercising", exercise.exercise.running, true)
T.eq("Stop allowed", exercise.exercise.stop, nil)
T.eq("Start refused", exercise.exercise.start, "The generator is already running")

T.section("a fault lists its alert and the log, newest first")
local fault = stateOf(
  fixture("state-fault.json"),
  { alerts = fixture("state-fault-alerts.json"), events = fixture("state-fault-events.json") }
)
T.eq("fault", fault.top.fault, true)
T.eq("one alert", #fault.alerts, 1)
T.eq("named by its event", fault.alerts[1].name, "Overcrank")
T.eq("with its level", fault.alerts[1].level, "Shutdown")
T.eq("history newest first", fault.history[1].id >= (fault.history[#fault.history].id or 0), true)
local many = {}
for i = 1, 30 do
  many[i] = { id = i, event = "Engine Started", level = "Status", timestamp = "2026-09-21T14:13:20+00:00" }
end
T.eq("history keeps the newest twenty", #stateOf(fixture("device-58001.json"), { events = many }).history, 20)

T.section("an offline generator: not connected, with when it was last heard from")
local offline = stateOf(fixture("device-58004.json"))
T.eq("not connected", offline.connected, false)
T.eq("because it is offline", offline.reason, "offline")
T.eq("Start refused", offline.exercise.start, "The generator is offline")

T.section("loads only with Load Control on and a load control module")
T.eq("Load Control off", stateOf(fixture("device-58001.json"), { loadControl = false }).loads, nil)
T.eq("no module", liquid.loads, nil)

T.section("before the first record, or signed out")
T.eq(
  "waiting",
  Page.state({ identity = Generator.identity(fixture("device-58001.json")), now = NOW, scale = "F" }).reason,
  "waiting"
)
T.eq("signed out", Page.state({ now = NOW, scale = "F" }).reason, "account")

-- ─── The link ──────────────────────────────────────────────────────────────

T.section("the link answers a hello with the state, marked for that page")
local clock = 1000
local pushed = {}
local current = { a = 1 }
local link = Page.link({
  device = 77,
  boot = "boot-1",
  now = function()
    return clock
  end,
  encode = function(v)
    return JSON:encode(v)
  end,
  send = function(command, params)
    pushed[#pushed + 1] = { command = command, message = JSON:decode(params.json) }
  end,
  getState = function()
    return current
  end,
})
link:publish()
T.eq("nothing before a page opens", #pushed, 0)
link:hello({ page = "page-9" })
T.eq("one push", #pushed, 1)
T.eq("as the state command", pushed[1].command, "KG_PAGE_STATE")
T.eq("for that page", pushed[1].message.page, "page-9")
T.eq("from this device", pushed[1].message.device, "77")
T.eq("with the state", pushed[1].message.state, { a = 1 })

T.section("a change goes to open pages; the same state doesn't")
link:publish()
T.eq("unchanged: nothing", #pushed, 1)
current = { a = 2 }
link:publish()
T.eq("changed: pushed", #pushed, 2)
T.eq("raised revision", pushed[2].message.rev, 2)
T.eq("for every page", pushed[2].message.page, nil)

T.section("a ping behind, or from before a reload, gets the state again")
link:ping({ boot = "boot-1", rev = 2 })
T.eq("current: nothing", #pushed, 2)
link:ping({ boot = "boot-1", rev = 1 })
T.eq("behind: pushed", #pushed, 3)
link:ping({ boot = "boot-0", rev = 9 })
T.eq("another load: pushed", #pushed, 4)

T.section("no page heard from for three pings: changes wait")
clock = clock + 46
current = { a = 3 }
link:publish()
T.eq("nothing", #pushed, 4)
link:ping({ boot = "boot-1", rev = 2 })
T.eq("a page back gets it", pushed[5].message.state, { a = 3 })

-- ─── The driver ────────────────────────────────────────────────────────────

local toUI = {}
C4.SendDataToUI = function(_, command, params)
  toUI[#toUI + 1] = { command = command, message = JSON:decode(params.json) }
end
local sent = {}
local realSendToProxy = C4.SendToProxy
C4.SendToProxy = function(self, idBinding, command, tParams, ...)
  if command == constants.CMD.GENERATOR_COMMAND then
    sent[#sent + 1] = JSON:decode(tParams.JSON)
  end
  return realSendToProxy(self, idBinding, command, tParams, ...)
end
local realUpdateProperty = C4.UpdateProperty
C4.UpdateProperty = function(self, name, value, ...)
  Properties[name] = value
  return realUpdateProperty(self, name, value, ...)
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

dofile(DRIVER)
OnDriverInit()
ShimLateInit()

local function record(name)
  RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", { JSON = JSON:encode(fixture(name)) })
end

T.section("a page that opens gets the state, and nothing runs")
sent = {}
record("device-58001.json")
T.eq("no page open: nothing pushed", #toUI, 0)
ExecuteCommand("KG_PAGE_HELLO", { page = "p1" })
T.eq("pushed", #toUI, 1)
T.eq("for the page", toUI[1].message.page, "p1")
T.eq("the generator", toUI[1].message.state.name, "Demo Generator")
ExecuteCommand("KG_PAGE_PING", { boot = toUI[1].message.boot, rev = toUI[1].message.rev })
RFP.SELECT(5001)
T.eq("no command sent", sent, {})

T.section("a record that changes the page reaches it")
record("state-outage.json")
T.eq("pushed", #toUI, 2)
T.eq("on generator power", toUI[2].message.state.top.onGeneratorPower, true)

T.section("Start from the page runs Start Exercise, and its answer comes back to the page")
record("device-58001.json")
sent = {}
ExecuteCommand("KG_PAGE_COMMAND", { action = "start", mode = "Unloaded", request = "r1" })
T.eq("the same command programming sends, with the page's request", sent[1], {
  action = "start",
  mode = "Unloaded",
  request = "r1",
})
RFP.commandResult(
  constants.GENERATOR_BINDING,
  "commandResult",
  { ACTION = "start", OK = "true", MESSAGE = "Sent", REQUEST = "r1" }
)
local last = toUI[#toUI].message.state.lastCommand
T.eq("answered", last, { request = "r1", action = "start", ok = true, message = "Sent" })

T.section("a programming command's answer, while the page's is on its way, is not the page's")
sent = {}
ExecuteCommand("KG_PAGE_COMMAND", { action = "stop", request = "p1-2" })
EC.Stop_Exercise({})
T.eq("programming's carries no request", sent[2], { action = "stop" })
RFP.commandResult(
  constants.GENERATOR_BINDING,
  "commandResult",
  { ACTION = "stop", OK = "false", MESSAGE = "Another command is still on its way" }
)
T.eq("its answer names no request", toUI[#toUI].message.state.lastCommand.request, nil)
RFP.commandResult(
  constants.GENERATOR_BINDING,
  "commandResult",
  { ACTION = "stop", OK = "true", MESSAGE = "Sent", REQUEST = "p1-2" }
)
T.eq("the page's answer names its request", toUI[#toUI].message.state.lastCommand.request, "p1-2")

T.section("each page command maps to its command")
sent = {}
ExecuteCommand("KG_PAGE_COMMAND", { action = "stop", request = "r2" })
ExecuteCommand("KG_PAGE_COMMAND", {
  action = "schedule",
  frequency = "Monthly",
  day = "Friday",
  time = "09:15",
  mode = "Unloaded",
  minutes = "30",
  request = "r3",
})
ExecuteCommand("KG_PAGE_COMMAND", { action = "load", load = "HVAC A", state = "On", request = "r4" })
ExecuteCommand("KG_PAGE_COMMAND", { action = "refresh" })
T.eq("stop", sent[1], { action = "stop", request = "r2" })
T.eq("schedule", sent[2], {
  action = "schedule",
  frequency = "Monthly",
  day = "Friday",
  time = "09:15",
  mode = "Unloaded",
  minutes = "30",
  request = "r3",
})
T.eq("load", sent[3], { action = "load", load = "HVAC A", on = true, request = "r4" })
T.eq("Try again reads the generator", sent[4], { action = "refresh" })

T.section("a command the page doesn't know runs nothing")
sent = {}
ExecuteCommand("KG_PAGE_COMMAND", { action = "reset", request = "r5" })
T.eq("nothing sent", sent, {})

T.section("a load state other than On or Off runs nothing")
sent = {}
ExecuteCommand("KG_PAGE_COMMAND", { action = "load", load = "HVAC A", state = "Off", request = "r7" })
ExecuteCommand("KG_PAGE_COMMAND", { action = "load", load = "HVAC A", on = true, request = "r8" })
ExecuteCommand("KG_PAGE_COMMAND", { action = "load", load = "HVAC A", state = "true", request = "r9" })
T.eq("only Off is sent", sent, { { action = "load", load = "HVAC A", on = false, request = "r7" } })

T.section("Set Load from the page while Load Control is off: refused on the page")
Properties["Load Control"] = "Off"
OnPropertyChanged("Load Control")
sent = {}
ExecuteCommand("KG_PAGE_COMMAND", { action = "load", load = "HVAC A", state = "On", request = "r6" })
T.eq("nothing sent", sent, {})
T.eq(
  "the page is told why",
  toUI[#toUI].message.state.lastCommand,
  { request = "r6", action = "load", ok = false, message = "Load Control is off" }
)
T.eq("and shows no loads", toUI[#toUI].message.state.loads, nil)

T.section("signed out: the page says so")
RFP.goOffline(constants.GENERATOR_BINDING)
T.eq("not connected", toUI[#toUI].message.state.connected, false)
T.eq("because of the account", toUI[#toUI].message.state.reason, "account")

T.finish()
