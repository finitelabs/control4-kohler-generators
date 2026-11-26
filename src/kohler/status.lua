--- What a KOHLER generator record, its alerts and its events say about the generator: power,
--- engine, switch, readings, exercise and service, and what changed between two reads. Pure but for
--- remembering, persisted, which generators sense utility voltage.

local Generator = require("kohler.generator")
local persist = require("lib.persist")

local M = {}

--- Engine states in which the engine turns. A state the list doesn't know counts as not running.
local RUNNING = {
  CrankOn = true,
  CrankPause = true,
  Idle = true,
  Running = true,
  CoolDown = true,
}

--- Below this a utility voltage reading means the utility is out.
local UTILITY_OUT_V = 100
--- Persist key: the generators that have reported a utility voltage of at least UTILITY_OUT_V, by id.
local SENSED_PERSIST_KEY = "UtilitySensed"

--- Alert and event levels that mean a fault.
local FAULT_LEVELS = { Fault = true, Shutdown = true }

--- The event the generator logs when its battery is low.
M.LOW_BATTERY_EVENT = "Low Battery Voltage"

--- The readings' names, each a NUMBER variable that has no value while the generator doesn't report it.
M.READINGS = {
  "Utility Voltage",
  "Generator Voltage",
  "Load Watts",
  "Load Percent",
  "Frequency",
  "Engine RPM",
  "Battery Voltage",
  "Controller Temperature",
  "Lube Oil Temperature",
  "Coolant Temperature",
  "Runtime Hours",
  "Operation Hours",
  "Hours Since Maintenance",
}

local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }

local FREQUENCIES = { Weekly = "Weekly", EveryOtherWeek = "Every other week", Monthly = "Monthly" }

local MODES = {
  Unloaded = "Unloaded",
  UnloadedFullSpeed = "Unloaded full speed",
  LoadedFullSpeed = "Loaded full speed",
  EcoExercise = "Eco",
}

--- @param engineState any
--- @return boolean
local function isRunning(engineState)
  if type(engineState) ~= "string" then
    return false
  end
  return RUNNING[engineState] == true or engineState:find("^Performing") ~= nil
end

--- @param record table
--- @return table device
local function deviceOf(record)
  return type(record.device) == "table" and record.device or {}
end

--- A date and time as the controller shows it, "" for none.
--- @param epoch integer|nil
--- @return string text
function M.formatTime(epoch)
  if epoch == nil then
    return ""
  end
  return os.date("%Y-%m-%d %H:%M", epoch)
end

