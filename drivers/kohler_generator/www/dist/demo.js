// A made-up generator for the page outside the Control4 app, where there is no C4 object: a stand-in C4 that
// answers hello with the sample generator's state and carries out the page's commands on it, as the driver
// and the generator would, a few seconds apart. The name, serial number and dealer are invented.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.KGDemo = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var DAY = 86400;

  function nextTuesdayTen(now) {
    var d = new Date(now * 1000);
    d.setHours(10, 0, 0, 0);
    var add = (2 - d.getDay() + 7) % 7;
    if (add === 0 && d.getTime() / 1000 <= now) add = 7;
    d.setDate(d.getDate() + add);
    return Math.floor(d.getTime() / 1000);
  }

  // The sample generator's state at `now`, epoch seconds.
  function state(now) {
    now = now || Math.floor(Date.now() / 1000);
    return {
      connected: true,
      scale: "F",
      name: "Sample Generator",
      lastHeard: now - 60,
      top: {
        powerSource: "Utility",
        onGeneratorPower: false,
        utilityOut: false,
        status: "Ready To Run",
        engineState: "Standby",
        switchPosition: "Auto",
        inAuto: true,
        running: false,
        exercising: false,
        fault: false,
        reported: now - 4 * 60,
      },
      readings: [
        { key: "utilityVoltage", value: 241 },
        { key: "batteryVoltage", value: 13.4 },
        { key: "controllerTemperature", value: 68 },
        { key: "lubeOilTemperature", value: 64 },
        { key: "runtimeHours", value: 87.3 },
        { key: "operationHours", value: 9120.5 },
        { key: "oilPressure", value: true },
      ],
      exercise: {
        schedule: "Weekly, Tuesday 10:00, Unloaded, 20 minutes",
        nextAt: nextTuesdayTen(now),
        lastAt: nextTuesdayTen(now) - 7 * DAY,
        running: false,
        start: null,
        stop: "No exercise is running",
        sheet: { frequency: "Weekly", day: "Tuesday", time: "10:00", mode: "Unloaded", minutes: 20 },
      },
      loads: {
        items: [
          { name: "HVAC A", on: true },
          { name: "HVAC B", on: true },
          { name: "Load A", on: false },
          { name: "Load B", on: true },
        ],
      },
      alerts: [],
      history: [
        { id: 3, name: "Exercise Ended", level: "Status", at: nextTuesdayTen(now) - 7 * DAY + 20 * 60 },
        { id: 2, name: "Engine Started", level: "Status", at: nextTuesdayTen(now) - 7 * DAY },
        { id: 1, name: "Battery Charger Check", level: "Notice", at: now - 20 * DAY },
      ],
      service: {
        lastMaintenanceAt: now - 200 * DAY,
        nextMaintenanceAt: now + 165 * DAY,
        maintenanceDue: false,
        hoursSinceMaintenance: 12.4,
        dealer: "Sample Power Service, 555-0100",
        model: "20 KW",
        serial: "SAMPLE-000001",
        controller: "RDC2 (Blue Board)",
        firmware: "0.0.0",
        fuel: "Natural Gas",
        connection: "Ethernet",
      },
      lastCommand: null,
    };
  }

  // A stand-in for the app's C4: deliver(value) hands a push to the page, the way the app calls onDataToUi.
  function c4(deliver, opts) {
    opts = opts || {};
    var later = opts.later || function (fn, ms) {
      setTimeout(fn, ms);
    };
    var s = state();
    var rev = 1;
    var device = "demo";

    function push(page) {
      rev += 1;
      var json = JSON.stringify({ device: device, page: page || null, boot: "demo", rev: rev, state: s });
      later(function () {
        deliver({
          devicecommand: {
            command: "KG_PAGE_STATE",
            params: { param: [{ name: "json", value: { type: "STRING", static: json } }] },
          },
        });
      }, 0);
    }

    function answer(fields, ok, message) {
      s.lastCommand = { request: fields.request || null, action: fields.action, ok: ok, message: message };
      if (!ok) push();
    }

    function command(fields) {
      var now = Math.floor(Date.now() / 1000);
      if (fields.action === "start") {
        if (s.exercise.start) return answer(fields, false, s.exercise.start);
        answer(fields, true, "Sent");
        push();
        later(function () {
          s.top.running = s.top.exercising = s.exercise.running = true;
          s.top.engineState = "Performing Unloaded Exercise";
          s.top.status = "Running Exercise";
          s.top.reported = now;
          s.top.onGeneratorPower = fields.mode === "Loaded Full Speed";
          s.exercise.start = "The generator is already running";
          s.exercise.stop = null;
          push();
        }, 2500);
      } else if (fields.action === "stop") {
        if (s.exercise.stop) return answer(fields, false, s.exercise.stop);
        answer(fields, true, "Sent");
        push();
        later(function () {
          s.top.running = s.top.exercising = s.exercise.running = false;
          s.top.onGeneratorPower = false;
          s.top.engineState = "Standby";
          s.top.status = "Ready To Run";
          s.exercise.start = null;
          s.exercise.stop = "No exercise is running";
          s.exercise.lastAt = now;
          push();
        }, 2500);
      } else if (fields.action === "schedule") {
        answer(fields, true, "Sent");
        s.exercise.sheet = {
          frequency: fields.frequency,
          day: fields.day,
          time: fields.time,
          mode: fields.mode,
          minutes: Number(fields.minutes),
        };
        s.exercise.schedule =
          fields.frequency + ", " + fields.day + " " + fields.time + ", " + fields.mode + ", " + fields.minutes + " minutes";
        push();
      } else if (fields.action === "load") {
        answer(fields, true, "Sent");
        s.loads.items.forEach(function (l) {
          if (l.name === fields.load) l.on = fields.on === true || fields.on === "true";
        });
        push();
      } else if (fields.action === "refresh") {
        s.top.reported = now;
        push();
      }
    }

    return {
      subscribeToDataToUi: function () {},
      sendCommand: function (name, json) {
        var fields = JSON.parse(json || "{}");
        if (name === "KG_PAGE_HELLO") push(fields.page);
        else if (name === "KG_PAGE_COMMAND") command(fields);
      },
      state: function () {
        return s;
      },
    };
  }

  return { state: state, c4: c4 };
});
