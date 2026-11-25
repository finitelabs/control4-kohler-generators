-- The Kohler Generators account driver against a scripted KOHLER cloud answering with the mock's
-- replies: sign-in from the Email and Password properties and its Login Status, Account Connected
-- and Account Disconnected on real changes only, a binding and a record handed off per generator,
-- Add Generators, a generator that leaves the account and its companion marked, a 429 that pauses the poll, and a wrong
-- password that stops.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_kohler_account.lua

local T = require("testlib")

require("c4_shim")

local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local DRIVER = root .. "/drivers/kohler_generators/driver.lua"

local constants = require("constants")
constants.CLIENT_ID = "test-client"
constants.CLIENT_SECRET = "test-secret"
constants.API_KEY = "test-api-key"

local JSON = require("JSON")

local FIXTURES = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/kohler/"

--- @param name string
--- @return table
local function fixture(name)
  local file = assert(io.open(FIXTURES .. name, "r"))
  local body = file:read("*a")
  file:close()
  return JSON:decode(body)
end

require("drivers-common-public.global.lib")
require("drivers-common-public.global.url")
require("drivers-common-public.global.timer")

local now = 1790000000
os.time = function(t)
  return t and 0 or now
end

-- ─── Scripted cloud ────────────────────────────────────────────────────────

local homes = fixture("demo-homes.json")
local requests = {}
--- The answers the next token requests get, in order; then a new token.
local tokenAnswers = {}
--- The answers the next API calls get, in order; then the fixtures.
local apiAnswers = {}
local issued = 0
--- When set, the answer every API call gets.
local apiAlways = nil
--- When set, every answer waits in it, to be released by calling it.
--- @type function[]|nil
local held = nil

