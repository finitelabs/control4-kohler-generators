--- A KOHLER generator record, as the homeowner API sends it: the fields both drivers read, with
--- the cloud's own quirks undone. Pure: no Control4 calls, so the tests run it as it is.
---
--- The record is GET devices/{id}: the generator's identity under `device`, its readings beside it.
--- homeowner/homes lists the same identity for each generator in a home.

local M = {}

--- The largest clock offset from UTC a generator can report, in seconds.
local MAX_CLOCK_OFFSET_S = 14 * 3600

--- Words a vendor enumeration splits into, where splitting at capitals reads wrong.
local NAMES = {
  NaturalGas = "Natural Gas",
  LiquidPropane = "Liquid Propane",
  Gasoline = "Gasoline",
  Diesel = "Diesel",
  UnknownUndefined = "Unknown",
  Ethernet = "Ethernet",
  KohlerWifi = "KOHLER Wi-Fi",
  OtherWifi = "Wi-Fi",
  Cellular = "Cellular",
  KohlerCellKit = "KOHLER Cellular Kit",
}

--- A vendor enumeration as text: "SwitchStateOff" reads "Switch State Off".
--- @param value any
--- @return string text "" for nil or a non-string.
function M.label(value)
  if type(value) ~= "string" then
    return ""
  end
  if NAMES[value] then
    return NAMES[value]
  end
  return (value:gsub("(%l)(%u)", "%1 %2"))
end

--- The MAC address the right way round: the cloud sends its bytes reversed.
--- @param mac any
--- @return string mac "" when it is not six bytes.
function M.mac(mac)
  if type(mac) ~= "string" then
    return ""
  end
  local bytes = {}
  for byte in mac:gmatch("%x%x") do
    table.insert(bytes, 1, byte:upper())
  end
  if #bytes ~= 6 then
    return ""
  end
  return table.concat(bytes, ":")
end

--- Days from 1970-01-01 to a civil date in the proleptic Gregorian calendar.
--- @param y integer
--- @param m integer
--- @param d integer
--- @return integer days
local function daysFromCivil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- A timestamp as epoch seconds. The cloud writes them three ways: with Z, with an offset, or
--- with neither, which is the generator's local time. The generator's clock offset reads that one;
--- without it the controller's time zone stands in. Fractions of a second, of any length, are
--- dropped. A generator whose clock was never set counts from 2011-01-01, so a time before 2012 is
--- no time at all.
--- @param value any
--- @param clockOffset? integer The generator's clock offset from UTC in seconds, from M.clockOffset.
--- @return integer|nil epoch Nil for anything else.
function M.time(value, clockOffset)
  if type(value) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s, rest = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
  if not y or tonumber(y) < 2012 then
    return nil
  end
  rest = rest:gsub("^%.%d+", "")
  local fields = { tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s) }
  if rest == "" and clockOffset == nil then
    return os.time({
      year = fields[1],
      month = fields[2],
      day = fields[3],
      hour = fields[4],
      min = fields[5],
      sec = fields[6],
    })
  end
  local offset = rest == "" and clockOffset or 0
  if rest ~= "" and rest ~= "Z" then
    local sign, oh, om = rest:match("^([%+%-])(%d%d):?(%d%d)$")
    if not sign then
      return nil
    end
    offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
  end
  local days = daysFromCivil(fields[1], fields[2], fields[3])
  return days * 86400 + fields[4] * 3600 + fields[5] * 60 + fields[6] - offset
end

--- The generator's clock offset from UTC, in seconds. A generator keeps its own clock, which needn't
--- follow the controller's time zone or its daylight saving, and writes its local times by it. The
--- record carries a reading of that clock and the moment the record was taken; their difference,
--- rounded to 15 minutes, is the offset.
--- @param record any The full record (devices/{id}).
--- @return integer|nil offset Nil when the record has no clock reading to tell.
function M.clockOffset(record)
  if type(record) ~= "table" or type(record.device) ~= "table" then
    return nil
  end
  local taken = record.device.latestParameterUpdateTimestamp
  if type(taken) ~= "string" or taken:match("T[%d:%.]+$") then
    return nil
  end
  local clock, at = M.time(record.controllerClockTimestamp, 0), M.time(taken)
  if clock == nil or at == nil then
    return nil
  end
  local offset = math.floor((clock - at) / 900 + 0.5) * 900
  if math.abs(offset) > MAX_CLOCK_OFFSET_S then
    return nil
  end
  return offset
