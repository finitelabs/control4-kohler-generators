-- Kohler Generators: the KOHLER Energy Management account.
--
-- Signs in with the homeowner's email and password, reads the account's generators on the poll
-- interval, and exposes a dynamic PROXY binding per generator that the kohler_generator companion
-- drivers bind to. Each companion receives its generator's full record over the binding
-- (updateGenerator). Add Generators gives every generator a companion.

--#ifndef DRIVERCENTRAL
DRIVER_GITHUB_REPO = "finitelabs/control4-kohler-generators"
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local bindings = require("lib.bindings")
local companions = require("lib.companions")
local values = require("lib.values")
local updateSettings = require("lib.update-settings")
--#ifdef DRIVERCENTRAL
local drivercentral = require("lib.drivercentral")
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif
--#ifndef DRIVERCENTRAL
local driverFilenames = require("lib.driver-filenames")
local githubUpdater = require("lib.github-updater")
--#endif

local Client = require("kohler.client")
local Generator = require("kohler.generator")
local constants = require("constants")

--- Whether the license gate lets the account reach KOHLER. An OSS build has no gate.
--- @return boolean
local function licensed()
  --#ifdef DRIVERCENTRAL
  if not drivercentral:licensed() then
    return false
  end
  --#endif
  return true
end

--- Whether the license gate holds the account stopped, logged for an action it refuses.
--- @return boolean
local function stopped()
  if licensed() then
    return false
  end
  log:print("No active license: the KOHLER account stays stopped")
  return true
end

local NS = constants.BINDING_NAMESPACE
local CMD = constants.CMD

--- driver.xml event ids.
local EVENT = { ACCOUNT_CONNECTED = 1, ACCOUNT_DISCONNECTED = 2 }

--- Poll interval when the property holds nothing usable.
local DEFAULT_POLL_S = 60
--- The wait before signing in again after a sign-in that may work later, and its ceiling.
local LOGIN_RETRY_S = 5
local LOGIN_RETRY_MAX_S = 300
--- The pause after a 5xx or no answer, doubling to its ceiling while they continue.
local UNAVAILABLE_BACKOFF_S = 30
local UNAVAILABLE_BACKOFF_MAX_S = 300

local COMPANION_DRIVER = "kohler_generator.c4z"
--- Added to the name of a companion whose generator is no longer on the account.
local REMOVED_SUFFIX = " - REMOVED FROM KOHLER"

local client = Client:new({ allowed = licensed })

--- Runtime state (not persisted; rebuilt from the cloud).
local gState = {
  --- @type table<string, table> generator id -> its latest record
  records = {},
  --- @type table<string, KohlerIdentity> generator id -> its identity, from homeowner/homes
  generators = {},
}

--- Set true once OnDriverLateInit finishes; guards the property handlers from firing while
--- Composer replays the initial property values.
local gInitialized = false

--- Monotonic ids for refreshes, so a slow one that started before a newer one can't overwrite it.
local gRefreshIssued = 0
local gRefreshAccepted = 0

--- os.time() before which no poll is sent, after a 429 or a run of 5xx answers.
local gPausedUntil = 0
--- The next pause after a 5xx; nil once a refresh has worked.
--- @type number|nil
local gUnavailableBackoffS = nil

--- Set once a refresh has listed the account's generators, so Add Generators knows them.
local gListed = false

--- Whether the account is connected, as the Account Connected variable says.
local gConnected = false
--- Whether the account was connected at the last change: nil until the first change after
--- start-up, so a start-up sign-in is not news.
--- @type boolean|nil
local gWasConnected = nil

--- Bumped on every sign-in, so a retry armed by an earlier one retires itself.
local gLoginGeneration = 0

