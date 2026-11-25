-- Kohler Generator: one KOHLER generator on a Kohler Generators account.
--
-- Has no network of its own: the account hands it the generator's full record over binding 5002
-- (updateGenerator) on every read, and goOffline when the generator leaves the account or the
-- account is signed out. Its UI Button proxy puts the generator in the Navigator; a tap on it
-- never runs the generator.

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local values = require("lib.values")
local updateSettings = require("lib.update-settings")
--#ifdef DRIVERCENTRAL
local drivercentral = require("lib.drivercentral")
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif

local Generator = require("kohler.generator")
local constants = require("constants")

local ACCOUNT_BINDING = constants.GENERATOR_BINDING

--- driver.xml event ids.
local EVENT = { GENERATOR_ONLINE = 1, GENERATOR_OFFLINE = 2 }

--- The identity properties, filled from each record.
local IDENTITY_PROPERTIES = {
  { "Generator Name", "name" },
  { "Model", "model" },
  { "Serial Number", "serial" },
  { "Controller", "controller" },
  { "Firmware Version", "firmware" },
  { "Fuel Type", "fuel" },
  { "Connection Type", "connection" },
  { "Dealer", "dealer" },
}

local gInitialized = false

--- The generator as the last record gave it; nil while the account has handed none.
--- @type KohlerIdentity|nil
local gIdentity = nil

--- Whether the generator is online, as the Online variable says: restored at start, so a start
--- that finds it as it was fires nothing.
local gOnline = false

-- ─── Programming ───────────────────────────────────────────────────────────

--- Record whether the generator is online, firing its event on a change.
--- @param online boolean
local function setOnline(online)
  values:update("Online", online, "BOOL")
  if online ~= gOnline then
    gOnline = online
    C4:FireEventByID(online and EVENT.GENERATOR_ONLINE or EVENT.GENERATOR_OFFLINE)
  end
end

--- Tests whether the generator is online.
--- @param strConditionName string
--- @param tParams table VALUE ("Online" or "Offline") and LOGIC.
--- @return boolean result
function TC.GENERATOR_ONLINE(strConditionName, tParams)
  log:trace("TC.GENERATOR_ONLINE(%s, %s)", strConditionName, tParams)
  local test = Select(tParams, "VALUE") == "Online"
  if Select(tParams, "LOGIC") == "NOT_EQUAL" then
    return test ~= gOnline
  end
  return test == gOnline
end

-- ─── Account handoff (account to this companion) ───────────────────────────

--- With Auto Rename Driver on, name this driver after its generator in the KOHLER app.
local function applyGeneratorName()
  if not gIdentity or Properties["Auto Rename Driver"] ~= "On" or IsEmpty(gIdentity.name) then
    return
  end
  local proxyId = tonumber((tostring(C4:GetProxyDevicesById(C4:GetDeviceID()) or "")):match("^(%d+)"))
  RenameDevice(proxyId or C4:GetDeviceID(), gIdentity.name)
end

--- The account hands over the generator's full record.
--- @param idBinding integer
--- @param _strCommand string
--- @param tParams table { JSON = the record }
function RFP.updateGenerator(idBinding, _strCommand, tParams)
  log:trace("RFP.updateGenerator(%s)", idBinding)
  local ok, record = pcall(JSON.decode, JSON, (tParams or {}).JSON or "")
  local identity = ok and Generator.identity(record) or nil
  if not identity then
    log:warn("The account sent a generator record this driver cannot read")
    return
  end
  local renamed = not gIdentity or gIdentity.name ~= identity.name
  gIdentity = identity
  for _, p in ipairs(IDENTITY_PROPERTIES) do
    C4:UpdateProperty(p[1], identity[p[2]])
  end
  if renamed then
    applyGeneratorName()
  end
  C4:UpdateProperty("Driver Status", identity.connected and "Online" or "Generator offline")
  setOnline(identity.connected)
end

--- The generator left the account, or the account is signed out.
--- @param idBinding integer
function RFP.goOffline(idBinding)
  log:trace("RFP.goOffline(%s)", idBinding)
  gIdentity = nil
  C4:UpdateProperty("Driver Status", "Offline")
  setOnline(false)
end

--- A tap on the Navigator button. It runs nothing: the generator page arrives with a later
--- release.
--- @param idBinding integer
function RFP.SELECT(idBinding)
  log:trace("RFP.SELECT(%s)", idBinding)
end

-- ─── Property handlers (OPC dispatch) ──────────────────────────────────────

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

function OPC.Driver_Status(_v)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

function OPC.Auto_Rename_Driver(_v)
  if gInitialized then
    applyGeneratorName()
  end
end

function OPC.Driver_Version(_v)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Automatic_Updates(propertyValue)
  if gInitialized then
    updateSettings:share("Automatic Updates", propertyValue)
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

  -- Before OnDriverLateInit: Director resolves variables' programming before then.
  values:restoreValues()
  local stored = values:getValue("Online")
  if stored == nil or stored.deleted then
    values:update("Online", false, "BOOL")
  end
  gOnline = toboolean(Select(values:getValue("Online"), "value"))
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
  gInitialized = true
  C4:UpdateProperty("Driver Status", "Waiting for the Kohler Generators driver")
  -- The account answers with the record, or goOffline while it is signed out.
  SendToProxy(ACCOUNT_BINDING, constants.CMD.REFRESH_STATE, {})
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif
