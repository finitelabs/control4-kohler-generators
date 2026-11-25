--- KOHLER Energy Management client: signs in with the homeowner's email and password, reads the
--- account's homes and generators from the homeowner API, and sends their commands.
---
--- Sign-in is the password grant with the app's client, which answers an access token of about
--- an hour and a refresh token that changes on each use. Both stay in memory: after a restart the
--- driver signs in again from the Email and Password properties. A call the API answers 401 drops
--- the tokens and signs in again once.
---
--- Every method that reaches the cloud returns a Deferred, rejected with a KohlerError.

local deferred = require("deferred")
local http = require("lib.http")
local log = require("lib.logging")
local constants = require("constants")

--- Seconds before an access token's end at which it is no longer used.
local TOKEN_SKEW_S = 60
--- The wait after a 429 that names none.
local DEFAULT_RETRY_AFTER_S = 60

--- @alias KohlerErrorKind
--- | "credentials" # The email or password is wrong: stop until they change.
--- | "refused" # The service would not sign this account in, such as one that needs a second factor.
--- | "unauthorized" # A call was refused after signing in again.
--- | "rateLimited" # A 429: wait retryAfter seconds.
--- | "unavailable" # A 5xx, a timeout or no answer: try again later.
--- | "failed" # Anything else, such as a 404.

--- @class KohlerError
--- @field kind KohlerErrorKind
--- @field message string
--- @field code? integer The HTTP status, when there was one.
--- @field retryAfter? integer Seconds to wait, for "rateLimited".

--- @class KohlerClient
local Client = {}
Client.__index = Client

--- A build secret, or nil when the build substituted none (a source checkout still holds the
--- literal __NAME__ placeholder).
--- @param value string|nil
--- @return string|nil value
local function secret(value)
  if type(value) ~= "string" or value == "" or value:match("^__[%w_]+__$") then
    return nil
  end
  return value
end

--- @param value any
--- @return string|nil
local function nonEmpty(value)
  return type(value) == "string" and value ~= "" and value or nil
end

--- Creates a client.
--- @param options? table { allowed = fun(): boolean } allowed is false while the driver may not reach the cloud.
--- @return KohlerClient client
function Client:new(options)
  options = options or {}
  local instance = setmetatable({}, self)
  instance._allowed = options.allowed or function()
    return true
  end
  instance._server = nil
  instance._email = nil
  instance._password = nil
  instance._access = nil
  instance._expiresAt = 0
  instance._refresh = nil
  --- The sign-in or refresh in flight, which every call waiting on a token shares.
  instance._pending = nil
  --- Bumped on sign-out, so a sign-in that settles after it keeps nothing.
  instance._generation = 0
  return instance
end

--- Points the client at a test cloud (the mock) instead of KOHLER's, or back with nil. Signs out.
--- @param server string|nil An origin such as "http://host:18400".
--- @param clientId string|nil The test cloud's client id; the build's when nil.
--- @param clientSecret string|nil Its client secret; the build's when nil.
--- @param apiKey string|nil Its API key; the build's when nil.
function Client:setServer(server, clientId, clientSecret, apiKey)
  server = nonEmpty(server)
  self._server = server
      and {
        origin = (server:gsub("/+$", "")),
        clientId = nonEmpty(clientId),
        clientSecret = nonEmpty(clientSecret),
        apiKey = nonEmpty(apiKey),
      }
    or nil
  self:signOut()
end

--- Whether a test cloud is in use.
--- @return boolean
function Client:usesTestCloud()
  return self._server ~= nil
end

--- The endpoints and keys in use.
--- @return table endpoints { token, api, clientId, clientSecret, apiKey }
function Client:endpoints()
  local server = self._server
  return {
    token = (server and server.origin or constants.AUTH_ORIGIN) .. constants.TOKEN_PATH,
    api = (server and server.origin or constants.API_ORIGIN) .. constants.API_PATH,
    clientId = server and server.clientId or secret(constants.CLIENT_ID),
    clientSecret = server and server.clientSecret or secret(constants.CLIENT_SECRET),
    apiKey = server and server.apiKey or secret(constants.API_KEY),
  }
end

--- Whether this build, or the test cloud, has the client and key a sign-in needs.
--- @return boolean configured
function Client:isConfigured()
  local e = self:endpoints()
  return e.clientId ~= nil and e.clientSecret ~= nil and e.apiKey ~= nil
end

--- Sets the account the client signs in to. A change signs out.
--- @param email string|nil
--- @param password string|nil
function Client:setCredentials(email, password)
  if email ~= self._email or password ~= self._password then
    self:signOut()
  end
  self._email, self._password = email, password
end

--- Whether the client holds an access token that has not run out.
--- @return boolean authenticated
function Client:isAuthenticated()
  return self._access ~= nil and os.time() < self._expiresAt
end

--- Whether the client holds a sign-in to use: an access token, even one that has run out, or a
--- refresh token. A call refreshes or signs in again as it needs to.
--- @return boolean
function Client:hasSession()
  return self._access ~= nil or self._refresh ~= nil
