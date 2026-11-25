--- The commands a KOHLER generator takes from Control4: start or stop an exercise, change the
--- exercise schedule, and switch a load-shed load. Checks each against the generator's last record
--- the way the KOHLER app does before it sends anything, and builds the request. Pure: no Control4
--- calls, so the tests run it as it is.

local Generator = require("kohler.generator")
local Status = require("kohler.status")

local M = {}

--- The exercise modes a command offers, as Composer shows them, and as the cloud names them.
M.MODES = {
  ["Unloaded"] = "Unloaded",
  ["Unloaded Full Speed"] = "UnloadedFullSpeed",
  ["Loaded Full Speed"] = "LoadedFullSpeed",
}

--- The exercise frequencies, as Composer shows them, and as the cloud names them.
M.FREQUENCIES = {
  ["Weekly"] = "Weekly",
  ["Every Other Week"] = "EveryOtherWeek",
  ["Monthly"] = "Monthly",
}

--- Day names by os.date's wday, 1 for Sunday.
M.DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }

--- The exercise lengths the cloud takes, in minutes.
M.MIN_MINUTES = 5
M.MAX_MINUTES = 60

--- @param record table
--- @return table device
local function deviceOf(record)
  return type(record.device) == "table" and record.device or {}
end

--- The load-shed loads a record lists, empty without a connected load control module.
--- @param record table|nil
--- @return KohlerLoad[]
function M.loads(record)
  if type(record) ~= "table" then
    return {}
  end
  return Status.fromRecord(record, 0, "F").loads
end

--- Whether the record shows a connected load control module.
--- @param record table|nil
--- @return boolean
function M.hasLoadControl(record)
  return type(record) == "table" and type(record.loadShed) == "table" and record.loadShed.isConnected == true
end

--- A time of day as hours and minutes: "14:30", "2:30 PM" or "2:30pm".
--- @param text any
--- @return integer|nil hour
--- @return integer|nil minute
function M.timeOfDay(text)
  if type(text) ~= "string" then
    return nil
  end
  local h, m, ampm = text:upper():match("^%s*(%d%d?):(%d%d)%s*([AP]?M?)%s*$")
  h, m = tonumber(h), tonumber(m)
  if not h or m >= 60 then
    return nil
  end
  if ampm == "AM" or ampm == "PM" then
    if h < 1 or h > 12 then
      return nil
    end
    h = h % 12 + (ampm == "PM" and 12 or 0)
  elseif ampm ~= "" or h > 23 then
    return nil
  end
  return h, m
end

--- The next time a day of the week and time of day comes round, after now, in the controller's time.
--- @param day string A name from M.DAYS.
--- @param hour integer
--- @param minute integer
--- @param now integer Epoch seconds.
--- @return integer|nil epoch Nil for a day name M.DAYS doesn't have.
function M.nextStart(day, hour, minute, now)
  local wday
  for i, name in ipairs(M.DAYS) do
    if name == day then
      wday = i
    end
  end
  if not wday then
    return nil
  end
  local t = os.date("*t", now)
  local ahead = (wday - t.wday) % 7
  local function at(days)
    return os.time({ year = t.year, month = t.month, day = t.day + days, hour = hour, min = minute, sec = 0 })
  end
  local start = at(ahead)
  if start <= now then
    start = at(ahead + 7)
  end
  return start
end

--- A time in the form the generator's record last used for its next exercise: with Z, with an
--- offset, or local with neither. Local with neither when the record had none.
--- @param epoch integer
--- @param lastRead any The record's exercise.nextStartTimestamp.
--- @return string
function M.timestamp(epoch, lastRead)
  local rest = type(lastRead) == "string" and lastRead:match("T%d%d:%d%d:%d%d%.?%d*(.*)$") or ""
  if rest == "Z" then
    return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
  end
  local localTime = os.date("%Y-%m-%dT%H:%M:%S", epoch)
  if rest == "" then
    return localTime
  end
  local utc = os.date("!*t", epoch)
  -- Read the UTC fields as local time with the DST flag the moment has, not one mktime guesses.
  utc.isdst = os.date("*t", epoch).isdst
  local offset = math.floor((epoch - os.time(utc)) / 60)
  local sign = offset < 0 and "-" or "+"
  offset = math.abs(offset)
  return string.format("%s%s%02d:%02d", localTime, sign, math.floor(offset / 60), offset % 60)