end

--- A reading as a number, or nil when the cloud has none.
--- @param value any
--- @return number|nil value
function M.number(value)
  local n = tonumber(value)
  if n == nil or n ~= n or n == math.huge or n == -math.huge then
    return nil
  end
  return n
end

--- A load reading: the cloud sends load as a negative number.
--- @param value any
--- @return number|nil value
function M.load(value)
  local n = M.number(value)
  return n and math.abs(n) or nil
end

--- @class KohlerIdentity
--- @field id integer The generator's id in the KOHLER cloud.
--- @field name string Its name in Control4: its name in the app, or "KOHLER <model>" when the app's name is
--- empty or only its serial number.
--- @field kohlerName string Its name in the app, as the app has it.
--- @field serial string
--- @field model string As the app shows it, such as "20 KW".
--- @field controller string The controller board.
--- @field firmware string
--- @field fuel string "" when the record has none.
--- @field connection string "" when the record has none.
--- @field dealer string The dealer's name and phone number, "" when there is none.
--- @field host string The telemetry backend its reads name, as `sourceDeviceHost`.
--- @field connected boolean Whether the cloud hears from the generator.
--- @field mac string
--- @field home? string The home the app lists it under; set only by M.fromHomes.

--- The device part of a record, or the record itself when it is a homes entry.
--- @param record table
--- @return table device
local function deviceOf(record)
  return type(record.device) == "table" and record.device or record
end

--- @param value any
--- @return string
local function text(value)
  return type(value) == "string" and value or ""
end

--- A name as it compares: lowercase, without spaces.
--- @param value string
--- @return string
local function bare(value)
  return (value:lower():gsub("%s", ""))
end

--- A generator's identity, from a record or a homes entry.
--- @param record any
--- @return KohlerIdentity|nil identity Nil when the record carries no id.
function M.identity(record)
  if type(record) ~= "table" then
    return nil
  end
  local device = deviceOf(record)
  local id = tonumber(device.id)
  if id == nil or id ~= math.floor(id) then
    return nil
  end
  local dealer = ""
  local orgs = record.dealerOrgs or device.dealerOrgs
  if type(orgs) == "table" and type(orgs[1]) == "table" then
    local name, phone = text(orgs[1].name), text(orgs[1].displayPhoneNumber)
    dealer = (name ~= "" and phone ~= "") and (name .. ", " .. phone) or (name .. phone)
  end
  local kohlerName = text(device.displayName)
  local serial = text(device.serialNumber)
  local model = text(device.modelDisplayName) ~= "" and device.modelDisplayName or text(device.model)
  local name = kohlerName
  if bare(name) == "" or bare(name) == bare(serial) then
    name = model ~= "" and ("KOHLER " .. model) or ("KOHLER Generator " .. tostring(id))
  end
  return {
    id = id,
    name = name,
    kohlerName = kohlerName,
    serial = serial,
    model = model,
    controller = text(device.controllerType),
    firmware = text(device.firmwareVersion),
    fuel = M.label(record.fuelType),
    connection = M.label(record.connectionType),
    dealer = dealer,
    host = text(device.deviceHost) ~= "" and device.deviceHost or "Oncue",
    connected = device.isConnected == true,
    mac = M.mac(device.macAddress),
  }
end

--- Every generator in a homeowner/homes reply, in the order the app lists them.
--- @param homes any
--- @return KohlerIdentity[] generators
function M.fromHomes(homes)
  local list = {}
  for _, home in ipairs(type(homes) == "table" and homes or {}) do
    for _, device in ipairs(type(home) == "table" and type(home.devices) == "table" and home.devices or {}) do
      local identity = M.identity(device)
      if identity then
        identity.home = text(home.name)
        list[#list + 1] = identity
      end
    end
  end
  return list
end

return M