--- The exercise schedule as one line: "Weekly, Tuesday 10:00, Unloaded, 20 minutes".
--- @param exercise any The record's exercise part.
--- @param clockOffset? integer The generator's clock offset, from Generator.clockOffset.
--- @return string schedule "None" when no exercise is scheduled.
function M.schedule(exercise, clockOffset)
  if type(exercise) ~= "table" or type(exercise.frequency) ~= "string" then
    return "None"
  end
  local parts = { FREQUENCIES[exercise.frequency] or Generator.label(exercise.frequency) }
  local nextStart = Generator.time(exercise.nextStartTimestamp, clockOffset)
  if nextStart then
    local t = os.date("*t", nextStart)
    parts[#parts + 1] = string.format("%s %02d:%02d", DAYS[t.wday], t.hour, t.min)
  end
  if type(exercise.mode) == "string" and exercise.mode ~= "None" then
    parts[#parts + 1] = MODES[exercise.mode] or Generator.label(exercise.mode)
  end
  local minutes = Generator.number(exercise.durationMinutes)
  if minutes then
    parts[#parts + 1] = string.format("%d minutes", minutes)
  end
  return table.concat(parts, ", ")
end

--- A Fahrenheit reading in the scale the project shows.
--- @param f number|nil
--- @param scale string "C" or "F".
--- @return number|nil
local function temperature(f, scale)
  if f == nil then
    return nil
  end
  if scale == "C" then
    return math.floor((f - 32) * 5 / 9 * 10 + 0.5) / 10
  end
  return f
end

--- @class KohlerLoad
--- @field id integer The load's definitionId.
--- @field name string As the app names it, such as "HVAC A".
--- @field on boolean

--- @class KohlerStatus
--- @field online boolean
--- @field status string The generator's status as text, such as "Ready To Run".
--- @field engineState string
--- @field powerSource string
--- @field onGeneratorPower boolean
--- @field utilityOut boolean
--- @field running boolean
--- @field exercising boolean
--- @field switchPosition string
--- @field inAuto boolean
--- @field shutDown boolean The generator reports it is shut down.
--- @field oilPressureOk boolean|nil Nil when the controller doesn't report it.
--- @field readings table<string, number|boolean|nil> Variable name to reading, nil where none.
--- @field lastRan string
--- @field nextExercise string
--- @field lastMaintenance string
--- @field nextMaintenance string
--- @field maintenanceDue boolean
--- @field exerciseSchedule string
--- @field loads KohlerLoad[] Empty without a load control module.

--- Whether a generator's utility voltage can be trusted: one that doesn't sense utility reports 0
--- volts, so it counts only once the generator has reported a live line.
--- @param id any The generator's id.
--- @param utilityV number
--- @return boolean
local function sensesUtility(id, utilityV)
  if utilityV >= UTILITY_OUT_V then
    if id ~= nil then
      local sensed = persist:get(SENSED_PERSIST_KEY, {}) or {}
      if not sensed[tostring(id)] then
        sensed[tostring(id)] = true
        persist:set(SENSED_PERSIST_KEY, sensed)
      end
    end
    return true
  end
  return id ~= nil and (persist:get(SENSED_PERSIST_KEY, {}) or {})[tostring(id)] == true
end

--- The generator's state from its record.
--- @param record table The full record (devices/{id}).
--- @param now integer Epoch seconds.
--- @param scale string The project's temperature scale, "C" or "F".
--- @return KohlerStatus status
function M.fromRecord(record, now, scale)
  local device = deviceOf(record)
  local n = Generator.number
  local utilityV = n(record.utilityVoltageV)
  local power = type(record.powerSource) == "string" and record.powerSource or ""
  local exercise = type(record.exercise) == "table" and record.exercise or {}
  local runningMode = exercise.runningMode
  local engine = record.engineState
  local exercising = device.status == "RunningExercise"
    or (type(runningMode) == "string" and runningMode ~= "None")
    or (type(engine) == "string" and engine:find("^Performing.*Exercise$") ~= nil)
  local utilitySensed = utilityV ~= nil and sensesUtility(device.id, utilityV)
  local utilityOut
  if utilitySensed then
    utilityOut = utilityV < UTILITY_OUT_V
  else
    utilityOut = power == "Generator" and not exercising
  end
  local clockOffset = Generator.clockOffset(record)
  local nextMaint = Generator.time(device.nextMaintenanceTimestamp, clockOffset)
  local engineText = type(record.engineStateDisplayNameEn) == "string" and record.engineStateDisplayNameEn
    or Generator.label(engine)
  local oilOk = record.engineOilPressureOk
  if type(oilOk) ~= "boolean" then
    oilOk = nil
  end
  local loads = {}
  local shed = record.loadShed
  if type(shed) == "table" and shed.isConnected == true and type(shed.parameters) == "table" then
    for _, p in ipairs(shed.parameters) do
      if type(p) == "table" and tonumber(p.definitionId) and type(p.displayName) == "string" then
        loads[#loads + 1] = { id = tonumber(p.definitionId), name = p.displayName, on = p.value == true }
      end
    end
  end
  return {
    online = device.isConnected == true,
    status = Generator.label(device.status),
    engineState = engineText,
    powerSource = Generator.label(power),
    onGeneratorPower = power == "Generator",
    utilityOut = utilityOut,
    running = isRunning(engine),
    exercising = exercising,
    switchPosition = Generator.label(record.switchState),
    inAuto = record.switchState == "Auto",
    shutDown = device.status == "Shutdown" or engine == "Shutdown",
    readings = {
      ["Utility Voltage"] = utilitySensed and utilityV or nil,
      ["Generator Voltage"] = n(record.generatorVoltageAvgV),
      ["Load Watts"] = Generator.load(record.generatorLoadW),
      ["Load Percent"] = Generator.load(record.generatorLoadPercent),
      ["Frequency"] = n(record.engineFrequencyHz),
      ["Engine RPM"] = n(record.engineSpeedRpm),
      ["Battery Voltage"] = n(record.batteryVoltageV),
      ["Controller Temperature"] = temperature(n(record.controllerTempF), scale),
      ["Lube Oil Temperature"] = temperature(n(record.lubeOilTempF), scale),
      ["Coolant Temperature"] = temperature(n(record.engineCoolantTempF), scale),
      ["Runtime Hours"] = n(record.totalRuntimeHours),
      ["Operation Hours"] = n(record.totalOperationHours),
      ["Hours Since Maintenance"] = n(record.runtimeSinceLastMaintenanceHours),
    },
    oilPressureOk = oilOk,
    lastRan = M.formatTime(Generator.time(record.lastRanTimestamp, clockOffset)),
    nextExercise = M.formatTime(Generator.time(exercise.nextStartTimestamp, clockOffset)),
    lastMaintenance = M.formatTime(Generator.time(device.lastMaintenanceTimestamp, clockOffset)),
    nextMaintenance = M.formatTime(nextMaint),
    maintenanceDue = nextMaint ~= nil and nextMaint <= now,
    exerciseSchedule = M.schedule(record.exercise, clockOffset),
    loads = loads,
  }
end

--- Forgets which generators sense utility voltage, as on a fresh install.
function M.reset()
  persist:set(SENSED_PERSIST_KEY, nil)
end

--- Whether the generator needs the fast poll: its engine runs or the utility is out.
--- @param record any
--- @return boolean busy
function M.busy(record)
  if type(record) ~= "table" then
    return false
  end
  local s = M.fromRecord(record, 0, "F")
  return s.online and (s.running or s.utilityOut or s.onGeneratorPower)
end

--- The Navigator icon for the generator's state, as a driver.xml state id, and its description.
--- Offline comes first, then a fault, the utility out, an exercise, and a run; otherwise standby.
--- Before the first record since start-up it is offline, whatever Online was restored as.
--- @param online boolean
--- @param status KohlerStatus|nil Nil before the first record.
--- @param fault boolean
--- @return string id
--- @return string description
function M.icon(online, status, fault)
  if not online or status == nil then
    return "offline", "Offline"
  elseif fault then
    return "fault", "Fault"
  elseif status.utilityOut then
    return "utility_out", "Utility power out"
  elseif status.exercising then
    return "exercising", "Exercising"
  elseif status.running then
    return "running", "Running"
  end
  return "standby", "Standby"
end

--- @class KohlerAlerts
--- @field count integer Active alerts, leaving out notices such as Not Connected.
--- @field last string The newest one's name, "" for none.
--- @field fault boolean One of them is a fault.

--- The generator's active alerts.
--- @param alerts any The alerts reply.
--- @return KohlerAlerts alerts
function M.alerts(alerts)
  local result = { count = 0, last = "", fault = false }
  local newest
  for _, a in ipairs(type(alerts) == "table" and alerts or {}) do
    if type(a) == "table" and a.level ~= "None" then
      result.count = result.count + 1
      if a.isCriticalFault == true or FAULT_LEVELS[a.level] then
        result.fault = true
      end
      local id = tonumber(a.id) or 0
      if newest == nil or id > newest then
        newest = id
        result.last = type(a.event) == "string" and a.event or Generator.label(a.name)
      end
    end
  end
  return result
end

--- @class KohlerNews
--- @field fault boolean A new fault was logged.
--- @field warning boolean A new warning was logged.
--- @field lowBattery boolean A new low battery warning was logged.

--- What the event log holds after `cursor`.
--- @param events any The events reply.
--- @param cursor number|nil The highest event id already seen; nil when no log was ever read.
--- @param since integer|nil Only events logged at or after this epoch count.
--- @return KohlerNews news
--- @return number cursor The highest event id now seen; 0 for a log read empty. Ids that start
--- again below the cursor, as after a generator is replaced, become the cursor and are not news.
function M.news(events, cursor, since)
  local news = { fault = false, warning = false, lowBattery = false }
  local highest = cursor or 0
  local newest
  for _, e in ipairs(type(events) == "table" and events or {}) do
    local id = type(e) == "table" and tonumber(e.id) or nil
    if id and (newest == nil or id > newest) then
      newest = id
    end
  end
  if cursor ~= nil and newest ~= nil and newest < cursor then
    return news, newest
  end
  for _, e in ipairs(type(events) == "table" and events or {}) do
    local id = type(e) == "table" and tonumber(e.id) or nil
    if id then
      if id > highest then
        highest = id
      end
      local at = Generator.time(e.timestamp)
      local fresh = cursor ~= nil and id > cursor and (since == nil or (at ~= nil and at >= since))
      if fresh then
        if FAULT_LEVELS[e.level] or e.isCriticalFault == true then
          news.fault = true
        elseif e.level == "Warning" then
          news.warning = true
        end
        if e.event == M.LOW_BATTERY_EVENT then
          news.lowBattery = true
        end
      end
    end
  end
  return news, highest
end

--- The named transitions between two states of the generator, in the order they happen.
--- @param was table|nil The flags at the last read; nil on the first read since start-up.
--- @param now table The flags now: utilityOut, running, exercising, inAuto, maintenanceDue.
--- @return string[] transitions Event names.
function M.transitions(was, now)
  if was == nil then
    return {}
  end
  local out = {}
  local function edge(key, on, off)
    if now[key] and not was[key] and on then
      out[#out + 1] = on
    elseif was[key] and not now[key] and off then
      out[#out + 1] = off
    end
  end
  edge("utilityOut", "Utility Power Lost", "Utility Power Restored")
  edge("exercising", "Exercise Started", nil)
  edge("running", "Engine Started", "Engine Stopped")
  edge("exercising", nil, "Exercise Ended")
  edge("inAuto", "Switch Back In Auto", "Switch Not In Auto")
  edge("maintenanceDue", "Maintenance Due", nil)
  return out
end

return M
