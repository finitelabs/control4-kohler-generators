-- The Kohler Generator companion: the record the account hands it fills its properties and names
-- it, Generator Online and Generator Offline fire on real changes only, and a tap does nothing.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_kohler_companion.lua

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
C4.UpdateProperty = function(self, name, value, ...)
  props[name] = value
  return realUpdateProperty(self, name, value, ...)
end

local events = {}
local EVENT_NAMES = { "Generator Online", "Generator Offline" }
C4.FireEventByID = function(_, id)
  events[#events + 1] = EVENT_NAMES[id]
end

local asked = {}
local icons = {}
local realSendToProxy = C4.SendToProxy
C4.SendToProxy = function(self, idBinding, command, tParams, ...)
  if command == "ICON_CHANGED" then
    local callType = ...
    icons[#icons + 1] = idBinding .. " " .. tParams.icon .. " " .. tostring(callType)
  else
    asked[#asked + 1] = idBinding .. " " .. command
  end
  return realSendToProxy(self, idBinding, command, tParams, ...)
end

local renamed = {}
C4.RenameDevice = function(_, deviceId, name)
  renamed[#renamed + 1] = name
end

C4.GetDriverConfigInfo = function(_, key)
  return ({ minimum_os_version = "3.3.0", version = "20261125", model = "Kohler Generator" })[key]
end
C4.GetVersionInfo = function()
  return { version = "4.3.0" }
end
Properties["Auto Rename Driver"] = "On"
Properties["Load Control"] = "On"
Properties["Automatic Updates"] = "On"
Properties["Log Level"] = "3 - Info"
Properties["Log Mode"] = "Off"
package.preload["cloud-client-byte"] = function()
  return {}
end
require("lib.drivercentral").PRODUCT_ID = 999

dofile(DRIVER)
OnDriverInit()
ShimLateInit()

local function online()
  return require("lib.values"):getValue("Online").value
end

T.section("at start-up")
T.eq("asks the account for its record", asked, { constants.GENERATOR_BINDING .. " " .. constants.CMD.REFRESH_STATE })
T.eq("Online is false", online(), false)
T.eq("the icon is sent at start-up, as a notification", icons, { "5001 offline NOTIFY" })

T.section("the record fills the properties")
RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", { JSON = fixture("device-58001.json") })
T.eq("Generator Name", props["Generator Name"], "Demo Generator")
T.eq("Model", props["Model"], "20 KW")
T.eq("Serial Number", props["Serial Number"], "DEMO000001")
T.eq("Fuel Type", props["Fuel Type"], "Natural Gas")
T.eq("Dealer", props["Dealer"], "Example Power Co., (555) 555-0142")
T.eq("Driver Status", props["Driver Status"], "Online")
T.eq("renamed after the generator", renamed, { "Demo Generator" })
T.eq("Generator Online fires", events, { "Generator Online" })
T.eq("Online is NOTIFY", online(), true)

T.section("the same record again changes nothing")
RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", { JSON = fixture("device-58001.json") })
T.eq("no second rename", #renamed, 1)
T.eq("no second event", #events, 1)
T.eq("the icon changed once, to standby", icons, { "5001 offline NOTIFY", "5001 standby NOTIFY" })

T.section("the icon follows the generator")
icons = {}
RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", { JSON = fixture("state-outage.json") })
T.eq("an outage", icons, { "5001 utility_out NOTIFY" })
RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", { JSON = fixture("state-outage.json") })
T.eq("the same state sends nothing", #icons, 1)
RFP.updateFeeds(constants.GENERATOR_BINDING, "updateFeeds", {
  ALERTS = fixture("state-fault-alerts.json"),
  EVENTS = fixture("state-fault-events.json"),
})
T.eq("a fault alert", icons[#icons], "5001 fault NOTIFY")
RFP.updateFeeds(constants.GENERATOR_BINDING, "updateFeeds", {
  ALERTS = fixture("state-cleared-alerts.json"),
  EVENTS = fixture("state-cleared-events.json"),
})
T.eq("cleared, back to the outage", icons[#icons], "5001 utility_out NOTIFY")
RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", { JSON = fixture("device-58001.json") })
T.eq("back to standby", icons[#icons], "5001 standby NOTIFY")

T.section("a generator that stops reaching the cloud")
local offline = JSON:decode(fixture("device-58001.json"))
offline.device.isConnected = false
RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", { JSON = JSON:encode(offline) })
T.eq("not renamed", #renamed, 1)
T.eq("Driver Status", props["Driver Status"], "Generator offline")
T.eq("Generator Offline fires", events[#events], "Generator Offline")
T.eq("Online is false", online(), false)
T.eq("the icon goes offline", icons[#icons], "5001 offline NOTIFY")

T.section("an unreadable record is ignored")
local before = #events
RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", { JSON = "{" })
RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", { JSON = JSON:encode({ device = {} }) })
T.eq("Driver Status kept", props["Driver Status"], "Generator offline")
T.eq("no event", #events, before)

T.section("goOffline")
RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", { JSON = fixture("device-58001.json") })
RFP.goOffline(constants.GENERATOR_BINDING)
T.eq("Driver Status", props["Driver Status"], "Offline")
T.eq("Generator Offline fires", events[#events], "Generator Offline")

T.section("Auto Rename Driver off keeps the integrator's name")
Properties["Auto Rename Driver"] = "Off"
renamed = {}
local record = JSON:decode(fixture("device-58001.json"))
record.device.displayName = "Renamed"
RFP.updateGenerator(constants.GENERATOR_BINDING, "updateGenerator", { JSON = JSON:encode(record) })
T.eq("Generator Name follows", props["Generator Name"], "Renamed")
T.eq("the driver is not renamed", renamed, {})

T.section("a tap runs nothing")
asked = {}
RFP.SELECT(5001)
T.eq("nothing sent", asked, {})

T.finish()
