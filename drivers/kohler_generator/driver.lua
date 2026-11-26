-- Kohler Generator: one KOHLER generator on a Kohler Generators account.
--
-- Has no network of its own: the account hands it the generator's full record over binding 5002
-- (updateGenerator) on every read, its alerts and event log (updateFeeds) every few minutes, and
-- goOffline when the generator leaves the account or the account is signed out. It turns them into
-- variables, events, conditionals and four contact outputs. Its commands (start or stop an
-- exercise, the exercise schedule, a load-shed load, Refresh) go to the account as generatorCommand,
-- which answers commandResult. Its UI Button proxy puts the generator in the Navigator, where it
-- opens the generator page (www/dist); the page sends the same commands, and opening it or tapping
-- the icon never runs the generator.

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local values = require("lib.values")
local persist = require("lib.persist")
local updateSettings = require("lib.update-settings")
--#ifdef DRIVERCENTRAL
local drivercentral = require("lib.drivercentral")
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif

local Controls = require("kohler.controls")
local Generator = require("kohler.generator")
local Page = require("kohler.page")
local Status = require("kohler.status")
local constants = require("constants")

local ACCOUNT_BINDING = constants.GENERATOR_BINDING
local PROXY_BINDING = 5001

--- driver.xml event ids.
local EVENT = {
  GENERATOR_ONLINE = 1,
  GENERATOR_OFFLINE = 2,
  ["Utility Power Lost"] = 3,
  ["Utility Power Restored"] = 4,
  ["Engine Started"] = 5,
  ["Engine Stopped"] = 6,
  ["Exercise Started"] = 7,
  ["Exercise Ended"] = 8,
  ["Fault"] = 9,
  ["Warning"] = 10,
  ["Alerts Cleared"] = 11,
  ["Switch Not In Auto"] = 12,
  ["Switch Back In Auto"] = 13,
  ["Maintenance Due"] = 14,
  ["Low Battery"] = 15,
}

--- The variables every generator has, with the type and value each starts with.
local VARIABLES = {
  { "Status", "STRING", "" },
  { "Engine State", "STRING", "" },
  { "Power Source", "STRING", "" },
  { "On Generator Power", "BOOL", false },
  { "Running", "BOOL", false },
  { "Switch Position", "STRING", "" },
  { "In Auto", "BOOL", false },
  { "Fault", "BOOL", false },
  { "Active Alerts", "NUMBER", 0 },
  { "Last Alert", "STRING", "" },
  { "Utility Voltage", "NUMBER", nil },
  { "Generator Voltage", "NUMBER", nil },
  { "Load Watts", "NUMBER", nil },
  { "Load Percent", "NUMBER", nil },
  { "Frequency", "NUMBER", nil },
  { "Engine RPM", "NUMBER", nil },
  { "Battery Voltage", "NUMBER", nil },
  { "Oil Pressure OK", "BOOL", nil },
  { "Controller Temperature", "NUMBER", nil },
  { "Lube Oil Temperature", "NUMBER", nil },
  { "Coolant Temperature", "NUMBER", nil },
  { "Runtime Hours", "NUMBER", nil },
  { "Operation Hours", "NUMBER", nil },
  { "Hours Since Maintenance", "NUMBER", nil },
  { "Last Ran", "STRING", "" },
  { "Next Exercise", "STRING", "" },
  { "Next Maintenance", "STRING", "" },
  { "Maintenance Due", "BOOL", false },
}

--- The contact outputs: driver.xml connection id, and whether each is closed.
local CONTACTS = {
  { id = 1, name = "On Generator Power" },
  { id = 2, name = "Running" },
  { id = 3, name = "Fault" },
  { id = 4, name = "Not In Auto" },
}

--- How old an event logged while the driver was stopped may be and still fire.
local RESTART_GRACE_S = 300

--- Persisted: the highest event id this generator's events have fired up to.
local CURSOR_KEY = "EventCursor"

--- Persisted: the flags the last record set, so a change across a restart fires once.
local FLAGS_KEY = "StatusFlags"

--- Persisted: how many alerts were active at the last read, so alerts that clear across a restart
--- fire Alerts Cleared once.
local ALERT_COUNT_KEY = "AlertCount"

--- Persisted: each contact output's state as last told, by connection id as text.
local CONTACTS_KEY = "ContactStates"

