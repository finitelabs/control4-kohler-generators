// The generator page's words and buttons for each state, from view.js alone.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const KGView = require("../drivers/kohler_generator/www/dist/view.js");
const KGDemo = require("../drivers/kohler_generator/www/dist/demo.js");

const NOW = Date.UTC(2026, 8, 26, 14, 0, 0) / 1000;

function sample(change) {
  const s = KGDemo.state(NOW);
  if (change) change(s);
  return s;
}

test("standby: utility power, start allowed, stop refused", () => {
  const v = KGView.view(sample(), NOW);
  assert.equal(v.connected, true);
  assert.equal(v.notConnected, undefined);
  assert.deepEqual(v.top.power, { text: "On utility power", tone: "ok" });
  assert.equal(v.top.engine.text, "Ready To Run");
  assert.equal(v.top.switchPosition.text, "Switch in Auto");
  assert.equal(v.top.reported, "Updated 4 min ago");
  assert.deepEqual(v.exercise.start, { enabled: true, reason: "" });
  assert.equal(v.exercise.stop.enabled, false);
  assert.equal(v.loads.length, 4);
  assert.equal(v.alerts.length, 0);
  assert.equal(v.history.length, 3);
});

test("the schedule's time reads as the page's other times", () => {
  const v = KGView.view(sample(), NOW);
  assert.equal(v.exercise.schedule, "Weekly, Tuesday 10:00 AM, Unloaded, 20 minutes");
  assert.match(v.exercise.next, /10:00 AM$/);
  const evening = KGView.view(sample((s) => (s.exercise.schedule = "Monthly, Friday 18:05, Unloaded, 30 minutes")), NOW);
  assert.equal(evening.exercise.schedule, "Monthly, Friday 6:05 PM, Unloaded, 30 minutes");
  assert.equal(KGView.view(sample((s) => (s.exercise.schedule = "None")), NOW).exercise.schedule, "No exercise scheduled");
});

test("readings: only those sent, in the project's scale", () => {
  let v = KGView.view(sample(), NOW);
  const byKey = Object.fromEntries(v.readings.map((r) => [r.key, r.value]));
  assert.equal(byKey.controllerTemperature, "68 °F");
  assert.equal(byKey.oilPressure, "OK");
  assert.equal(byKey.coolantTemperature, undefined);
  v = KGView.view(
    sample((s) => {
      s.scale = "C";
      s.readings = [
        { key: "coolantTemperature", value: 91.4 },
        { key: "loadWatts", value: 4250 },
        { key: "oilPressure", value: false },
        { key: "notAReading", value: 1 },
      ];
    }),
    NOW
  );
  assert.deepEqual(
    v.readings.map((r) => [r.label, r.value, r.tone]),
    [
      ["Coolant temperature", "91 °C", null],
      ["Load", "4.3 kW", null],
      ["Oil pressure", "Low", "bad"],
    ]
  );
});

test("outage: utility out, start greyed with the guard's reason", () => {
  const v = KGView.view(
    sample((s) => {
      s.top.utilityOut = true;
      s.exercise.start = "Utility power is out";
    }),
    NOW
  );
  assert.deepEqual(v.top.power, { text: "Utility power is out", tone: "bad" });
  assert.deepEqual(v.exercise.start, { enabled: false, reason: "Utility power is out" });
});

test("exercise running: stop allowed, start refused, on generator power when loaded", () => {
  const v = KGView.view(
    sample((s) => {
      s.top.running = s.top.exercising = s.exercise.running = true;
      s.top.onGeneratorPower = true;
      s.exercise.start = "The generator is already running";
      s.exercise.stop = null;
    }),
    NOW
  );
  assert.equal(v.top.engine.text, "Exercising");
  assert.deepEqual(v.top.power, { text: "On generator power", tone: "warn" });
  assert.deepEqual(v.exercise.stop, { enabled: true, reason: "" });
  assert.equal(v.exercise.start.enabled, false);
});

test("fault: alerts first, with tones", () => {
  const v = KGView.view(
    sample((s) => {
      s.top.fault = true;
      s.top.inAuto = false;
      s.top.switchPosition = "Off";
      s.alerts = [
        { id: 9, name: "Overcrank", level: "Shutdown", at: NOW - 600 },
        { id: 8, name: "Low Battery", level: "Warning", at: NOW - 3600 },
      ];
    }),
    NOW
  );
  assert.deepEqual(v.top.engine, { text: "Fault", tone: "bad" });
  assert.deepEqual(v.top.switchPosition, { text: "Switch in Off", tone: "warn" });
  assert.deepEqual(
    v.alerts.map((a) => [a.name, a.tone]),
    [
      ["Overcrank", "bad"],
      ["Low Battery", "warn"],
    ]
  );
});

test("loads: absent when the driver sends none", () => {
  assert.equal(KGView.view(sample((s) => delete s.loads), NOW).loads, null);
});

test("service: maintenance due shows in the warn tone", () => {
  const v = KGView.view(sample((s) => (s.service.maintenanceDue = true)), NOW);
  assert.equal(v.service.due, true);
  assert.equal(v.service.rows[0].label, "Next maintenance");
  assert.equal(v.service.rows[0].tone, "warn");
  assert.ok(v.service.rows.some((r) => r.label === "Dealer" && r.value === "Sample Power Service, 555-0100"));
});

test("not connected: account, waiting and offline", () => {
  let v = KGView.view({ connected: false, reason: "account", scale: "F" }, NOW);
  assert.equal(v.notConnected.title, "Not connected");
  assert.equal(v.notConnected.retry, false);
  assert.equal(v.top, undefined);
  v = KGView.view({ connected: false, reason: "waiting", scale: "F" }, NOW);
  assert.equal(v.notConnected.retry, true);
  v = KGView.view(
    sample((s) => {
      s.connected = false;
      s.reason = "offline";
      s.lastHeard = NOW - 2 * 86400;
    }),
    NOW
  );
  assert.equal(v.notConnected.title, "Generator offline");
  assert.match(v.notConnected.text, /last heard from/);
  assert.equal(v.notConnected.retry, true);
  assert.ok(v.top);
});

test("confirm before Start states the physical effect", () => {
  const unloaded = KGView.confirmStart("Unloaded");
  assert.match(unloaded.text, /engine starts/);
  assert.match(unloaded.text, /stays on utility power/);
  const loaded = KGView.confirmStart("Loaded Full Speed");
  assert.match(loaded.text, /engine starts/);
  assert.match(loaded.text, /moves to generator power/);
});

test("answers: sent and refused", () => {
  assert.deepEqual(KGView.answer({ action: "start", ok: true }), {
    text: "Exercise start sent to the generator.",
    tone: "ok",
  });
  assert.deepEqual(KGView.answer({ action: "load", ok: false, message: "Load Control is off" }), {
    text: "Load not sent: Load Control is off.",
    tone: "bad",
  });
  assert.equal(KGView.answer(null), null);
});

test("ago and when", () => {
  assert.equal(KGView.ago(NOW - 30, NOW), "just now");
  assert.equal(KGView.ago(NOW - 2 * 3600, NOW), "2 h ago");
  assert.equal(KGView.when(undefined, NOW), "");
  assert.match(KGView.when(NOW + 86400, NOW), /^Tomorrow /);
  assert.match(KGView.when(NOW - 30 * 86400, NOW), /^Aug \d+, 2026$/);
});
