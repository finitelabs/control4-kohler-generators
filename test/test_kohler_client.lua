-- kohler.client against a scripted KOHLER cloud: the password grant and its errors, the refresh
-- grant and its rotating token, a 401 that signs in again once, 429 and 5xx, and the headers
-- every call carries.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_kohler_client.lua

local T = require("testlib")

require("c4_shim")

local constants = require("constants")
constants.CLIENT_ID = "test-client"
constants.CLIENT_SECRET = "test-secret"
constants.API_KEY = "test-api-key"

-- Loaded before urlDo is replaced, which the url module would otherwise redefine.
require("drivers-common-public.global.lib")
require("drivers-common-public.global.url")
local Client = require("kohler.client")

local TOKEN_URL = constants.AUTH_ORIGIN .. constants.TOKEN_PATH
local API = constants.API_ORIGIN .. constants.API_PATH

local now = 1790000000
os.time = function(t)
  return t and 0 or now
end

--- @param body string
--- @return table<string, string>
local function form(body)
  local out = {}
  if type(body) ~= "string" then
    return out
  end
  for pair in (body or ""):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]+)=(.*)$")
    out[k] = v and v:gsub("%%(%x%x)", function(h)
      return string.char(tonumber(h, 16))
    end)
  end
  return out
end

-- ─── Scripted cloud ────────────────────────────────────────────────────────

local requests = {}
--- The answers the next token requests get, in order; then the default.
local tokenAnswers = {}
--- The answers the next API calls get, in order; then 200 with apiBody.
local apiAnswers = {}
local apiBody = { { id = 1, devices = {} } }
local issued = 0

local function issue()
  issued = issued + 1
  return 200, { access_token = "access-" .. issued, refresh_token = "refresh-" .. issued, expires_in = 3600 }, {}
end