--- All Kohler Generators instances on this controller, sorted by device id. Used for leader
--- election (lowest id is the leader that runs updates).
--- @return integer[]
local function getAccountDriverIds()
  local drivers = C4:GetDevicesByC4iName(C4:GetDriverFileName()) or {}
  local ids = {}
  for id in pairs(drivers) do
    ids[#ids + 1] = tonumber(id)
  end
  table.sort(ids)
  return ids
end

-- ─── Companion handoff ─────────────────────────────────────────────────────

--- Push a generator's record to its bound companion (if any).
--- @param key string The generator's id.
local function handoff(key)
  local record = gState.records[key]
  local binding = bindings:getDynamicBinding(NS, key)
  if not record or not binding then
    return
  end
  SendToProxy(binding.bindingId, CMD.UPDATE_GENERATOR, { JSON = JSON:encode(record) })
end

--- Tell a generator's companion it is gone.
--- @param key string
local function goOffline(key)
  local binding = bindings:getDynamicBinding(NS, key)
  if binding then
    SendToProxy(binding.bindingId, CMD.GO_OFFLINE, {})
  end
end

--- Resolve the generator behind a dynamic binding id.
--- @param idBinding integer
--- @return string|nil key
local function keyForBinding(idBinding)
  for key, binding in pairs(bindings:getDynamicBindings(NS)) do
    if binding.bindingId == idBinding then
      return key
    end
  end
  return nil
end

--- Make sure a generator has its provider binding, with a bind handler that hands the record off
--- when a companion connects.
--- @param identity KohlerIdentity
--- @return table|nil binding
local function ensureBinding(identity)
  local key = tostring(identity.id)
  local binding = bindings:getOrAddDynamicBinding(NS, key, "PROXY", true, identity.name, constants.GENERATOR_CLASS)
  if binding then
    OBC[binding.bindingId] = function(_idBinding, _strClass, bIsBound)
      if bIsBound then
        handoff(key)
      end
    end
  end
  return binding
end

--- @param count integer
--- @return string
local function connectedStatus(count)
  return string.format("Connected (%d generator%s)", count, count == 1 and "" or "s")
end

-- ─── Reading the account ───────────────────────────────────────────────────

--- Signs in; defined under Sign-in.
--- @type fun(retryBackoffS?: number)
local login

--- A failed read: a 429 or 5xx pauses the poll; a refused token signs in again.
--- @param err KohlerError
--- @param what string
local function readFailed(err, what)
  log:warn("Reading %s failed: %s", what, err.message)
  if err.kind == "rateLimited" then
    gPausedUntil = os.time() + err.retryAfter
    C4:UpdateProperty("Driver Status", string.format("Rate limited by KOHLER; retrying in %ds", err.retryAfter))
  elseif err.kind == "unavailable" then
    local wait = gUnavailableBackoffS or UNAVAILABLE_BACKOFF_S
    gUnavailableBackoffS = math.min(wait * 2, UNAVAILABLE_BACKOFF_MAX_S)
    gPausedUntil = os.time() + wait
    C4:UpdateProperty("Driver Status", string.format("KOHLER is not answering; retrying in %ds", wait))
  elseif err.kind == "unauthorized" or err.kind == "credentials" or err.kind == "refused" then
    login()
  else
    C4:UpdateProperty("Driver Status", "Error reading generators: " .. tostring(err.message))
  end
end

--- Read one generator's record and hand it to its companion.
--- @param identity KohlerIdentity
--- @param refreshId integer
--- @return Deferred
local function readGenerator(identity, refreshId)
  local key = tostring(identity.id)
  return client:getDevice(identity.id, identity.host):next(function(record)
    if refreshId < gRefreshAccepted then
      return
    end
    gState.records[key] = record
    handoff(key)
  end, function(err)
    if refreshId >= gRefreshAccepted then
      readFailed(err, identity.name)
    end
  end)
end

--- Read the account's generators and each one's record. Responses are accepted in issue order
--- only, and a generator the account no longer lists is taken offline.
--- @return Deferred|nil refresh Settles when the homes read does; nil when none was sent.
local function refreshGenerators()
  if not client:isAuthenticated() or not licensed() then
    return nil
  end
  if os.time() < gPausedUntil then
    log:debug("Skipping a refresh: paused for %ds more", gPausedUntil - os.time())
    return nil
  end
  gRefreshIssued = gRefreshIssued + 1
  local refreshId = gRefreshIssued
  return client:getHomes():next(function(homes)
    if refreshId < gRefreshAccepted then
      log:trace("Discarding stale refresh %d (accepted %d)", refreshId, gRefreshAccepted)
      return
    end
    gRefreshAccepted = refreshId
    gListed = true
    gUnavailableBackoffS = nil
    local listed = {}
    local list = Generator.fromHomes(homes)
    for _, identity in ipairs(list) do
      local key = tostring(identity.id)
      listed[key] = true
      gState.generators[key] = identity
      ensureBinding(identity)
      readGenerator(identity, refreshId)
    end
    for key in pairs(gState.generators) do
      if not listed[key] then
        log:info("Generator %s is no longer on the account", key)
        gState.generators[key] = nil
        gState.records[key] = nil
        goOffline(key)
      end
    end
    C4:UpdateProperty("Driver Status", connectedStatus(#list))
  end, function(err)
    if refreshId >= gRefreshAccepted then
      readFailed(err, "the account's generators")
    end
  end)
end

--- Whether a scheduled poll is still waiting on KOHLER.
local gPollInFlight = false

--- A scheduled poll, skipped while the last one is outstanding so a slow cloud does not collect
--- requests. Refresh Generators is not held back by this.
local function pollTick()
  if gPollInFlight then
    log:debug("Skipping a poll: the last one has not finished")
    return
  end
  local refresh = refreshGenerators()
  if refresh == nil then
    return
  end
  gPollInFlight = true
  local function done()
    gPollInFlight = false
  end
  refresh:next(done, done)
end

--- The poll interval in seconds, from the Poll Interval property.
--- @return integer
local function pollIntervalS()
  return tonumber((Properties["Poll Interval"] or ""):match("^(%d+)")) or DEFAULT_POLL_S
end

local function startPolling()
  if not licensed() then
    return
  end
  SetTimer("KohlerPoll", pollIntervalS() * ONE_SECOND, pollTick, true)
end

local function stopPolling()
  CancelTimer("KohlerPoll")
  gPollInFlight = false
end

-- ─── Companions ────────────────────────────────────────────────────────────

--- @param deviceId integer
--- @return integer|nil
local function proxyOf(deviceId)
  return tonumber((tostring(C4:GetProxyDevicesById(deviceId) or "")):match("^(%d+)"))
end

--- Rename the companions of generators that are no longer on the account, so the integrator can
--- find and remove them, and restore the name of one whose generator is back.
local function markRemovedCompanions()
  for key, binding in pairs(bindings:getDynamicBindings(NS)) do
    local listed = gState.generators[key] ~= nil
    for deviceId in pairs(C4:GetBoundConsumerDevices(C4:GetDeviceID(), binding.bindingId) or {}) do
      local proxyId = proxyOf(tonumber(deviceId))
      local name = proxyId and C4:GetDeviceDisplayName(proxyId)
      local marked = name and name:find(REMOVED_SUFFIX, 1, true) ~= nil
      if name and not listed and not marked then
        log:info("Generator %s left the account; renaming %s", key, name)
        C4:RenameDevice(proxyId, name .. REMOVED_SUFFIX)
      elseif name and listed and marked then
        log:info("Generator %s is back on the account; renaming %s", key, name)
        C4:RenameDevice(proxyId, (name:gsub(REMOVED_SUFFIX:gsub("%p", "%%%0"), "")))
      end
    end
  end
end

--- Give every generator on the account a companion driver: the one it had, a spare in this
--- driver's room, or a new one named after the generator.
local function addGenerators()
  if companions.running then
    log:info("Add Generators is already running")
    return
  end
  if not client:isAuthenticated() or not gListed then
    C4:UpdateProperty("Driver Status", "Sign in before adding generators")
    return
  end
  markRemovedCompanions()
  local needs = {}
  for key, identity in pairs(gState.generators) do
    local binding = ensureBinding(identity)
    if binding then
      needs[#needs + 1] = {
        binding = binding.bindingId,
        file = COMPANION_DRIVER,
        consumer = constants.GENERATOR_BINDING,
        class = constants.GENERATOR_CLASS,
        name = identity.name,
        key = key,
      }
    end
  end
  table.sort(needs, function(a, b)
    return a.name < b.name
  end)
  if #needs == 0 then
    C4:UpdateProperty("Driver Status", "The account has no generators")
    return
  end
  companions
    :setup(needs, {
      spares = "room",
      progress = function(done, total)
        C4:UpdateProperty("Driver Status", string.format("Adding generator %d of %d...", done, total))
      end,
    })
    :next(function(result)
      log:info(
        "Add Generators: %d kept, %d bound again, %d spares, %d added, %d failed",
        result.kept,
        result.rebound,
        result.spares,
        result.added,
        result.failed
      )
      for _, need in ipairs(needs) do
        handoff(need.key)
      end
      if #result.missing > 0 then
        C4:UpdateProperty("Driver Status", "Load the Kohler Generator driver on the controller first")
      elseif result.failed > 0 then
        C4:UpdateProperty("Driver Status", string.format("%d generator(s) got no driver", result.failed))
      else
        C4:UpdateProperty("Driver Status", connectedStatus(TableLength(gState.generators)))
      end
    end, function(err)
      log:warn("Add Generators failed: %s", err)
    end)
end

-- ─── Sign-in ───────────────────────────────────────────────────────────────

--- Tests whether the account is connected to KOHLER.
--- @param strConditionName string
--- @param tParams table VALUE ("Connected" or "Not Connected") and LOGIC.
--- @return boolean result
function TC.ACCOUNT_CONNECTED(strConditionName, tParams)
  log:trace("TC.ACCOUNT_CONNECTED(%s, %s)", strConditionName, tParams)
  local test = Select(tParams, "VALUE") == "Connected"
  if Select(tParams, "LOGIC") == "NOT_EQUAL" then
    return test ~= gConnected
  end
  return test == gConnected
end

--- Record whether the account is connected, firing its event on a change after start-up.
--- @param connected boolean
local function setConnected(connected)
  gConnected = connected
  values:update("Account Connected", connected, "BOOL")
  if connected and gWasConnected == false then
    C4:FireEventByID(EVENT.ACCOUNT_CONNECTED)
  elseif not connected and gWasConnected == true then
    C4:FireEventByID(EVENT.ACCOUNT_DISCONNECTED)
  end
  gWasConnected = connected
end

--- Take every generator offline and forget what was read.
local function dropGenerators()
  for key in pairs(gState.generators) do
    goOffline(key)
  end
  gState.generators, gState.records = {}, {}
  gListed = false
end

--- Sign in with the Email and Password properties, then read the account and poll. A wrong
--- email or password, or a sign-in the service refuses, stops until they change or Reconnect;
--- anything else tries again with a growing wait.
--- @param retryBackoffS? number The wait before the next try, when this one is a retry.
login = function(retryBackoffS)
  gLoginGeneration = gLoginGeneration + 1
  local generation = gLoginGeneration
  CancelTimer("KohlerLoginRetry")
  stopPolling()
  if not licensed() then
    return
  end
  local email, password = Properties["Email"], Properties["Password"]
  client:setCredentials(email, password)
  if IsEmpty(email) or IsEmpty(password) then
    client:signOut()
    C4:UpdateProperty("Login Status", "Enter email and password")
    C4:UpdateProperty("Driver Status", "Awaiting credentials")
    setConnected(false)
    dropGenerators()
    return
  end
  if not client:isConfigured() then
    C4:UpdateProperty("Login Status", "This build has no KOHLER client")
    C4:UpdateProperty("Driver Status", "Not configured")
    return
  end
  C4:UpdateProperty("Login Status", "Logging in...")
  C4:UpdateProperty("Driver Status", "Connecting")
  client:signIn():next(function()
    if generation ~= gLoginGeneration then
      return
    end
    C4:UpdateProperty("Login Status", "Logged In")
    setConnected(true)
    gPausedUntil, gUnavailableBackoffS = 0, nil
    refreshGenerators()
    startPolling()
  end, function(err)
    if generation ~= gLoginGeneration then
      return
    end
    log:warn("Signing in to KOHLER failed: %s", err.message)
    setConnected(false)
    if err.kind == "credentials" then
      C4:UpdateProperty("Login Status", err.message)
      C4:UpdateProperty("Driver Status", "Not connected")
      dropGenerators()
      return
    end
    if err.kind == "refused" then
      C4:UpdateProperty("Login Status", "Sign-in refused")
      C4:UpdateProperty("Driver Status", "Not connected")
      dropGenerators()
      return
    end
    local delay = err.retryAfter or retryBackoffS or LOGIN_RETRY_S
    C4:UpdateProperty("Login Status", "Login failed")
    C4:UpdateProperty("Driver Status", string.format("Not connected; retrying in %ds", delay))
    for key in pairs(gState.generators) do
      goOffline(key)
    end
    SetTimer("KohlerLoginRetry", delay * ONE_SECOND, function()
      if generation == gLoginGeneration then
        login(math.min(delay * 2, LOGIN_RETRY_MAX_S))
      end
    end)
  end)
end

--#ifdef DRIVERCENTRAL
--- The license gate stopped the account: nothing reaches KOHLER and the generators go offline
--- until a license is back.
local function stopAccount()
  gLoginGeneration = gLoginGeneration + 1
  stopPolling()
  CancelTimer("KohlerLoginRetry")
  client:signOut()
  dropGenerators()
  setConnected(false)
  C4:UpdateProperty("Login Status", drivercentral.UNLICENSED_STATUS)
  C4:UpdateProperty("Driver Status", drivercentral.UNLICENSED_STATUS)
end
--#endif

--- For development, from the Lua window: points this run of the driver at a test cloud such as
--- test/mock-kohler instead of KOHLER's, and signs in there. Never stored: a driver restart,
--- Reset Driver and a call with no server go back to KOHLER's. A DriverCentral build runs it only
--- while the Support Code has the Lua window open.
--- @param server string|nil The test cloud's origin, such as "http://host:18400".
--- @param clientId string|nil Its client id.
--- @param clientSecret string|nil Its client secret.
--- @param apiKey string|nil Its API key.
function UseTestCloud(server, clientId, clientSecret, apiKey)
  if not gInitialized then
    return
  end
  client:setServer(server, clientId, clientSecret, apiKey)
  dropGenerators()
  log:info(client:usesTestCloud() and "Using a test cloud" or "Using KOHLER's cloud")
  login()
end

--#ifndef DRIVERCENTRAL
--- Update the driver(s) from the GitHub repository.
--- @param forceUpdate? boolean Force the update even if already up to date.
function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, driverFilenames, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if updatedDrivers and #updatedDrivers > 0 then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      end
    end, function(err)
      log:warn("Driver update failed: %s", err)
    end)
end
--#endif

-- ─── Lifecycle ─────────────────────────────────────────────────────────────

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  drivercentral:startClient()
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")

  -- Before OnDriverLateInit: Director resolves stored connections and variables' programming
  -- before then (src/lib/bindings.lua, src/lib/values.lua).
  bindings:restoreBindings()
  values:restoreValues()
  local stored = values:getValue("Account Connected")
  if stored == nil or stored.deleted then
    values:update("Account Connected", false, "BOOL")
  end
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- The router runs each handler in its own xpcall and reports its error, so the rest still run.
  for p, _ in pairs(Properties) do
    OnPropertyChanged(p)
  end

  -- Each binding's bind handler, so a companion that connects is handed its record.
  for key, binding in pairs(bindings:getDynamicBindings(NS)) do
    OBC[binding.bindingId] = function(_idBinding, _strClass, bIsBound)
      if bIsBound then
        handoff(key)
      end
    end
  end

  --#ifndef DRIVERCENTRAL
  -- Auto-update: only the leader account instance checks, at most every 30 min, and only when
  -- Automatic Updates is On. The DriverCentral build lets cloud-client-byte own updates instead.
  SetTimer("UpdateCheck", 30 * ONE_MINUTE, function()
    local isLeader = Select(getAccountDriverIds(), 1) == C4:GetDeviceID()
    if isLeader and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
      UpdateDrivers()
    end
  end, true)
  --#endif

  gInitialized = true
  --#ifdef DRIVERCENTRAL
  drivercentral:startGate(function(isLicensed)
    if isLicensed then
      login()
    else
      stopAccount()
    end
  end)
  if not licensed() then
    return
  end
  --#endif
  login()
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

function OnDriverDestroyed()
  gLoginGeneration = gLoginGeneration + 1
  stopPolling()
  CancelTimer("KohlerLoginRetry")
  CancelTimer("UpdateCheck")
end

-- ─── Property handlers (OPC dispatch) ──────────────────────────────────────

OPC.suppressDebug["Password"] = true

function OPC.Driver_Status(_v)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

function OPC.Driver_Version(_v)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
end

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    return
  end
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    UpdateProperty("Log Mode", "Off", true)
  end)
end

function OPC.Email(_v)
  if gInitialized then
    login()
  end
end

--- Not logged: the value is the password.
function OPC.Password(_v)
  if gInitialized then
    login()
  end
end

function OPC.Poll_Interval(_v)
  if gInitialized and client:isAuthenticated() then
    startPolling()
  end
end

function OPC.Automatic_Updates(propertyValue)
  if gInitialized then
    updateSettings:share("Automatic Updates", propertyValue)
  end
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  if gInitialized then
    updateSettings:share("Update Channel", propertyValue)
  end
end
--#endif

-- ─── Messages from a companion (RFP dispatch) ──────────────────────────────

--- A companion that started up asks for its generator's record.
--- @param idBinding integer
function RFP.REFRESH_STATE(idBinding)
  log:trace("RFP.REFRESH_STATE(%s)", idBinding)
  local key = keyForBinding(idBinding)
  if not key then
    return
  end
  if gState.records[key] then
    handoff(key)
  elseif not client:isAuthenticated() then
    SendToProxy(idBinding, CMD.GO_OFFLINE, {})
  end
end

-- ─── Actions (EC dispatch) ─────────────────────────────────────────────────

function EC.Add_Generators()
  log:trace("EC.Add_Generators()")
  if stopped() then
    return
  end
  addGenerators()
end

function EC.Refresh_Generators()
  log:trace("EC.Refresh_Generators()")
  if stopped() then
    return
  end
  gPausedUntil = 0
  refreshGenerators()
end

function EC.Reconnect()
  log:trace("EC.Reconnect()")
  if stopped() then
    return
  end
  client:signOut()
  login()
end

function EC.Reset_Driver(tParams)
  log:trace("EC.Reset_Driver()")
  if (tParams or {})["Are You Sure?"] == "Yes" then
    dropGenerators()
    bindings:reset()
    companions:reset()
    client:setServer(nil)
    C4:UpdateProperty("Login Status", "")
    --#ifdef DRIVERCENTRAL
    UpdateProperty("Cloud Monitoring", "Enabled", true)
    --#endif
    login()
  end
end

--- An update setting changed on another item.
function EC.SET_UPDATE_SETTING(params)
  log:trace("EC.SET_UPDATE_SETTING(%s)", params)
  updateSettings:take(params)
end

--#ifdef DRIVERCENTRAL
--- Not logged: the value is the code.
function OPC.Support_Code(propertyValue)
  supportCode:enter(propertyValue)
end

--- Turns Cloud Monitoring on or off.
--- @param propertyValue string
function OPC.Cloud_Monitoring(propertyValue)
  diagnostics:setEnabled(propertyValue == "Enabled")
end

--- Prints a diagnostics report, and sends it while Cloud Monitoring is on.
function EC.DiagnosticsSnapshot()
  diagnostics:dumpSnapshot()
end
--#endif

--#ifndef DRIVERCENTRAL
function EC.Update_Drivers()
  log:trace("EC.Update_Drivers()")
  UpdateDrivers(true)
end
--#endif