urlDo = function(method, url, data, _headers, callback, context)
  requests[#requests + 1] = { method = method, url = url, data = data }
  -- A runaway loop of requests is left unanswered, so it ends and its count shows.
  if #requests > 100 then
    return
  end
  local code, body, responseHeaders = 404, { message = "Not Found" }, {}
  if url:sub(-#constants.TOKEN_PATH) == constants.TOKEN_PATH then
    local answer = table.remove(tokenAnswers, 1)
    if answer then
      code, body, responseHeaders = answer[1], answer[2], answer[3] or {}
    else
      issued = issued + 1
      code, body = 200, { access_token = "access-" .. issued, refresh_token = "refresh-" .. issued, expires_in = 3600 }
    end
  else
    local answer = apiAlways or table.remove(apiAnswers, 1)
    if answer then
      code, body, responseHeaders = answer[1], answer[2], answer[3] or {}
    elseif url:find("/homeowner/homes$") then
      code, body = 200, homes
    else
      local id = url:match("/devices/(%d+)%?")
      if id then
        code, body = 200, fixture("device-" .. id .. ".json")
      end
    end
  end
  if held then
    held[#held + 1] = function()
      callback(nil, code, responseHeaders, body, context, url)
    end
    return
  end
  callback(nil, code, responseHeaders, body, context, url)
end

--- @param pattern string
--- @return integer
local function sent(pattern)
  local n = 0
  for _, r in ipairs(requests) do
    if r.url:find(pattern) then
      n = n + 1
    end
  end
  return n
end

-- ─── What the driver tells Control4 ─────────────────────────────────────────

local props = {}
local realUpdateProperty = C4.UpdateProperty
C4.UpdateProperty = function(self, name, value, ...)
  props[name] = value
  return realUpdateProperty(self, name, value, ...)
end

local events = {}
local EVENT_NAMES = { "Account Connected", "Account Disconnected" }
C4.FireEventByID = function(_, id)
  events[#events + 1] = EVENT_NAMES[id]
end

local toProxy = {}
local realSendToProxy = C4.SendToProxy
C4.SendToProxy = function(self, idBinding, command, tParams, ...)
  toProxy[#toProxy + 1] = { binding = idBinding, command = command, params = tParams }
  return realSendToProxy(self, idBinding, command, tParams, ...)
end

--- @param command string
--- @return table<integer, table> params by binding
local function proxySends(command)
  local out = {}
  for _, s in ipairs(toProxy) do
    if s.command == command then
      out[s.binding] = s.params
    end
  end
  return out
end

-- ─── A project ─────────────────────────────────────────────────────────────

local ME = C4:GetDeviceID()
local UTILITY, GARAGE = 10, 11
ShimSetDevices({
  [UTILITY] = { deviceName = "Utility", driverFileName = "roomdevice.c4i" },
  [GARAGE] = { deviceName = "Garage", driverFileName = "roomdevice.c4i" },
})
ShimSetRoom(UTILITY)
ShimSetDriverFiles({ "kohler_generator.c4z" })

C4.GetDriverConfigInfo = function(_, key)
  return ({ minimum_os_version = "3.3.0", version = "20261125", model = "Kohler Generators" })[key]
end
C4.GetVersionInfo = function()
  return { version = "4.3.0" }
end
Properties["Email"] = ""
Properties["Password"] = ""
Properties["Poll Interval"] = "60 seconds"
Properties["Automatic Updates"] = "Off"
Properties["Log Level"] = "3 - Info"
Properties["Log Mode"] = "Off"
Properties["Cloud Monitoring"] = "Enabled"
package.preload["cloud-client-byte"] = function()
  return {}
end
-- A product id keeps the license gate from stopping the account at its load.
require("lib.drivercentral").PRODUCT_ID = 999

local bindings = require("lib.bindings")

--- @param id integer
--- @return integer|nil
local function bindingOf(id)
  local binding = bindings:getDynamicBinding(constants.BINDING_NAMESPACE, tostring(id))
  return binding and binding.bindingId
end

--- @param name string
--- @param value string
local function setProperty(name, value)
  Properties[name] = value
  OnPropertyChanged(name)
end

dofile(DRIVER)
OnDriverInit()
ShimLateInit()

T.section("with no email or password")
T.eq("Login Status asks for them", props["Login Status"], "Enter email and password")
T.eq("nothing is sent", #requests, 0)
T.eq("Account Connected is false", require("lib.values"):getValue("Account Connected").value, false)
T.eq("no event", events, {})

T.section("entering them signs in and reads the account")
setProperty("Email", "demo@example.com")
T.eq("an email alone sends nothing", #requests, 0)
setProperty("Password", "demo-password")
T.eq("one sign-in", sent(constants.TOKEN_PATH .. "$"), 1)
T.eq("Login Status", props["Login Status"], "Logged In")
T.eq("Driver Status", props["Driver Status"], "Connected (3 generators)")
T.eq("Account Connected fires", events, { "Account Connected" })
T.eq("Account Connected is true", require("lib.values"):getValue("Account Connected").value, true)
T.eq("each generator's record is read, from its host", sent("/devices/%d+%?sourceDeviceHost=Oncue$"), 3)
T.truthy("a binding for 58001", bindingOf(58001))
T.truthy("for 58002", bindingOf(58002))
T.truthy("for 58003", bindingOf(58003))

T.section("Add Generators gives every generator a companion")
--- Runs Add Generators to its end, answering every add and firing every timer as it goes.
local function addGenerators()
  EC.Add_Generators()
  for _ = 1, 20 do
    if ShimPendingAdds() == 0 and not require("lib.companions").running then
      break
    end
    ShimAnswerAdds()
    ShimFireTimers()
  end
end

toProxy = {}
addGenerators()
local companionOf = {}
for _, id in ipairs({ 58001, 58002, 58003 }) do
  companionOf[id] = next(C4:GetBoundConsumerDevices(ME, bindingOf(id)) or {})
end
T.truthy("58001 has one", companionOf[58001])
T.truthy("58002 has one", companionOf[58002])
T.truthy("58003 has one", companionOf[58003])
T.eq("named after its generator", C4:GetDeviceDisplayName(companionOf[58001] + 1), "Demo Generator")
T.eq(
  "in this driver's room",
  C4:GetDevices({ DeviceIds = tostring(companionOf[58002]) })[companionOf[58002]].roomId,
  UTILITY
)
local handed = proxySends(constants.CMD.UPDATE_GENERATOR)
T.truthy("each is handed its record", handed[bindingOf(58003)])
T.eq("the whole record", JSON:decode(handed[bindingOf(58003)].JSON).device.id, 58003)
T.eq("Driver Status when done", props["Driver Status"], "Connected (3 generators)")

T.section("a companion that starts up is handed its record")
toProxy = {}
RFP.REFRESH_STATE(bindingOf(58001), "REFRESH_STATE", {})
T.truthy("updateGenerator", proxySends(constants.CMD.UPDATE_GENERATOR)[bindingOf(58001)])

T.section("a generator that leaves the account goes offline")
toProxy = {}
local cabin = table.remove(homes[2].devices)
EC.Refresh_Generators()
T.truthy("goOffline to its companion", proxySends(constants.CMD.GO_OFFLINE)[bindingOf(58003)])
T.eq("Driver Status counts the rest", props["Driver Status"], "Connected (2 generators)")
T.truthy("its binding stays, so its programming does", bindingOf(58003))
local cabinProxy = companionOf[58003] + 1
addGenerators()
T.eq(
  "Add Generators marks its companion",
  C4:GetDeviceDisplayName(cabinProxy),
  "Demo Cabin Generator - REMOVED FROM KOHLER"
)
T.eq("and leaves the others' names", C4:GetDeviceDisplayName(companionOf[58001] + 1), "Demo Generator")
addGenerators()
T.eq("only once", C4:GetDeviceDisplayName(cabinProxy), "Demo Cabin Generator - REMOVED FROM KOHLER")
table.insert(homes[2].devices, cabin)
EC.Refresh_Generators()
T.eq("it comes back", props["Driver Status"], "Connected (3 generators)")
addGenerators()
T.eq("the next Add Generators restores its name", C4:GetDeviceDisplayName(cabinProxy), "Demo Cabin Generator")
T.eq("and adds no companion", TableLength(C4:GetDevicesByC4iName("kohler_generator.c4z") or {}), 3)

T.section("a 429 pauses the poll for the wait it names")
apiAnswers = { { 429, { message = "Too Many Requests" }, { ["Retry-After"] = "120" } } }
EC.Refresh_Generators()
T.contains("Driver Status says so", props["Driver Status"], "Rate limited")
requests = {}
ShimFireTimers()
T.eq("the poll sends nothing while paused", #requests, 0)
now = now + 121
ShimFireTimers()
T.eq("then reads again", sent("/homeowner/homes$"), 1)

T.section("an expired sign-in on a read signs in again")
requests = {}
apiAnswers = { { 401, { message = "Unauthorized" } } }
EC.Refresh_Generators()
T.eq("one new sign-in", sent(constants.TOKEN_PATH .. "$"), 1)
T.eq("still connected", props["Driver Status"], "Connected (3 generators)")
T.eq("no event", events, { "Account Connected" })

T.section("a wrong password stops and says so")
toProxy = {}
tokenAnswers = { { 400, { error = "invalid_grant", error_description = "The credentials provided were invalid." } } }
setProperty("Password", "wrong")
T.eq("Login Status", props["Login Status"], "Invalid email or password")
T.eq("Account Disconnected fires", events, { "Account Connected", "Account Disconnected" })
T.eq("Account Connected is false", require("lib.values"):getValue("Account Connected").value, false)
T.truthy("the generators go offline", proxySends(constants.CMD.GO_OFFLINE)[bindingOf(58001)])
requests = {}
ShimFireTimers()
T.eq("and nothing is tried again", #requests, 0)
toProxy = {}
RFP.REFRESH_STATE(bindingOf(58002), "REFRESH_STATE", {})
T.truthy("a companion that asks is told it is offline", proxySends(constants.CMD.GO_OFFLINE)[bindingOf(58002)])

T.section("a sign-in the service refuses")
tokenAnswers = { { 400, { error = "mfa_required", error_description = "A second factor is required." } } }
EC.Reconnect()
T.eq("Login Status", props["Login Status"], "Sign-in refused")
requests = {}
ShimFireTimers()
T.eq("nothing is tried again", #requests, 0)

T.section("a sign-in that fails for now tries again on its own")
tokenAnswers = { { 503, "Service Unavailable" } }
setProperty("Password", "demo-password")
T.eq("Login Status", props["Login Status"], "Login failed")
T.contains("Driver Status names the wait", props["Driver Status"], "retrying in 5s")
ShimFireTimers()
T.eq("then signs in", props["Login Status"], "Logged In")
T.eq("Account Connected fires again", events[#events], "Account Connected")

T.section("an access token that runs out is refreshed by the next poll")
requests = {}
now = now + 3600
ShimFireTimers()
local grants = {}
for _, r in ipairs(requests) do
  if r.url:sub(-#constants.TOKEN_PATH) == constants.TOKEN_PATH then
    grants[#grants + 1] = r.data:match("grant_type=([%w_]+)")
  end
end
T.eq("one refresh grant", grants, { "refresh_token" })
T.eq("then the account is read", sent("/homeowner/homes$"), 1)
T.eq("and every generator", sent("/devices/%d+%?"), 3)
T.eq("still logged in", props["Login Status"], "Logged In")

T.section("reads refused even with a fresh sign-in wait before signing in again")
requests = {}
apiAlways = { 401, { message = "Unauthorized" } }
EC.Refresh_Generators()
T.eq("the read, a sign-in and the read again, then it stops", #requests, 3)
T.eq("Login Status says so", props["Login Status"], "KOHLER refused access")
T.contains("Driver Status names the wait", props["Driver Status"], "retrying in 5s")
requests = {}
ShimFireTimers()
T.eq("the retry reads, signs in and reads once more", #requests, 3)
T.contains("and waits longer", props["Driver Status"], "retrying in 10s")
apiAlways = nil
ShimFireTimers()
T.eq("once reads work again", props["Login Status"], "Logged In")
T.eq("the generators are read", props["Driver Status"], "Connected (3 generators)")

T.section("a read answered after Reset Driver is not taken")
held = {}
EC.Refresh_Generators()
EC.Reset_Driver({ ["Are You Sure?"] = "Yes" })
local stale = table.remove(held, 1)
local signIn = held
held = nil
stale()
T.falsy("no binding comes back from it", bindingOf(58001))
T.eq("nor a count", props["Driver Status"], "Connecting")
for _, release in ipairs(signIn) do
  release()
end
T.eq("the new sign-in reads the account", props["Driver Status"], "Connected (3 generators)")
T.truthy("and binds it", bindingOf(58001))

T.section("a read answered after the email changes is not taken")
held = {}
EC.Refresh_Generators()
setProperty("Email", "other@example.com")
stale = table.remove(held, 1)
held = nil
stale()
T.eq("the old account's generators are not shown", props["Driver Status"], "Connecting")

T.finish()