--- Persisted: set once the driver has chosen Load Control from the first record, after which the
--- property is the integrator's.
local LOAD_CONTROL_SET_KEY = "LoadControlSet"

--- What each command is called in the Driver Status.
local COMMAND_NAMES = {
  start = "Start Exercise",
  stop = "Stop Exercise",
  schedule = "Set Exercise Schedule",
  load = "Set Load",
}

--- The identity properties, filled from each record.
local IDENTITY_PROPERTIES = {
  { "Generator Name", "kohlerName" },
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

--- The generator's state at the last record; nil until the first since start-up.
--- @type KohlerStatus|nil
local gStatus = nil

--- What its alerts said at the last read; nil until the first since start-up.
--- @type KohlerAlerts|nil
local gAlerts = nil

--- The flags the last record set, which the next one is compared with; restored at start, and nil
--- only before a generator's first record ever.
--- @type table|nil
local gFlags = nil

--- Whether an event log has been read since start-up.
local gEventsRead = false

--- Each contact output's state as last told to its proxy, by connection id; nil until told since
--- start-up.
--- @type table<integer, boolean>
local gTold = {}

--- Each contact output's state as last told before start-up, by connection id as text.
--- @type table<string, boolean>
local gToldBefore = {}

--- The load variables the driver has made, by variable name.
--- @type table<string, boolean>
local gLoadVariables = {}

--- The generator's last record; nil until the first since start-up.
--- @type table|nil
local gRecord = nil

--- How long a command's result stays in Driver Status before a reading may replace it, in seconds.
local RESULT_HOLD_S = 30

--- os.time() until which Driver Status keeps the last command's result.
local gResultUntil = 0

--- The generator's last alerts reply and event log, for the page; nil until the first since
--- start-up.
--- @type table|nil
local gAlertsReply = nil
--- @type table|nil
local gEventsReply = nil

--- The last command's answer, for the page: { request, action, ok, message }.
--- @type table|nil
local gLastCommand = nil

--- The Navigator icon's state as last sent; nil until sent since start-up.
--- @type string|nil
local gIcon = nil

--- The link with open generator pages; made in OnDriverInit.
--- @type KohlerPageLink|nil
local gPage = nil

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

--- @param name string
local function fire(name)
  log:info("%s", name)
  C4:FireEventByID(EVENT[name])
end

--- Whether the generator has a fault: it reports it is shut down, or an alert is a fault.
--- @return boolean
local function hasFault()
  return (gStatus ~= nil and gStatus.shutDown) or (gAlerts ~= nil and gAlerts.fault)
end

--- Whether a contact output is closed; nil before the first record.
--- @param id integer
--- @return boolean|nil
local function contactClosed(id)
  if gStatus == nil then
    return nil
  end
  if id == 1 then
    return gStatus.onGeneratorPower
  elseif id == 2 then
    return gStatus.running
  elseif id == 3 then
    return hasFault()
  end
  return not gStatus.inAuto
end

--- Tell each contact output's proxies its state: a change as CLOSED or OPENED, which fires the
--- contact's programming, and a state unchanged since before start-up as STATE_CLOSED or
--- STATE_OPENED, which fires nothing.
local function tellContacts()
  local changed = false
  for _, contact in ipairs(CONTACTS) do
    local closed = contactClosed(contact.id)
    if closed ~= nil and closed ~= gTold[contact.id] then
      local was = gTold[contact.id]
      if was == nil then
        was = gToldBefore[tostring(contact.id)]
      end
      local state = closed and "CLOSED" or "OPENED"
      SendToProxy(contact.id, (was == nil or was == closed) and ("STATE_" .. state) or state, {}, "NOTIFY")
      gTold[contact.id] = closed
      gToldBefore[tostring(contact.id)] = closed
      changed = true
    end
  end
  if changed then
    persist:set(CONTACTS_KEY, gToldBefore)
  end
end

--- Record whether the generator has a fault.
local function updateFault()
  values:update("Fault", hasFault(), "BOOL")
end

--- Show the generator's state as its Navigator icon, when it changed.
local function updateIcon()
  local id, description = Status.icon(gOnline, gStatus, hasFault())
  if id == gIcon then
    return
  end
  gIcon = id
  -- A notification: the proxy ignores ICON_CHANGED sent as a command.
  SendToProxy(PROXY_BINDING, "ICON_CHANGED", { icon = id, icon_description = description }, "NOTIFY", true)
end

--- The temperature scale the project shows.
--- @return string "C" or "F"
local function scale()
  return TemperatureScaleLetter(C4:GetTemperatureScale()) or "F"
end

--- Whether Load Control is on.
--- @return boolean
local function loadControlOn()
  return Properties["Load Control"] == "On"
end

--- Send open generator pages the state when it changed.
local function publishPage()
  if gPage ~= nil then
    gPage:publish()
  end
end

--- A load's variable name: "Load HVAC A", "Load A".
--- @param loadName string
--- @return string
local function loadVariable(loadName)
  return loadName:find("^Load ") and loadName or ("Load " .. loadName)
end

--- Remove the load variables, while Load Control is off: those made since start-up, and those the
--- record's loads would have, which a restart restored.
--- @param loads KohlerLoad[]
local function removeLoadVariables(loads)
  for _, load in ipairs(loads) do
    gLoadVariables[loadVariable(load.name)] = true
  end
  for name in pairs(gLoadVariables) do
    local existing = values:getValue(name)
    if existing ~= nil and not existing.deleted then
      values:delete(name)
    end
  end
  gLoadVariables = {}
end

--- Keep a variable per load-shed load while Load Control is on. The first record chooses Load
--- Control: on when the generator has a load control module.
--- @param record table
--- @param loads KohlerLoad[]
local function updateLoads(record, loads)
  gRecord = record
  if not persist:get(LOAD_CONTROL_SET_KEY) then
    persist:set(LOAD_CONTROL_SET_KEY, true)
    local choice = Controls.hasLoadControl(record) and "On" or "Off"
    if Properties["Load Control"] ~= choice then
      UpdateProperty("Load Control", choice, false)
    end
  end
  if not loadControlOn() then
    removeLoadVariables(loads)
    return
  end
  for _, load in ipairs(loads) do
    local name = loadVariable(load.name)
    values:update(name, load.on, "BOOL")
    gLoadVariables[name] = true
  end
end

--- Turn a record into variables, properties and events.
--- @param record table
local function applyRecord(record)
  local s = Status.fromRecord(record, os.time(), scale())
  gStatus = s
  values:update("Status", s.status, "STRING")
  values:update("Engine State", s.engineState, "STRING")
  values:update("Power Source", s.powerSource, "STRING")
  values:update("On Generator Power", s.onGeneratorPower, "BOOL")
  values:update("Running", s.running, "BOOL")
  values:update("Switch Position", s.switchPosition, "STRING")
  values:update("In Auto", s.inAuto, "BOOL")
  for _, name in ipairs(Status.READINGS) do
    values:update(name, s.readings[name], "NUMBER")
  end
  values:update("Oil Pressure OK", s.oilPressureOk, "BOOL")
  values:update("Last Ran", s.lastRan, "STRING")
  values:update("Next Exercise", s.nextExercise, "STRING")
  values:update("Next Maintenance", s.nextMaintenance, "STRING", nil, nil, { property = false })
  values:update("Maintenance Due", s.maintenanceDue, "BOOL")
  updateLoads(record, s.loads)
  C4:UpdateProperty("Exercise Schedule", s.exerciseSchedule)
  C4:UpdateProperty("Last Maintenance", s.lastMaintenance)
  C4:UpdateProperty("Next Maintenance", s.nextMaintenance)
  updateFault()

  local flags = {
    utilityOut = s.utilityOut,
    running = s.running,
    exercising = s.exercising,
    inAuto = s.inAuto,
    maintenanceDue = s.maintenanceDue,
  }
  for _, name in ipairs(Status.transitions(gFlags, flags)) do
    fire(name)
  end
  gFlags = flags
  persist:set(FLAGS_KEY, flags)
  tellContacts()
end

--- Turn the alerts and event log into variables and events. Events logged before the last one seen
--- never fire; on the first read since start-up, only those logged in the last few minutes do.
--- @param alerts table
--- @param events table
local function applyFeeds(alerts, events)
  local a = Status.alerts(alerts)
  local hadAlerts = (tonumber(persist:get(ALERT_COUNT_KEY)) or 0) > 0
  gAlerts = a
  persist:set(ALERT_COUNT_KEY, a.count)
  values:update("Active Alerts", a.count, "NUMBER")
  values:update("Last Alert", a.last, "STRING")
  updateFault()
  if hadAlerts and a.count == 0 then
    fire("Alerts Cleared")
  end

  local cursor = tonumber(persist:get(CURSOR_KEY))
  local since = not gEventsRead and (os.time() - RESTART_GRACE_S) or nil
  local news, highest = Status.news(events, cursor, since)
  gEventsRead = true
  if highest ~= cursor then
    persist:set(CURSOR_KEY, highest)
  end
  if news.fault then
    fire("Fault")
  end
  if news.warning then
    fire("Warning")
  end
  if news.lowBattery then
    fire("Low Battery")
  end
  tellContacts()
end

--- A BOOL conditional's test with the VALUE/LOGIC idiom.
--- @param tParams table
--- @param trueText string
--- @param state boolean
--- @return boolean
local function testBool(tParams, trueText, state)
  local test = Select(tParams, "VALUE") == trueText
  if Select(tParams, "LOGIC") == "NOT_EQUAL" then
    return test ~= state
  end
  return test == state
end

--- Tests whether the house is on generator power.
--- @param _strConditionName string
--- @param tParams table VALUE and LOGIC.
--- @return boolean result
function TC.ON_GENERATOR_POWER(_strConditionName, tParams)
  return testBool(tParams, "Generator Power", gStatus ~= nil and gStatus.onGeneratorPower)
end

--- Tests whether the engine runs.
--- @param _strConditionName string
--- @param tParams table VALUE and LOGIC.
--- @return boolean result
function TC.GENERATOR_RUNNING(_strConditionName, tParams)
  return testBool(tParams, "Running", gStatus ~= nil and gStatus.running)
end

--- Tests whether the generator is exercising.
--- @param _strConditionName string
--- @param tParams table VALUE and LOGIC.
--- @return boolean result
function TC.GENERATOR_EXERCISING(_strConditionName, tParams)
  return testBool(tParams, "Exercising", gStatus ~= nil and gStatus.exercising)
end

--- Tests whether the generator's switch is in Auto.
--- @param _strConditionName string
--- @param tParams table VALUE and LOGIC.
--- @return boolean result
function TC.GENERATOR_IN_AUTO(_strConditionName, tParams)
  return testBool(tParams, "In Auto", gStatus ~= nil and gStatus.inAuto)
end

--- Tests whether the generator has a fault.
--- @param _strConditionName string
--- @param tParams table VALUE and LOGIC.
--- @return boolean result
function TC.GENERATOR_FAULT(_strConditionName, tParams)
  return testBool(tParams, "Faulted", hasFault())
end

--- Tests whether the generator's maintenance is due.
--- @param _strConditionName string
--- @param tParams table VALUE and LOGIC.
--- @return boolean result
function TC.MAINTENANCE_DUE(_strConditionName, tParams)
  return testBool(tParams, "Due", gStatus ~= nil and gStatus.maintenanceDue)
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
  if os.time() >= gResultUntil then
    C4:UpdateProperty("Driver Status", identity.connected and "Online" or "Generator offline")
  end
  setOnline(identity.connected)
  applyRecord(record)
  updateIcon()
  publishPage()
end

--- The account hands over the generator's alerts and event log.
--- @param idBinding integer
--- @param _strCommand string
--- @param tParams table { ALERTS = JSON, EVENTS = JSON }
function RFP.updateFeeds(idBinding, _strCommand, tParams)
  log:trace("RFP.updateFeeds(%s)", idBinding)
  local okA, alerts = pcall(JSON.decode, JSON, (tParams or {}).ALERTS or "")
  local okE, events = pcall(JSON.decode, JSON, (tParams or {}).EVENTS or "")
  if not okA or not okE or type(alerts) ~= "table" or type(events) ~= "table" then
    log:warn("The account sent alerts or events this driver cannot read")
    return
  end
  gAlertsReply, gEventsReply = alerts, events
  applyFeeds(alerts, events)
  updateIcon()
  publishPage()
end

--- A contact output's proxy asks for its state.
--- @param idBinding integer
function RFP.GET_STATE(idBinding)
  log:trace("RFP.GET_STATE(%s)", idBinding)
  if CONTACTS[idBinding] == nil then
    return
  end
  local closed = contactClosed(idBinding)
  if closed ~= nil then
    SendToProxy(idBinding, closed and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
  end
end

--- The generator left the account, or the account is signed out.
--- @param idBinding integer
function RFP.goOffline(idBinding)
  log:trace("RFP.goOffline(%s)", idBinding)
  gIdentity = nil
  C4:UpdateProperty("Driver Status", "Offline")
  setOnline(false)
  updateIcon()
  publishPage()
end

--- A tap on the Navigator button, which the app answers by opening the generator page. It runs
--- nothing.
--- @param idBinding integer
function RFP.SELECT(idBinding)
  log:trace("RFP.SELECT(%s)", idBinding)
end

-- ─── Commands (EC dispatch) ───────────────────────────────────────────────

--- Show a command's progress or result in Driver Status, where readings leave it for a while.
--- @param text string
local function showResult(text)
  gResultUntil = os.time() + RESULT_HOLD_S
  C4:UpdateProperty("Driver Status", text)
end

--- Send a command to the account, which checks it, sends it to KOHLER and answers commandResult
--- with the page's request id, when the generator page sent it.
--- @param command KohlerCommand|table
--- @param request string|nil
local function sendCommand(command, request)
  command.request = request
  if command.action ~= "refresh" then
    showResult("Sending " .. COMMAND_NAMES[command.action] .. "...")
  end
  SendToProxy(ACCOUNT_BINDING, constants.CMD.GENERATOR_COMMAND, { JSON = JSON:encode(command) })
end

--- Starts an exercise now: the engine starts and runs for the scheduled length. Loaded Full Speed
--- also moves the house onto generator power for the exercise.
--- @param tParams table Mode.
--- @param request string|nil The generator page's request id.
function EC.Start_Exercise(tParams, request)
  log:trace("EC.Start_Exercise(%s)", tParams)
  sendCommand({ action = "start", mode = Select(tParams, "Mode") }, request)
end

--- Stops the exercise that is running: the engine cools down and stops.
--- @param _tParams table|nil
--- @param request string|nil The generator page's request id.
function EC.Stop_Exercise(_tParams, request)
  log:trace("EC.Stop_Exercise()")
  sendCommand({ action = "stop" }, request)
end

--- Changes when and how the generator exercises.
--- @param tParams table Frequency, Day, Time, Mode and Minutes.
--- @param request string|nil The generator page's request id.
function EC.Set_Exercise_Schedule(tParams, request)
  log:trace("EC.Set_Exercise_Schedule(%s)", tParams)
  sendCommand({
    action = "schedule",
    frequency = Select(tParams, "Frequency"),
    day = Select(tParams, "Day"),
    time = Select(tParams, "Time"),
    mode = Select(tParams, "Mode"),
    minutes = Select(tParams, "Minutes"),
  }, request)
end

--- Switches a load-shed load on or off.
--- @param tParams table Load and State.
--- @param request string|nil The generator page's request id.
function EC.Set_Load(tParams, request)
  log:trace("EC.Set_Load(%s)", tParams)
  if not loadControlOn() then
    showResult("Load Control is off")
    gLastCommand = { request = request, action = "load", ok = false, message = "Load Control is off" }
    publishPage()
    return
  end
  sendCommand({ action = "load", load = Select(tParams, "Load"), on = Select(tParams, "State") == "On" }, request)
end

--- The loads Set Load offers: this generator's, while Load Control is on.
--- @param paramName string
--- @return string[]
function GCPL.Set_Load(paramName)
  log:trace("GCPL.Set_Load(%s)", paramName)
  if paramName ~= "Load" or not loadControlOn() then
    return {}
  end
  local names = {}
  for _, load in ipairs(Controls.loads(gRecord)) do
    names[#names + 1] = load.name
  end
  return names
end

--- Reads the generator from KOHLER now.
function EC.Refresh()
  log:trace("EC.Refresh()")
  sendCommand({ action = "refresh" })
end

--- The account answers a command.
--- @param idBinding integer
--- @param _strCommand string
--- @param tParams table ACTION, OK, MESSAGE and, for the generator page's command, REQUEST.
function RFP.commandResult(idBinding, _strCommand, tParams)
  log:trace("RFP.commandResult(%s, %s)", idBinding, tParams)
  local action = Select(tParams, "ACTION") or ""
  local name = COMMAND_NAMES[action] or "Command"
  local message = Select(tParams, "MESSAGE") or ""
  local ok = Select(tParams, "OK") == "true"
  if ok then
    log:info("%s sent", name)
    showResult(name .. " sent")
  else
    log:warn("%s not sent: %s", name, message)
    showResult(name .. " not sent: " .. message)
  end
  gLastCommand = { request = Select(tParams, "REQUEST"), action = action, ok = ok, message = message }
  publishPage()
end

-- ─── The generator page ────────────────────────────────────────────────────

--- The page's commands, by the action it sends, each the command programming runs.
local PAGE_COMMANDS = {
  start = function(p, request)
    EC.Start_Exercise({ Mode = p.mode }, request)
  end,
  stop = function(_p, request)
    EC.Stop_Exercise(nil, request)
  end,
  schedule = function(p, request)
    EC.Set_Exercise_Schedule({
      Frequency = p.frequency,
      Day = p.day,
      Time = p.time,
      Mode = p.mode,
      Minutes = p.minutes,
    }, request)
  end,
  load = function(p, request)
    EC.Set_Load({ Load = p.load, State = p.state }, request)
  end,
}

--- A generator page has opened: it gets the state.
--- @param tParams table { page }
function EC.KG_PAGE_HELLO(tParams)
  if gPage ~= nil then
    gPage:hello(tParams)
  end
end

--- An open generator page, every 15 s.
--- @param tParams table { boot, rev }
function EC.KG_PAGE_PING(tParams)
  if gPage ~= nil then
    gPage:ping(tParams)
  end
end

--- A command from the generator page: a button the homeowner pressed and, for Start Exercise,
--- confirmed.
--- @param tParams table { action, request, and the command's own fields: a load's state is "On" or
--- "Off", as Set Load's }
function EC.KG_PAGE_COMMAND(tParams)
  log:trace("EC.KG_PAGE_COMMAND(%s)", tParams)
  local p = type(tParams) == "table" and tParams or {}
  if p.action == "refresh" then
    EC.Refresh()
    return
  end
  local run = PAGE_COMMANDS[p.action or ""]
  if run == nil then
    log:warn("The generator page sent a command this driver does not know: %s", tostring(p.action))
    return
  end
  local request = type(p.request) == "string" and p.request or nil
  if p.action == "load" and p.state ~= "On" and p.state ~= "Off" then
    log:warn("The generator page sent a load state this driver does not know: %s", tostring(p.state))
    return
  end
  run(p, request)
end

EC.suppressDebug.KG_PAGE_PING = true
EC.suppressDebug.KG_PAGE_HELLO = true

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

function OPC.Load_Control(_v)
  if gInitialized then
    persist:set(LOAD_CONTROL_SET_KEY, true)
  end
  if gRecord ~= nil then
    updateLoads(gRecord, Controls.loads(gRecord))
  end
  publishPage()
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
  for _, v in ipairs(VARIABLES) do
    local existing = values:getValue(v[1])
    if existing == nil or existing.deleted then
      values:update(v[1], v[3], v[2])
    end
  end
  gPage = Page.Link:new({
    device = C4:GetDeviceID(),
    boot = C4:UUID("Random"),
    encode = function(value)
      return JSON:encode(value)
    end,
    send = function(command, params)
      C4:SendDataToUI(command, params)
    end,
    getState = function()
      return Page.state({
        identity = gIdentity,
        record = gRecord,
        alerts = gAlertsReply,
        events = gEventsReply,
        now = os.time(),
        scale = scale(),
        loadControl = loadControlOn(),
        lastCommand = gLastCommand,
      })
    end,
  })
  local flags = persist:get(FLAGS_KEY)
  gFlags = type(flags) == "table" and flags or nil
  local told = persist:get(CONTACTS_KEY)
  gToldBefore = type(told) == "table" and told or {}
  gTold = {}
  for _, contact in ipairs(CONTACTS) do
    OBC[contact.id] = function(_idBinding, _strClass, bIsBound)
      local closed = contactClosed(contact.id)
      if bIsBound and closed ~= nil then
        SendToProxy(contact.id, closed and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
      end
    end
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
  gInitialized = true
  updateIcon()
  C4:UpdateProperty("Driver Status", "Waiting for the Kohler Generators driver")
  -- The account answers with the record, or goOffline while it is signed out.
  SendToProxy(ACCOUNT_BINDING, constants.CMD.REFRESH_STATE, {})
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif
