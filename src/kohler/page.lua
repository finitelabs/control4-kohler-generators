--- The generator page's state, and the driver's half of its link with the page. How the two talk is
--- described with the page's half, in drivers/kohler_generator/www/dist/bridge.js. The state is
--- built from the generator's last record, alerts and event log; pure but for the link's clock, so
--- the tests run it as it is.

local Controls = require("kohler.controls")
local Generator = require("kohler.generator")
local Status = require("kohler.status")

local M = {}

M.STATE_COMMAND = "KG_PAGE_STATE"

--- Pages ping every 15 s. While none has been heard from for three pings, a change isn't sent.
local PAGE_TIMEOUT_S = 45

--- How many of the event log's newest entries the page lists.
local HISTORY_SIZE = 20

--- The readings the page shows, in its order, by the variable each comes from.
local READINGS = {
  { "utilityVoltage", "Utility Voltage" },
  { "generatorVoltage", "Generator Voltage" },
  { "loadWatts", "Load Watts" },
  { "loadPercent", "Load Percent" },
  { "frequency", "Frequency" },
  { "engineRpm", "Engine RPM" },
  { "batteryVoltage", "Battery Voltage" },
  { "controllerTemperature", "Controller Temperature" },
  { "lubeOilTemperature", "Lube Oil Temperature" },
  { "coolantTemperature", "Coolant Temperature" },
  { "runtimeHours", "Runtime Hours" },
  { "operationHours", "Operation Hours" },
}

--- The cloud's exercise frequencies and modes, as the commands name them.
local FREQUENCY_NAMES = {}
for name, cloud in pairs(Controls.FREQUENCIES) do
  FREQUENCY_NAMES[cloud] = name
end
local MODE_NAMES = {}
for name, cloud in pairs(Controls.MODES) do
  MODE_NAMES[cloud] = name
end

--- @param list any
--- @return table[]
local function entries(list)
  local out = {}
  for _, item in ipairs(type(list) == "table" and list or {}) do
    if type(item) == "table" then
      out[#out + 1] = item
    end
  end
  return out
end

--- One alert or logged event as the page lists it.
--- @param item table
--- @return table
local function entry(item)
  local name = type(item.event) == "string" and item.event or Generator.label(item.name)
  return {
    id = tonumber(item.id),
    name = name,
    level = type(item.level) == "string" and item.level or "",
    at = Generator.time(item.timestamp),
  }
end

--- The schedule sheet's starting values, from the generator's exercise.
--- @param exercise table
--- @return table
local function scheduleOf(exercise)
  local at = Generator.time(exercise.nextStartTimestamp)
  local t = at and os.date("*t", at) or nil
  return {
    frequency = FREQUENCY_NAMES[exercise.frequency] or "Weekly",
    day = t and Controls.DAYS[t.wday] or "Tuesday",
    time = t and string.format("%02d:%02d", t.hour, t.min) or "10:00",
    mode = MODE_NAMES[exercise.mode] or "Unloaded",
    minutes = Generator.number(exercise.durationMinutes) or 20,
  }
end

--- Why a command is refused now, or nil when it would be sent.
--- @param command table
--- @param record table
--- @param now integer
--- @return string|nil
local function refusal(command, record, now)
  local _, why = Controls.request(command, record, now)
  return why
end

--- @class KohlerPageContext
--- @field identity KohlerIdentity|nil The generator as the account last handed it; nil while signed out.
--- @field record table|nil Its last record.
--- @field alerts table|nil Its last alerts reply.
--- @field events table|nil Its last event log.
--- @field now integer Epoch seconds.
--- @field scale string "C" or "F".
--- @field loadControl boolean Whether the Load Control property is On.
--- @field lastCommand table|nil The last command the page or programming sent, and its answer.

--- What the page shows.
--- @param ctx KohlerPageContext
--- @return table
function M.state(ctx)
  local record, identity = ctx.record, ctx.identity
  if type(record) ~= "table" or identity == nil then
    return {
      connected = false,
      reason = identity == nil and "account" or "waiting",
      scale = ctx.scale,
      lastCommand = ctx.lastCommand,
    }
  end
  local s = Status.fromRecord(record, ctx.now, ctx.scale)
  local a = Status.alerts(ctx.alerts)
  local device = type(record.device) == "table" and record.device or {}
  local exercise = type(record.exercise) == "table" and record.exercise or {}

  local readings = {}
  for _, r in ipairs(READINGS) do
    local value = s.readings[r[2]]
    if value ~= nil then
      readings[#readings + 1] = { key = r[1], value = value }
    end
  end
  if s.oilPressureOk ~= nil then
    readings[#readings + 1] = { key = "oilPressure", value = s.oilPressureOk }
  end

  local alerts = {}
  for _, item in ipairs(entries(ctx.alerts)) do
    if item.level ~= "None" then
      alerts[#alerts + 1] = entry(item)
    end
  end
  table.sort(alerts, function(x, y)
    return (x.id or 0) > (y.id or 0)
  end)
  local history = {}
  for _, item in ipairs(entries(ctx.events)) do
    history[#history + 1] = entry(item)
  end
  table.sort(history, function(x, y)
    return (x.id or 0) > (y.id or 0)
  end)
  for i = #history, HISTORY_SIZE + 1, -1 do
    history[i] = nil
  end

  local loads = nil
  if ctx.loadControl and Controls.hasLoadControl(record) then
    loads = { items = {}, blocked = not s.online and "The generator is offline" or nil }
    for _, load in ipairs(s.loads) do
      loads.items[#loads.items + 1] = { name = load.name, on = load.on }
    end
  end

  return {
    connected = s.online,
    reason = not s.online and "offline" or nil,
    scale = ctx.scale,
    name = identity.name,
    lastHeard = Generator.time(device.lastConnectedTimestamp),
    top = {
      powerSource = s.powerSource,
      onGeneratorPower = s.onGeneratorPower,
      utilityOut = s.utilityOut,
      status = s.status,
      engineState = s.engineState,
      switchPosition = s.switchPosition,
      inAuto = s.inAuto,
      running = s.running,
      exercising = s.exercising,
      fault = s.shutDown or a.fault,
      reported = Generator.time(device.statusUpdateTimestamp or record.statusUpdateTimestamp),
    },
    readings = readings,
    exercise = {
      schedule = s.exerciseSchedule,
      nextAt = Generator.time(exercise.nextStartTimestamp),
      lastAt = Generator.time(record.lastRanTimestamp),
      running = s.exercising,
      start = refusal({ action = "start", mode = "Unloaded" }, record, ctx.now),
      stop = refusal({ action = "stop" }, record, ctx.now),
      sheet = scheduleOf(exercise),
      scheduleBlocked = not s.online and "The generator is offline" or nil,
    },
    loads = loads,
    alerts = alerts,
    history = history,
    service = {
      lastMaintenanceAt = Generator.time(device.lastMaintenanceTimestamp),
      nextMaintenanceAt = Generator.time(device.nextMaintenanceTimestamp),
      maintenanceDue = s.maintenanceDue,
      hoursSinceMaintenance = s.readings["Hours Since Maintenance"],
      dealer = identity.dealer,
      model = identity.model,
      serial = identity.serial,
      controller = identity.controller,
      firmware = identity.firmware,
      fuel = identity.fuel,
      connection = identity.connection,
    },
    lastCommand = ctx.lastCommand,
  }
end

-- ─── The link ──────────────────────────────────────────────────────────────

--- @class KohlerPageLink
--- @field _boot string Made at each load, so a page left open across a driver reload takes the new state.
--- @field _device string This driver's device id, which a page holds to after its first state.
--- @field _rev integer The state's revision, raised each time it changes.
--- @field _state table|nil The state last sent.
--- @field _sent string|nil The same, encoded, to tell whether it changed.
--- @field _seen integer|nil When a page last said hello or pinged.
--- @field _getState fun(): table
--- @field _send fun(command: string, params: table)
--- @field _now fun(): integer
--- @field _encode fun(value: table): string
local Link = {}
Link.__index = Link

--- @param opts table { getState, send, encode, device, boot?, now? }
--- @return KohlerPageLink
function M.link(opts)
  local self = setmetatable({}, Link)
  self._boot = opts.boot or tostring(math.random(1, 2 ^ 31 - 1))
  self._device = tostring(opts.device)
  self._rev = 0
  self._getState = opts.getState
  self._send = opts.send
  self._encode = opts.encode
  self._now = opts.now or os.time
  return self
end

--- @private
--- @return boolean
function Link:_open()
  return self._seen ~= nil and self._now() - self._seen <= PAGE_TIMEOUT_S
end

--- @private
--- @return boolean changed
function Link:_refresh()
  local state = self._getState()
  local encoded = self._encode(state)
  if encoded == self._sent then
    return false
  end
  self._state, self._sent, self._rev = state, encoded, self._rev + 1
  return true
end

--- @private
--- @param page string|nil The page whose hello this answers.
function Link:_push(page)
  self._send(M.STATE_COMMAND, {
    json = self._encode({
      device = self._device,
      page = page,
      boot = self._boot,
      rev = self._rev,
      state = self._state,
    }),
  })
end

--- Sends open pages the state when it changed since it was last sent.
function Link:publish()
  if self:_open() and self:_refresh() then
    self:_push(nil)
  end
end

--- A page has opened: it gets the state, marked as the answer to its hello.
--- @param params table { page: string }
function Link:hello(params)
  self._seen = self._now()
  self:_refresh()
  local page = type(params) == "table" and params.page or nil
  self:_push(type(page) == "string" and page or nil)
end

--- A page is still open: one holding an older state, or one from before the driver loaded, gets it
--- again.
--- @param params table { boot: string, rev: integer }
function Link:ping(params)
  if not self:_open() then
    self:_refresh()
  end
  self._seen = self._now()
  params = type(params) == "table" and params or {}
  if params.boot ~= self._boot or (tonumber(params.rev) or 0) < self._rev then
    self:_push(nil)
  end
end

return M