end

--- Forgets the tokens. A sign-in in flight keeps nothing when it settles.
function Client:signOut()
  self._generation = self._generation + 1
  self._access, self._expiresAt, self._refresh, self._pending = nil, 0, nil, nil
end

--- The KohlerError for a failed token request.
--- @param err table|string An HTTPErrorResponse, or a transfer error.
--- @return KohlerError
local function tokenError(err)
  local code = type(err) == "table" and tonumber(err.code) or nil
  local body = type(err) == "table" and type(err.body) == "table" and err.body or {}
  local reason = type(body.error) == "string" and body.error or nil
  if code == 429 then
    local headers = type(err) == "table" and err.headers or {}
    return {
      kind = "rateLimited",
      code = code,
      message = "Too many sign-ins",
      retryAfter = tonumber(headers["Retry-After"] or headers["retry-after"]) or DEFAULT_RETRY_AFTER_S,
    }
  end
  if code == nil or code >= 500 then
    local detail = type(err) == "table" and err.error or err
    return { kind = "unavailable", code = code, message = "Sign-in failed: " .. tostring(detail) }
  end
  if reason == "invalid_grant" then
    return { kind = "credentials", code = code, message = "Invalid email or password" }
  end
  return {
    kind = "refused",
    code = code,
    message = "Sign-in refused: " .. tostring(body.error_description or reason or code),
  }
end

