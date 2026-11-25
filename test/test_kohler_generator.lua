-- kohler.generator: a generator's identity and the cloud's quirks, read from the replies the mock
-- writes to test/fixtures/kohler (make kohler-fixtures).
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_kohler_generator.lua

local T = require("testlib")
local JSON = require("JSON")
local Generator = require("kohler.generator")

--- @param name string
--- @return table
local function fixture(name)
  local file = assert(io.open("fixtures/kohler/" .. name, "r"))
  local body = file:read("*a")
  file:close()
  return JSON:decode(body)
end

T.section("homeowner/homes lists every generator with its home")
local list = Generator.fromHomes(fixture("demo-homes.json"))
T.eq("three generators", #list, 3)
T.eq(
  "in the app's order",
  list[1].name .. "|" .. list[2].name .. "|" .. list[3].name,
  "Demo Generator|Demo Standby 48|Demo Cabin Generator"
)
T.eq("each with its home", list[3].home, "Demo Cabin")
T.eq("the id", list[1].id, 58001)
T.eq("the serial", list[1].serial, "DEMO000001")
T.eq("the model as the app shows it", list[1].model, "20 KW")
T.eq("the controller", list[3].controller, "RDC2 (Red or Green Board)")
T.eq("the firmware", list[1].firmware, "3.9.2")
T.eq("the reads' host", list[1].host, "Oncue")
T.eq("connected", list[1].connected, true)
T.eq("a homes entry has no fuel", list[1].fuel, "")
T.eq("the dealer's name and phone", list[1].dealer, "Example Power Co., (555) 555-0142")

T.section("the MAC address is put the right way round")
T.eq("homes entry", list[1].mac, "02:00:00:00:A1:01")
T.eq("a record", Generator.identity(fixture("device-58003.json")).mac, "02:00:00:00:A1:03")
T.eq("lower case reads the same", Generator.mac("01:a1:00:00:00:02"), "02:00:00:00:A1:01")
T.eq("not six bytes", Generator.mac("01:A1:00"), "")
T.eq("nothing", Generator.mac(nil), "")

T.section("a device record carries what a homes entry does not")
local record = Generator.identity(fixture("device-58001.json"))
T.eq("the id", record.id, 58001)
T.eq("fuel", record.fuel, "Natural Gas")
T.eq("connection", record.connection, "Ethernet")
T.eq("propane", Generator.identity(fixture("device-58003.json")).fuel, "Liquid Propane")
T.eq("an offline generator", Generator.identity(fixture("device-58004.json")).connected, false)

T.section("timestamps: Z, an offset, seven-digit fractions and local time")
T.eq("Z", Generator.time("2026-09-26T15:00:00Z"), 1790434800)
T.eq("+00:00", Generator.time("2026-09-26T15:00:00+00:00"), 1790434800)
T.eq("an offset", Generator.time("2026-09-26T10:00:00-05:00"), 1790434800)
T.eq("seven digits of fraction", Generator.time("2026-09-26T15:00:00.1234567+00:00"), 1790434800)
T.eq(
  "no offset is the controller's local time",
  Generator.time("2026-11-25T07:13:20"),
  os.time({ year = 2026, month = 11, day = 25, hour = 7, min = 13, sec = 20 })
)
local cabin = fixture("device-58003.json")
T.eq(
  "a naive maintenance date reads",
  Generator.time(cabin.device.nextMaintenanceTimestamp),
  os.time({ year = 2026, month = 11, day = 25, hour = 7, min = 13, sec = 20 })
)
T.eq("a leap day", Generator.time("2028-02-29T00:00:00Z"), 1835395200)
T.eq("not a time", Generator.time("yesterday"), nil)
T.eq("a bad offset", Generator.time("2026-09-26T15:00:00+5"), nil)
T.eq("nothing", Generator.time(nil), nil)

T.section("readings")
T.eq("load comes negative and reads positive", Generator.load(-4250.5), 4250.5)
T.eq("a positive load stays", Generator.load(12), 12)
T.eq("no load reading", Generator.load(nil), nil)
T.eq("a number", Generator.number("13.6"), 13.6)
T.eq("not a number", Generator.number("n/a"), nil)
T.eq("NaN is none", Generator.number(0 / 0), nil)

T.section("enumerations read as words")
T.eq("split at capitals", Generator.label("ReadyToRun"), "Ready To Run")
T.eq("a known word", Generator.label("KohlerWifi"), "KOHLER Wi-Fi")
T.eq("nothing", Generator.label(nil), "")

T.section("a record without an id is not a generator")
T.eq("no id", Generator.identity({ device = { displayName = "x" } }), nil)
T.eq("not a table", Generator.identity("x"), nil)
T.eq("a homes reply that is not a list", #Generator.fromHomes("x"), 0)
T.eq("a nameless generator gets one", Generator.identity({ id = 7 }).name, "KOHLER Generator 7")

T.finish()
