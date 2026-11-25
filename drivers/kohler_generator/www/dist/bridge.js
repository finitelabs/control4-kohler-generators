// The generator page's link to its Kohler Generator driver, through the C4 object the Control4 app puts in
// the web view. A command goes out with C4.sendCommand and reaches the driver's ExecuteCommand with this JSON
// as its parameters. The driver's state comes back through C4:SendDataToUI as a devicecommand envelope with
// one `json` parameter. That push may reach pages of other generators too, so the page holds to the driver
// that answered its own hello: each hello carries the page's id, the answer names it, and later states must
// come from that answer's device. A push sent the moment the page subscribes can be lost, so the page says
// hello every 3 s until its answer arrives, then pings every 15 s with the state it holds; the driver sends
// the state again to a page that is behind. A state carries the driver's load id with its revision, so a page
// left open across a driver reload takes the new one.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.KGBridge = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var STATE = "KG_PAGE_STATE";
  var HELLO_MS = 3000;
  var PING_MS = 15000;

  function parse(text) {
    try {
      return JSON.parse(text);
    } catch (e) {
      return null;
    }
  }

  // A push as { command, data }: the envelope's params, with the driver's `json` parameter decoded. null for
  // anything that isn't a devicecommand.
  function unwrap(value) {
    var v = typeof value === "string" ? parse(value) : value;
    var dc = v && v.devicecommand;
    if (!dc || typeof dc.command !== "string") return null;
    var params = {};
    var list = dc.params ? dc.params.param : null;
    (Array.isArray(list) ? list : list ? [list] : []).forEach(function (p) {
      if (!p || !p.name) return;
      var val = p.value;
      params[p.name] = val && typeof val === "object" && val.static !== undefined ? val.static : val;
    });
    var data = typeof params.json === "string" ? parse(params.json) : null;
    return { command: dc.command, data: data && typeof data === "object" ? data : {} };
  }

  function randomId() {
    return "p" + Math.floor(Math.random() * 1e12).toString(36) + Date.now().toString(36);
  }

  // options: { c4, onState(state, rev), onError?(message), timers?, pageId? }
  function create(options) {
    var c4 = options.c4;
    var timers = options.timers || {
      setInterval: function (fn, ms) {
        return setInterval(fn, ms);
      },
      clearInterval: function (handle) {
        clearInterval(handle);
      },
    };
    var pageId = options.pageId || randomId();
    var device = null;
    var boot = "";
    var rev = 0;
    var helloTimer = null;
    var pingTimer = null;

    function sendRaw(command, params) {
      try {
        c4.sendCommand(command, JSON.stringify(params), true, true);
      } catch (e) {
        if (options.onError) options.onError(command + ": " + e.message);
      }
    }

    function hello() {
      sendRaw("KG_PAGE_HELLO", { page: pageId });
    }

    function receive(value) {
      var message = unwrap(value);
      if (!message || message.command !== STATE) return;
      var data = message.data;
      var from = String(data.device || "");
      if (device === null) {
        if (data.page !== pageId) return;
        device = from;
        if (helloTimer !== null) {
          timers.clearInterval(helloTimer);
          helloTimer = null;
        }
      } else if (from !== device) {
        return;
      }
      var stateBoot = String(data.boot || "");
      var stateRev = Number(data.rev) || 0;
      if (stateBoot === boot && stateRev <= rev) return;
      boot = stateBoot;
      rev = stateRev;
      options.onState(data.state || {}, rev);
    }

    function start() {
      try {
        c4.subscribeToDataToUi(true);
      } catch (e) {
        if (options.onError) options.onError("subscribe: " + e.message);
      }
      hello();
      helloTimer = timers.setInterval(hello, HELLO_MS);
      pingTimer = timers.setInterval(function () {
        if (device !== null) sendRaw("KG_PAGE_PING", { boot: boot, rev: rev });
      }, PING_MS);
    }

    function stop() {
      if (helloTimer !== null) timers.clearInterval(helloTimer);
      if (pingTimer !== null) timers.clearInterval(pingTimer);
      helloTimer = pingTimer = null;
    }

    return {
      start: start,
      stop: stop,
      receive: receive,
      // A command: its fields reach the driver as KG_PAGE_COMMAND's parameters.
      command: function (fields) {
        sendRaw("KG_PAGE_COMMAND", fields);
      },
      pageId: function () {
        return pageId;
      },
    };
  }

  return { create: create, unwrap: unwrap, STATE: STATE };
});