--- Runs one token request. Resolves once the tokens are held.
--- @param form table<string, string>
--- @return Deferred<boolean, KohlerError>
function Client:_token(form)
  local d = deferred.new()
  local e = self:endpoints()
  local generation = self._generation
  local pairs_ = {}
  for _, key in ipairs({ "grant_type", "username", "password", "refresh_token", "scope" }) do
    if form[key] ~= nil then
      pairs_[#pairs_ + 1] = key .. "=" .. URLEncode(form[key], true)
    end
  end
  local headers = {
    ["Authorization"] = "Basic " .. C4:Base64Encode(e.clientId .. ":" .. e.clientSecret),
    ["Content-Type"] = "application/x-www-form-urlencoded",
    ["Accept"] = "application/json",
  }
  http:post(e.token, table.concat(pairs_, "&"), headers):next(function(response)
    if generation ~= self._generation then
      return d:reject({ kind = "failed", message = "Signed out while signing in" })
    end
    local body = type(response.body) == "table" and response.body or {}
    if type(body.access_token) ~= "string" or body.access_token == "" then
      return d:reject({ kind = "unavailable", message = "The sign-in answer carried no access token" })
    end
    self._access = body.access_token
    self._expiresAt = os.time() + math.max((tonumber(body.expires_in) or 3600) - TOKEN_SKEW_S, 0)
    -- The refresh token changes on each use; an answer without one keeps the last.
    self._refresh = nonEmpty(body.refresh_token) or self._refresh
    d:resolve(true)
  end, function(err)
    if generation ~= self._generation then
      return d:reject({ kind = "failed", message = "Signed out while signing in" })
    end
    d:reject(tokenError(err))
  end)
  return d
end

--- Signs in with the email and password.
--- @return Deferred<boolean, KohlerError>
function Client:_passwordGrant()
  if IsEmpty(self._email) or IsEmpty(self._password) then
    return deferred.new():reject({ kind = "credentials", message = "Enter email and password" })
  end
  log:debug("Signing in to KOHLER as %s", self._email)
  return self:_token({
    grant_type = "password",
    username = self._email,
    password = self._password,
    scope = constants.SCOPE,
  })
end

--- A valid access token: the one held, a refreshed one, or a new sign-in. Calls waiting at the
--- same time share one request.
--- @return Deferred<boolean, KohlerError>
function Client:_ensureToken()
  if self:isAuthenticated() then
    return deferred.new():resolve(true)
  end
  if self._pending then
    return self._pending
  end
  local d = deferred.new()
  self._pending = d
  local generation = self._generation
  local function settle(ok, value)
    if generation == self._generation then
      self._pending = nil
    end
    if ok then
      d:resolve(value)
    else
      d:reject(value)
    end
  end
  local function signIn()
    self:_passwordGrant():next(function(v)
      settle(true, v)
    end, function(err)
      settle(false, err)
    end)
  end
  if self._refresh then
    self
      :_token({ grant_type = "refresh_token", refresh_token = self._refresh, scope = constants.SCOPE })
      :next(function(v)
        settle(true, v)
      end, function(err)
        if err.kind == "credentials" or err.kind == "refused" then
          log:info("KOHLER refused the refresh token; signing in again")
          self._refresh = nil
          signIn()
          return
        end
        settle(false, err)
      end)
  else
    signIn()
  end
  return d
end

--- Signs in, or confirms the tokens held are good.
--- @return Deferred<boolean, KohlerError>
function Client:signIn()
  if not self._allowed() then
    return deferred.new():reject({ kind = "failed", message = "No active license" })
  end
  if not self:isConfigured() then
    return deferred.new():reject({ kind = "failed", message = "This build has no KOHLER client" })
  end
  return self:_ensureToken()
end

--- The KohlerError for a failed API call.
--- @param err table|string
--- @return KohlerError
local function apiError(err)
  local code = type(err) == "table" and tonumber(err.code) or nil
  local detail = type(err) == "table" and err.error or tostring(err)
  if code == 429 then
    local headers = type(err) == "table" and err.headers or {}
    return {
      kind = "rateLimited",
      code = code,
      message = detail,
      retryAfter = tonumber(headers["Retry-After"] or headers["retry-after"]) or DEFAULT_RETRY_AFTER_S,
    }
  end
  if code == nil or code >= 500 then
    return { kind = "unavailable", code = code, message = detail }
  end
  if code == 401 then
    return { kind = "unauthorized", code = code, message = detail }
  end
  return { kind = "failed", code = code, message = detail }
end

--- An authenticated call on the homeowner API. A 401 signs in again and repeats the call once:
--- KOHLER took nothing from a call it refused. Nothing else repeats, so a write that timed out or
--- failed with a 5xx is never sent twice.
--- @param method "GET"|"POST"|"PUT"
--- @param path string Below the API's base, such as "/homeowner/homes".
--- @param query? table<string, string>
--- @param body? table A write's JSON body.
--- @param retried? boolean
--- @return Deferred<any, KohlerError> body
--- @private
function Client:_call(method, path, query, body, retried)
  if not self._allowed() then
    return deferred.new():reject({ kind = "failed", message = "No active license" })
  end
  return self:_ensureToken():next(function()
    local e = self:endpoints()
    local url = e.api .. path
    local params = {}
    for key, value in pairs(query or {}) do
      params[#params + 1] = key .. "=" .. URLEncode(value, true)
    end
    if #params > 0 then
      table.sort(params)
      url = url .. "?" .. table.concat(params, "&")
    end
    local headers = {
      -- The app sends the scheme in lower case.
      ["Authorization"] = "bearer " .. self._access,
      ["ApiKey"] = e.apiKey,
      ["Accept"] = "application/json",
    }
    local d = deferred.new()
    local request
    if method == "GET" then
      request = http:get(url, headers)
    else
      request = http:request(method, url, body, headers)
    end
    request:next(function(response)
      d:resolve(response.body)
    end, function(err)
      local failure = apiError(err)
      if failure.kind == "unauthorized" and not retried then
        log:info("KOHLER refused the access token; signing in again")
        self._access, self._expiresAt, self._refresh = nil, 0, nil
        self:_call(method, path, query, body, true):next(function(again)
          d:resolve(again)
        end, function(again)
          d:reject(again)
        end)
        return
      end
      d:reject(failure)
    end)
    return d
  end)
end

--- An authenticated GET on the homeowner API.
--- @param path string
--- @param query? table<string, string>
--- @return Deferred<any, KohlerError> body
--- @private
function Client:_get(path, query)
  return self:_call("GET", path, query)
end

--- The account's homes, each with its generators (homeowner/homes).
--- @return Deferred<table[], KohlerError> homes
function Client:getHomes()
  return self:_get("/homeowner/homes"):next(function(body)
    return type(body) == "table" and body or {}
  end)
end

--- A generator's full record (devices/{id}).
--- @param id integer
--- @param host string The record's deviceHost, which routes the read.
--- @return Deferred<table, KohlerError> record
function Client:getDevice(id, host)
  return self:_get("/devices/" .. tostring(id), { sourceDeviceHost = host }):next(function(body)
    if type(body) ~= "table" then
      return deferred.new():reject({ kind = "failed", message = "The generator's record is not JSON" })
    end
    return body
  end)
end

--- A generator's active alerts (devices/{id}/alerts).
--- @param id integer
--- @param host string The record's deviceHost.
--- @return Deferred<table[], KohlerError> alerts
function Client:getAlerts(id, host)
  return self:_get("/devices/" .. tostring(id) .. "/alerts", { sourceDeviceHost = host }):next(function(body)
    return type(body) == "table" and body or {}
  end)
end

--- A generator's event log, newest first (devices/{id}/events).
--- @param id integer
--- @param host string The record's deviceHost.
--- @return Deferred<table[], KohlerError> events
function Client:getEvents(id, host)
  return self:_get("/devices/" .. tostring(id) .. "/events", { sourceDeviceHost = host }):next(function(body)
    return type(body) == "table" and body or {}
  end)
end

--- Sends a command to a generator (kohler.controls builds it): an exercise start or stop, an
--- exercise schedule, or a load-shed load.
--- @param request KohlerRequest
--- @param host string The record's deviceHost, which routes the call.
--- @return Deferred<any, KohlerError>
function Client:send(request, host)
  return self:_call(request.method, request.path, { sourceDeviceHost = host }, request.body)
end

return Client
