// What the generator page shows for a state from the Kohler Generator driver (src/kohler/page.lua): the
// words, values and which buttons work, with no DOM, so node:test checks it as it is. Times are epoch
// seconds, shown in the device's own time zone.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.KGView = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

  var MODES = ["Unloaded", "Unloaded Full Speed", "Loaded Full Speed"];
  var FREQUENCIES = ["Weekly", "Every Other Week", "Monthly"];
  var WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  var MINUTES = [5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60];

  // Each reading's label and how it reads, in the order the driver sends them.
  var READINGS = {
    utilityVoltage: { label: "Utility voltage", unit: " V", digits: 0 },
    generatorVoltage: { label: "Generator voltage", unit: " V", digits: 0 },
    loadWatts: { label: "Load", watts: true },
    loadPercent: { label: "Load share", unit: "%", digits: 0 },
    frequency: { label: "Frequency", unit: " Hz", digits: 1 },
    engineRpm: { label: "Engine speed", unit: " rpm", digits: 0 },
    batteryVoltage: { label: "Battery", unit: " V", digits: 1 },
    controllerTemperature: { label: "Controller temperature", temperature: true },
    lubeOilTemperature: { label: "Oil temperature", temperature: true },
    coolantTemperature: { label: "Coolant temperature", temperature: true },
    runtimeHours: { label: "Run hours", unit: " h", digits: 1 },
    operationHours: { label: "Operation hours", unit: " h", digits: 1 },
    oilPressure: { label: "Oil pressure", ok: ["OK", "Low"] },
  };

  function pad(n) {
    return (n < 10 ? "0" : "") + n;
  }

  function clock(d) {
    var h = d.getHours();
    return (h % 12 || 12) + ":" + pad(d.getMinutes()) + " " + (h < 12 ? "AM" : "PM");
  }

  function dayStart(d) {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  }

  // A time as the page words it: "Today 10:00 AM", "Tomorrow 10:00 AM", "Sat 10:00 AM" within a week,
  // else "Sep 3, 2026". "" for none.
  function when(epoch, now) {
    if (typeof epoch !== "number") return "";
    var d = new Date(epoch * 1000);
    var days = Math.round((dayStart(d) - dayStart(new Date(now * 1000))) / 86400000);
    if (days === 0) return "Today " + clock(d);
    if (days === 1) return "Tomorrow " + clock(d);
    if (days === -1) return "Yesterday " + clock(d);
    if (days > 1 && days < 7) return DAYS[d.getDay()] + " " + clock(d);
    if (days < -1 && days > -7) return DAYS[d.getDay()] + " " + clock(d);
    return MONTHS[d.getMonth()] + " " + d.getDate() + ", " + d.getFullYear();
  }

  // How long ago: "just now", "4 min ago", "2 h ago", or when() past a day.
  function ago(epoch, now) {
    if (typeof epoch !== "number") return "";
    var s = Math.max(0, now - epoch);
    if (s < 60) return "just now";
    if (s < 3600) return Math.floor(s / 60) + " min ago";
    if (s < 86400) return Math.floor(s / 3600) + " h ago";
    return when(epoch, now);
  }

  function number(value, digits) {
    var f = Math.pow(10, digits);
    return String(Math.round(value * f) / f);
  }

  function reading(r, scale) {
    var spec = READINGS[r.key];
    if (!spec) return null;
    var v = r.value;
    var text;
    if (spec.ok) text = v ? spec.ok[0] : spec.ok[1];
    else if (spec.watts) text = v >= 1000 ? number(v / 1000, 1) + " kW" : number(v, 0) + " W";
    else if (spec.temperature) text = number(v, 0) + (scale === "C" ? " °C" : " °F");
    else text = number(v, spec.digits) + spec.unit;
    return { key: r.key, label: spec.label, value: text, tone: spec.ok && !v ? "bad" : null };
  }

  // The top: what powers the house, and the generator's state.
  function top(state, now) {
    var t = state.top;
    var power;
    if (t.onGeneratorPower) power = { text: "On generator power", tone: "warn" };
    else if (t.utilityOut) power = { text: "Utility power is out", tone: "bad" };
    else power = { text: "On utility power", tone: "ok" };
    var engine;
    if (t.fault) engine = { text: "Fault", tone: "bad" };
    else if (t.exercising) engine = { text: "Exercising", tone: "warn" };
    else if (t.running) engine = { text: "Running", tone: "warn" };
    else engine = { text: t.status || "Standby", tone: "quiet" };
    var sw = t.inAuto
      ? { text: "Switch in Auto", tone: "quiet" }
      : { text: "Switch in " + (t.switchPosition || "Off"), tone: "warn" };
    return {
      name: state.name || "Generator",
      power: power,
      engine: engine,
      engineState: t.engineState || "",
      switchPosition: sw,
      reported: t.reported ? "Updated " + ago(t.reported, now) : "",
    };
  }

  // The driver's schedule line, "Weekly, Tuesday 10:00, ...", with its time as the rest of the page
  // shows times: "Weekly, Tuesday 10:00 AM, ...".
  function scheduleText(schedule) {
    if (!schedule || schedule === "None") return "No exercise scheduled";
    return schedule.replace(/\b(\d{1,2}):(\d{2})\b/, function (_m, h, m) {
      return clock(new Date(2000, 0, 1, Number(h), Number(m)));
    });
  }

  function exercise(state, now) {
    var e = state.exercise;
    return {
      running: !!e.running,
      schedule: scheduleText(e.schedule),
      next: when(e.nextAt, now),
      last: when(e.lastAt, now),
      start: { enabled: !e.start, reason: e.start || "" },
      stop: { enabled: !e.stop, reason: e.running ? e.stop || "" : "" },
      sheet: e.sheet || {},
    };
  }

  function entry(item, now) {
    var tone = "quiet";
    if (item.level === "Shutdown" || item.level === "Fault") tone = "bad";
    else if (item.level === "Warning") tone = "warn";
    return { id: item.id, name: item.name || "Alert", level: item.level || "", time: when(item.at, now), tone: tone };
  }

  function service(state, now) {
    var s = state.service;
    var rows = [];
    function add(label, value, tone) {
      if (value !== undefined && value !== null && value !== "") rows.push({ label: label, value: String(value), tone: tone || null });
    }
    add("Next maintenance", when(s.nextMaintenanceAt, now), s.maintenanceDue ? "warn" : null);
    add("Last maintenance", when(s.lastMaintenanceAt, now));
    if (typeof s.hoursSinceMaintenance === "number") add("Run hours since", number(s.hoursSinceMaintenance, 1) + " h");
    add("Dealer", s.dealer);
    add("Model", s.model);
    add("Serial number", s.serial);
    add("Controller", s.controller);
    add("Firmware", s.firmware);
    add("Fuel", s.fuel);
    add("Connection", s.connection);
    return { due: !!s.maintenanceDue, rows: rows };
  }

  // Why the page can't show the generator, with whether Try again helps.
  function notConnected(state, now) {
    if (state.reason === "account") {
      return {
        title: "Not connected",
        text: "The Kohler Generators driver isn't signed in to KOHLER, or this generator has left the account.",
        retry: false,
      };
    }
    if (state.reason === "waiting") {
      return { title: "Connecting", text: "Waiting for the generator's first reading.", retry: true };
    }
    var heard = state.lastHeard ? " It was last heard from " + when(state.lastHeard, now) + "." : "";
    return {
      title: "Generator offline",
      text: "KOHLER isn't hearing from the generator, so it can't be controlled from here." + heard,
      retry: true,
    };
  }

  // Everything the page draws. now: epoch seconds.
  function view(state, now) {
    var v = { connected: !!state.connected, scale: state.scale === "C" ? "C" : "F" };
    if (!state.connected) {
      v.notConnected = notConnected(state, now);
      if (!state.top) return v;
    }
    v.top = top(state, now);
    v.readings = (state.readings || [])
      .map(function (r) {
        return reading(r, v.scale);
      })
      .filter(Boolean);
    v.exercise = exercise(state, now);
    v.loads = state.loads
      ? state.loads.items.map(function (l) {
          return { name: l.name, on: !!l.on };
        })
      : null;
    v.alerts = (state.alerts || []).map(function (a) {
      return entry(a, now);
    });
    v.history = (state.history || []).map(function (h) {
      return entry(h, now);
    });
    v.service = service(state, now);
    return v;
  }

  // The confirm before Start: what the exercise does to the generator and the house.
  function confirmStart(mode) {
    var text = "The generator's engine starts and runs for the exercise's length, then cools down and stops.";
    if (mode === "Loaded Full Speed") {
      text += " The house moves to generator power for the exercise, and back to utility power after it.";
    } else {
      text += " The house stays on utility power.";
    }
    return { title: "Start an exercise?", text: text, ok: "Start exercise", cancel: "Cancel" };
  }

  // What the page says once a command it sent is answered.
  function answer(lastCommand) {
    if (!lastCommand) return null;
    var names = {
      start: "Exercise start",
      stop: "Exercise stop",
      schedule: "Schedule",
      load: "Load",
    };
    var name = names[lastCommand.action] || "Command";
    if (lastCommand.ok) return { text: name + " sent to the generator.", tone: "ok" };
    return { text: name + " not sent: " + (lastCommand.message || "refused") + ".", tone: "bad" };
  }

  return {
    view: view,
    when: when,
    ago: ago,
    confirmStart: confirmStart,
    answer: answer,
    MODES: MODES,
    FREQUENCIES: FREQUENCIES,
    WEEKDAYS: WEEKDAYS,
    MINUTES: MINUTES,
  };
});