urlDo = function(method, url, data, headers, callback, context)
  local entry = { method = method, url = url, data = data, headers = headers, form = form(data) }
  table.insert(requests, entry)
  local code, body, responseHeaders
  if url:sub(-#constants.TOKEN_PATH) == constants.TOKEN_PATH then
    local answer = table.remove(tokenAnswers, 1)
    if answer then
      code, body, responseHeaders = answer[1], answer[2], answer[3] or {}
    else
      code, body, responseHeaders = issue()
    end
  else
    local answer = table.remove(apiAnswers, 1)
    if answer then
      code, body, responseHeaders = answer[1], answer[2], answer[3] or {}
    else
      code, body, responseHeaders = 200, apiBody, {}
    end
  end
  callback(nil, code, responseHeaders, body, context, url)
end

local function reset()
  requests, tokenAnswers, apiAnswers = {}, {}, {}
end

local function tokenRequests()
  local list = {}
  for _, r in ipairs(requests) do
    if r.url:sub(-#constants.TOKEN_PATH) == constants.TOKEN_PATH then
      list[#list + 1] = r
    end
  end
  return list
end

--- Settles a Deferred that the scripted cloud has already answered.
--- @return boolean ok
--- @return any value
local function settled(d)
  local ok, value
  d:next(function(v)
    ok, value = true, v
  end, function(e)
    ok, value = false, e
  end)
  return ok, value
end

local client = Client:new()
client:setCredentials("demo@example.com", "pa ss&word")

T.section("the password grant")
reset()
local ok = settled(client:signIn())
T.eq("signs in", ok, true)
T.truthy("holds a token", client:isAuthenticated())
local grant = tokenRequests()[1]
T.eq("one token request", #tokenRequests(), 1)
T.eq("a POST", grant.method, "POST")
T.eq("form-encoded", grant.headers["Content-Type"], "application/x-www-form-urlencoded")
T.eq(
  "with the app's client as Basic",
  grant.headers.Authorization,
  "Basic " .. C4:Base64Encode("test-client:test-secret")
)
T.eq("the password grant", grant.form.grant_type, "password")
T.eq("the email", grant.form.username, "demo@example.com")
T.eq("the password, encoded", grant.form.password, "pa ss&word")
T.eq("the scope", grant.form.scope, "openid profile offline_access email")

T.section("calls carry the API key and a lower-case bearer token")
reset()
local _, homes = settled(client:getHomes())
T.eq("the homes", homes[1].id, 1)
T.eq("no new sign-in", #tokenRequests(), 0)
T.eq("homeowner/homes", requests[1].url, API .. "/homeowner/homes")
T.eq("bearer, as the app sends it", requests[1].headers.Authorization, "bearer access-1")
T.eq("the API key", requests[1].headers.ApiKey, "test-api-key")
reset()
apiBody = { device = { id = 58001 } }
local _, record = settled(client:getDevice(58001, "Oncue"))
T.eq("a device read names its host", requests[1].url, API .. "/devices/58001?sourceDeviceHost=Oncue")
T.eq("the record", record.device.id, 58001)
apiBody = { { id = 1, devices = {} } }

T.section("an expired token is refreshed, and the new refresh token kept")
reset()
now = now + 3600
T.falsy("the token ran out", client:isAuthenticated())
T.truthy("but the session is held", client:hasSession())
settled(client:getHomes())
local refresh = tokenRequests()[1]
T.eq("a refresh grant", refresh.form.grant_type, "refresh_token")
T.eq("with the refresh token held", refresh.form.refresh_token, "refresh-1")
T.eq("then the call", requests[2].headers.Authorization, "bearer access-2")
reset()
now = now + 3600
settled(client:getHomes())
T.eq("the next refresh uses the token the last one gave", tokenRequests()[1].form.refresh_token, "refresh-2")

T.section("a refused refresh token signs in again with the password")
reset()
now = now + 3600
tokenAnswers = { { 400, { error = "invalid_grant", error_description = "The refresh token is invalid or expired." } } }
ok = settled(client:getHomes())
T.eq("the call goes through", ok, true)
T.eq("a refresh, then the password grant", tokenRequests()[2].form.grant_type, "password")

T.section("calls waiting on a token share one sign-in")
reset()
now = now + 3600
local held = {}
local realUrlDo = urlDo
urlDo = function(...)
  local args = { ... }
  if args[2] == TOKEN_URL then
    table.insert(held, args)
    table.insert(requests, { url = args[2], form = form(args[3]) })
    return
  end
  realUrlDo(...)
end
local a = client:getHomes()
local b = client:getDevice(58001, "Oncue")
T.eq("one token request for two calls", #tokenRequests(), 1)
urlDo = realUrlDo
local code, body = issue()
held[1][5](nil, code, {}, body, nil, TOKEN_URL)
T.eq("the first call goes through", (settled(a)), true)
T.eq("and the second", (settled(b)), true)

T.section("a 401 signs in again once and repeats the call")
reset()
apiAnswers = { { 401, { message = "Unauthorized" } } }
ok = settled(client:getHomes())
T.eq("the call goes through", ok, true)
T.eq("signed in again with the password", tokenRequests()[1].form.grant_type, "password")
T.eq("the call was sent twice", #requests, 3)

T.section("a second 401 is not tried again")
reset()
apiAnswers = { { 401, { message = "Unauthorized" } }, { 401, { message = "Unauthorized" } } }
local err
ok, err = settled(client:getHomes())
T.eq("fails", ok, false)
T.eq("as unauthorized", err.kind, "unauthorized")
T.eq("one sign-in", #tokenRequests(), 1)

T.section("429 and 5xx")
reset()
apiAnswers = { { 429, { message = "Too Many Requests" }, { ["Retry-After"] = "120" } } }
ok, err = settled(client:getHomes())
T.eq("429 is rate limited", err.kind, "rateLimited")
T.eq("with the wait it names", err.retryAfter, 120)
apiAnswers = { { 429, {} } }
_, err = settled(client:getHomes())
T.eq("a 429 that names no wait waits a minute", err.retryAfter, 60)
apiAnswers = { { 503, { message = "Service Unavailable" } } }
_, err = settled(client:getHomes())
T.eq("a 5xx is unavailable", err.kind, "unavailable")
T.eq("with its status", err.code, 503)
apiAnswers = { { 404, { message = "Device not found" } } }
_, err = settled(client:getDevice(1, "Oncue"))
T.eq("a 404 failed", err.kind, "failed")

T.section("a wrong password stops at credentials")
reset()
client:setCredentials("demo@example.com", "wrong")
T.falsy("changing the password signs out", client:isAuthenticated())
T.falsy("and drops the session", client:hasSession())
tokenAnswers = { { 400, { error = "invalid_grant", error_description = "The credentials provided were invalid." } } }
ok, err = settled(client:signIn())
T.eq("fails", ok, false)
T.eq("as credentials", err.kind, "credentials")
T.eq("with the message Login Status shows", err.message, "Invalid email or password")

T.section("a sign-in the service refuses")
reset()
tokenAnswers = { { 400, { error = "mfa_required", error_description = "The sign-in was not allowed by policy." } } }
_, err = settled(client:signIn())
T.eq("a second factor is refused", err.kind, "refused")
T.contains("with the reason", err.message, "Sign-in refused")
tokenAnswers = { { 401, { error = "access_denied" } } }
_, err = settled(client:signIn())
T.eq("access denied is refused", err.kind, "refused")
tokenAnswers = { { 429, {}, { ["retry-after"] = "30" } } }
_, err = settled(client:signIn())
T.eq("a 429 at sign-in is rate limited", err.kind, "rateLimited")
T.eq("the wait", err.retryAfter, 30)
tokenAnswers = { { 502, "Bad Gateway" } }
_, err = settled(client:signIn())
T.eq("a 5xx at sign-in is unavailable", err.kind, "unavailable")

T.section("no email or password sends nothing")
reset()
client:setCredentials("", "")
_, err = settled(client:signIn())
T.eq("credentials", err.kind, "credentials")
T.eq("asks for them", err.message, "Enter email and password")
T.eq("nothing sent", #requests, 0)

T.section("a sign-out during a sign-in keeps nothing")
reset()
client:setCredentials("demo@example.com", "pa ss&word")
held = {}
urlDo = function(...)
  table.insert(held, { ... })
end
local pending = client:signIn()
client:signOut()
urlDo = realUrlDo
code, body = issue()
held[1][5](nil, code, {}, body, nil, TOKEN_URL)
T.eq("the sign-in fails", (settled(pending)), false)
T.falsy("and holds no token", client:isAuthenticated())

T.section("a command is sent once, with its JSON body, routed by the generator's host")
--- @return table[]
local function apiRequests()
  local list = {}
  for _, r in ipairs(requests) do
    if r.url:sub(-#constants.TOKEN_PATH) ~= constants.TOKEN_PATH then
      list[#list + 1] = r
    end
  end
  return list
end
reset()
ok = settled(
  client:send({ method = "POST", path = "/devices/58001/exercise/start", body = { mode = "Unloaded" } }, "Oncue")
)
T.eq("sent", ok, true)
local call = apiRequests()[1]
T.eq("one call", #apiRequests(), 1)
T.eq("a POST", call.method, "POST")
T.eq("to the path, with the host", call.url, API .. "/devices/58001/exercise/start?sourceDeviceHost=Oncue")
-- urlDo sends a table as JSON.
T.eq("the body", call.data, { mode = "Unloaded" })
T.eq("with the bearer token", call.headers.Authorization:match("^bearer "), "bearer ")
T.eq("and the API key", call.headers.ApiKey, "test-api-key")

reset()
settled(client:send({ method = "POST", path = "/devices/58001/exercise/stop" }, "Oncue"))
T.eq("a stop sends no body", apiRequests()[1].data, nil)

reset()
settled(client:send({ method = "PUT", path = "/devices/58001/exercise", body = { frequency = "Weekly" } }, "Oncue"))
T.eq("a schedule is a PUT", apiRequests()[1].method, "PUT")

T.section("a command KOHLER refused with a 401 is sent again once after a new sign-in")
reset()
apiAnswers = { { 401, { message = "Unauthorized" } } }
ok = settled(client:send({ method = "POST", path = "/devices/58001/exercise/stop" }, "Oncue"))
T.eq("goes through", ok, true)
T.eq("sent twice", #apiRequests(), 2)
T.eq("after a sign-in", #tokenRequests(), 1)

T.section("a command that failed with a 5xx or no answer is never sent again")
reset()
apiAnswers = { { 503, { message = "Service Unavailable" } } }
ok, err = settled(
  client:send({ method = "POST", path = "/devices/58001/exercise/start", body = { mode = "Unloaded" } }, "Oncue")
)
T.eq("fails", ok, false)
T.eq("as unavailable", err.kind, "unavailable")
T.eq("sent once", #apiRequests(), 1)
reset()
local realDo = urlDo
urlDo = function(method, url, data, headers, callback, context)
  if url:sub(-#constants.TOKEN_PATH) == constants.TOKEN_PATH then
    return realDo(method, url, data, headers, callback, context)
  end
  table.insert(requests, { method = method, url = url, data = data, headers = headers })
  callback("Operation timed out", nil, {}, nil, context, url)
end
ok, err = settled(
  client:send({ method = "POST", path = "/devices/58001/exercise/start", body = { mode = "Unloaded" } }, "Oncue")
)
urlDo = realDo
T.eq("a timeout fails", ok, false)
T.eq("as unavailable", err.kind, "unavailable")
T.eq("and is sent once", #apiRequests(), 1)

T.section("a test cloud replaces both origins and the keys")
reset()
client:setServer("http://mock.test:18400/", "mock-client", "mock-client-secret", "mock-api-key")
T.truthy("in use", client:usesTestCloud())
settled(client:getHomes())
T.eq("its token endpoint", requests[1].url, "http://mock.test:18400/oauth2/default/v1/token")
T.eq("its client", requests[1].headers.Authorization, "Basic " .. C4:Base64Encode("mock-client:mock-client-secret"))
T.eq("its API", requests[2].url, "http://mock.test:18400/kem/api/v3/homeowner/homes")
T.eq("its key", requests[2].headers.ApiKey, "mock-api-key")
client:setServer(nil)
T.falsy("back to KOHLER's", client:usesTestCloud())
T.eq("signed out", client:isAuthenticated(), false)

T.section("a build without the client cannot sign in")
constants.CLIENT_SECRET = "__KOHLER_CLIENT_SECRET__"
reset()
T.falsy("not configured", client:isConfigured())
_, err = settled(client:signIn())
T.contains("says so", err.message, "no KOHLER client")
T.eq("nothing sent", #requests, 0)

T.finish()
