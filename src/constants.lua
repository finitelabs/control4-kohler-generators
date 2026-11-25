--- Constants used throughout the driver.

return {
  --- Show a property in the Composer UI.
  --- @type number
  SHOW_PROPERTY = 0,

  --- Hide a property in the Composer UI.
  --- @type number
  HIDE_PROPERTY = 1,

  --- The KOHLER Energy Management sign-in and homeowner API. A test cloud replaces both origins
  --- (kohler.client), so a development run can use the mock in test/mock-kohler.
  AUTH_ORIGIN = "https://kohler-homeenergy.okta.com",
  TOKEN_PATH = "/oauth2/default/v1/token",
  API_ORIGIN = "https://api.hems.rehlko.com",
  API_PATH = "/kem/api/v3",
  SCOPE = "openid profile offline_access email",

  --- Build secrets, substituted by tools/preprocess.py from .env or CI secrets (see .env.default).
  --- Empty in a build that was given none.
  CLIENT_ID = "__KOHLER_CLIENT_ID__",
  CLIENT_SECRET = "__KOHLER_CLIENT_SECRET__",
  API_KEY = "__KOHLER_API_KEY__",

  --- Dynamic-binding namespace for the generator provider bindings on the account driver (see
  --- lib.bindings), keyed by the generator's id.
  BINDING_NAMESPACE = "kohler",

  --- The connection class shared by the account (provider) and the kohler_generator companion
  --- (consumer). Must match the companion's driver.xml.
  GENERATOR_CLASS = "KOHLER_GENERATOR",

  --- The companion's consumer binding for the account's generator bindings.
  GENERATOR_BINDING = 5002,

  --- Proxy commands exchanged across the account and companion binding.
  CMD = {
    --- account to companion: the generator's full record, as { JSON = ... }
    UPDATE_GENERATOR = "updateGenerator",
    --- account to companion: the generator's alerts and event log, as { ALERTS = ..., EVENTS = ... }
    UPDATE_FEEDS = "updateFeeds",
    --- account to companion: the generator is gone, or the account is signed out
    GO_OFFLINE = "goOffline",
    --- companion to account: send the generator's record again
    REFRESH_STATE = "REFRESH_STATE",
    --- companion to account: a command for the generator, as { JSON = a KohlerCommand }, or
    --- { JSON = { action = "refresh" } } to read the generator now
    GENERATOR_COMMAND = "generatorCommand",
    --- account to companion: how a command went, as { ACTION, OK = "true"|"false", MESSAGE }
    COMMAND_RESULT = "commandResult",
  },
}