end

--- @class KohlerCommand
--- @field action "start"|"stop"|"schedule"|"load"
--- @field mode? string Start and schedule: a name from M.MODES.
--- @field frequency? string Schedule: a name from M.FREQUENCIES.
--- @field day? string Schedule: a name from M.DAYS.
--- @field time? string Schedule: a time of day.
--- @field minutes? integer|string Schedule: the exercise's length.
--- @field load? string Load: the load's name, as the record lists it.
--- @field on? boolean Load: on or off.

--- @class KohlerRequest
--- @field method "POST"|"PUT"
--- @field path string Below the API's base.
--- @field body? table Nil for a call that sends none.

--- Checks a command against the generator's last record and builds its request. Refuses as the
--- KOHLER app does: nothing while the generator is offline; no exercise start while the utility is
--- out, the engine runs, the switch is not in Auto or the generator is not ready to run; no stop
--- without an exercise running.
--- @param command KohlerCommand
--- @param record table|nil The generator's last record.
--- @param now integer Epoch seconds.
--- @return KohlerRequest|nil request
--- @return string|nil refusal Why it was refused, for the Driver Status.
function M.request(command, record, now)
  if type(record) ~= "table" then
    return nil, "Waiting for the generator's first reading"
  end
  local device = deviceOf(record)
  local id = tostring(device.id)
  local s = Status.fromRecord(record, now, "F")
  if not s.online then
    return nil, "The generator is offline"
  end
  local action = command.action
  if action == "start" then
    local mode = M.MODES[command.mode or ""]
    if not mode then
      return nil, "Choose an exercise mode"
    end
    if s.utilityOut or s.onGeneratorPower then
      return nil, "Utility power is out"
    end
    if s.running or s.exercising then
      return nil, "The generator is already running"
    end
    if not s.inAuto then
      return nil, "The generator's switch is not in Auto"
    end
    if device.status ~= "ReadyToRun" then
      return nil, "The generator is not ready to run (" .. Generator.label(device.status) .. ")"
    end
    return { method = "POST", path = "/devices/" .. id .. "/exercise/start", body = { mode = mode } }
  elseif action == "stop" then
    if not s.exercising then
      return nil, "No exercise is running"
    end
    return { method = "POST", path = "/devices/" .. id .. "/exercise/stop" }
  elseif action == "schedule" then
    local frequency = M.FREQUENCIES[command.frequency or ""]
    local mode = M.MODES[command.mode or ""]
    local hour, minute = M.timeOfDay(command.time)
    local minutes = tonumber(command.minutes)
    if not frequency then
      return nil, "Choose how often the generator exercises"
    end
    if not mode then
      return nil, "Choose an exercise mode"
    end
    if not hour then
      return nil, "Enter the time as 10:00 or 10:00 AM"
    end
    if not minutes or minutes % 1 ~= 0 or minutes < M.MIN_MINUTES or minutes > M.MAX_MINUTES then
      return nil, string.format("Exercise for %d to %d minutes", M.MIN_MINUTES, M.MAX_MINUTES)
    end
    local start = M.nextStart(command.day or "", hour, minute, now)
    if not start then
      return nil, "Choose a day of the week"
    end
    local exercise = type(record.exercise) == "table" and record.exercise or {}
    return {
      method = "PUT",
      path = "/devices/" .. id .. "/exercise",
      body = {
        frequency = frequency,
        nextStartTimestamp = M.timestamp(start, exercise.nextStartTimestamp),
        mode = mode,
        durationMinutes = math.floor(minutes),
      },
    }
  elseif action == "load" then
    if type(command.load) ~= "string" or command.load == "" then
      return nil, "Choose a load"
    end
    if not M.hasLoadControl(record) then
      return nil, "The generator has no load control module"
    end
    for _, load in ipairs(s.loads) do
      if load.name == command.load then
        return {
          method = "POST",
          path = "/devices/" .. id .. "/peripherals/" .. tostring(load.id) .. "/set_value",
          body = { value = command.on == true },
        }
      end
    end
    return nil, "The generator has no load named " .. tostring(command.load)
  end
  return nil, "Unknown command"
end

return M
