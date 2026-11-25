// The generator page as the app runs it: the bridge's hello and device lock, and app.js in a stand-in DOM.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { loadPage, recordingC4, envelope } from "./page_dom.mjs";

const require = createRequire(import.meta.url);
const KGBridge = require("../drivers/kohler_generator/www/dist/bridge.js");
const KGDemo = require("../drivers/kohler_generator/www/dist/demo.js");

const NOW = Date.UTC(2026, 8, 26, 14, 0, 0) / 1000;

function manualTimers() {
  const list = [];
  return {
    list,
    setInterval(fn, ms) {
      const t = { fn, ms, live: true };
      list.push(t);
      return t;
    },
    clearInterval(t) {
      t.live = false;
    },
    fire(ms) {
      list.filter((t) => t.live && t.ms === ms).forEach((t) => t.fn());
    },
  };
}

function bridge(c4, timers) {
  const states = [];
  const b = KGBridge.create({ c4, timers, pageId: "p1", onState: (s, rev) => states.push([s, rev]) });
  return { b, states };
}

test("bridge: start says hello and nothing else; pings only once locked", () => {
  const c4 = recordingC4();
  const timers = manualTimers();
  const { b } = bridge(c4, timers);
  b.start();
  timers.fire(15000);
  timers.fire(3000);
  assert.deepEqual(
    c4.sent.map((s) => s.name),
    ["KG_PAGE_HELLO", "KG_PAGE_HELLO"]
  );
  assert.deepEqual(c4.sent[0].params, { page: "p1" });
  b.receive(envelope({ device: 42, page: "p1", boot: "b", rev: 1, state: {} }));
  timers.fire(3000);
  timers.fire(15000);
  assert.deepEqual(c4.sent.slice(2), [{ name: "KG_PAGE_PING", params: { boot: "b", rev: 1 } }]);
});

test("bridge: locks onto the device that answered its own hello", () => {
  const { b, states } = bridge(recordingC4(), manualTimers());
  b.receive(envelope({ device: 7, page: "other", boot: "b", rev: 5, state: { name: "Theirs" } }));
  assert.equal(states.length, 0);
  b.receive(envelope({ device: 42, page: "p1", boot: "b", rev: 1, state: { name: "Ours" } }));
  b.receive(envelope({ device: 7, page: null, boot: "b", rev: 9, state: { name: "Theirs" } }));
  b.receive(envelope({ device: 42, page: null, boot: "b", rev: 2, state: { name: "Ours 2" } }));
  assert.deepEqual(
    states.map(([s]) => s.name),
    ["Ours", "Ours 2"]
  );
});

test("bridge: an older revision is dropped; a new boot is taken", () => {
  const { b, states } = bridge(recordingC4(), manualTimers());
  b.receive(envelope({ device: 42, page: "p1", boot: "b1", rev: 5, state: {} }));
  b.receive(envelope({ device: 42, boot: "b1", rev: 4, state: {} }));
  b.receive(envelope({ device: 42, boot: "b1", rev: 5, state: {} }));
  b.receive(envelope({ device: 42, boot: "b2", rev: 1, state: {} }));
  assert.deepEqual(
    states.map(([, rev]) => rev),
    [5, 1]
  );
});

test("bridge: unwrap reads a string envelope and ignores other commands", () => {
  assert.equal(KGBridge.unwrap(JSON.stringify(envelope({ a: 1 }))).data.a, 1);
  assert.equal(KGBridge.unwrap({ other: 1 }), null);
  assert.equal(KGBridge.unwrap("not json"), null);
});

function openPage(state) {
  const c4 = recordingC4();
  const p = loadPage({ c4 });
  p.window.onDataToUi(envelope({ device: 42, page: hello(c4).page, boot: "b", rev: 1, state }));
  return { c4, ...p };
}

function hello(c4) {
  return c4.sent.find((s) => s.name === "KG_PAGE_HELLO").params;
}

function commands(c4) {
  return c4.sent.filter((s) => s.name === "KG_PAGE_COMMAND").map((s) => s.params);
}

test("page: opening, a state and the timers send no command", () => {
  const { c4, page, advance } = openPage(KGDemo.state(NOW));
  advance(120000);
  assert.deepEqual(commands(c4), []);
  assert.ok(c4.sent.every((s) => s.name === "KG_PAGE_HELLO" || s.name === "KG_PAGE_PING"));
  assert.ok(page.textContent.includes("Sample Generator"));
  assert.ok(page.textContent.includes("On utility power"));
});

test("page: Start asks first, with the physical effect, and sends only on confirm", () => {
  const { c4, page, body } = openPage(KGDemo.state(NOW));
  page.button("Start exercise").click();
  assert.deepEqual(commands(c4), []);
  const sheet = body.byClass("sheet")[0];
  assert.ok(sheet, "the confirm sheet is open");
  assert.match(sheet.textContent, /engine starts/);
  assert.match(sheet.textContent, /stays on utility power/);
  sheet.all((e) => e.type === "radio" && e.parentNode.textContent === "Loaded Full Speed")[0].click();
  const loaded = body.byClass("sheet")[0];
  assert.match(loaded.textContent, /moves to generator power/);
  loaded.button("Cancel").click();
  assert.equal(body.byClass("sheet").length, 0);
  assert.deepEqual(commands(c4), []);
  page.button("Start exercise").click();
  body.byClass("sheet")[0].button("Start exercise").click();
  const sent = commands(c4);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].action, "start");
  assert.equal(sent[0].mode, "Unloaded");
  assert.equal(sent[0].request, hello(c4).page + "-1");
  assert.ok(page.textContent.includes("Sending to the generator..."));
});

test("page: guards grey the buttons and say why", () => {
  const state = KGDemo.state(NOW);
  state.exercise.start = "Utility power is out";
  state.exercise.scheduleBlocked = "The generator is offline";
  const { page } = openPage(state);
  assert.equal(page.button("Start exercise").disabled, true);
  assert.equal(page.button("Change schedule").disabled, true);
  assert.ok(page.textContent.includes("Utility power is out"));
});

test("page: the driver's answer clears pending and shows the result", () => {
  const { c4, page, window } = openPage(KGDemo.state(NOW));
  page.button("Start exercise").click();
  window.document.body.byClass("sheet")[0].button("Start exercise").click();
  const request = commands(c4)[0].request;
  const state = KGDemo.state(NOW);
  state.lastCommand = { request, action: "start", ok: false, message: "Utility power is out" };
  window.onDataToUi(envelope({ device: 42, boot: "b", rev: 2, state }));
  assert.ok(page.textContent.includes("Exercise start not sent: Utility power is out."));
  assert.equal(page.button("Start exercise").disabled, false);
});

test("page: an answer to another page, or to this one before a reload, leaves the command pending", () => {
  const state = KGDemo.state(NOW);
  state.lastCommand = { request: "r1", action: "stop", ok: true, message: "Sent" };
  const { c4, page, body, window } = openPage(state);
  page.button("Start exercise").click();
  body.byClass("sheet")[0].button("Start exercise").click();
  const request = commands(c4)[0].request;
  assert.ok(request.startsWith(hello(c4).page + "-"), "the request carries the page's id");
  window.onDataToUi(envelope({ device: 42, boot: "b", rev: 2, state }));
  assert.ok(page.textContent.includes("Sending to the generator..."));
  const answered = KGDemo.state(NOW);
  answered.lastCommand = { request, action: "start", ok: false, message: "Another command is still on its way" };
  window.onDataToUi(envelope({ device: 42, boot: "b", rev: 3, state: answered }));
  assert.ok(page.textContent.includes("Exercise start not sent: Another command is still on its way."));
});

test("page: no answer in 20 s says so", () => {
  const { page, advance, window } = openPage(KGDemo.state(NOW));
  page.button("Start exercise").click();
  window.document.body.byClass("sheet")[0].button("Start exercise").click();
  advance(20000);
  assert.ok(page.textContent.includes("No answer from the generator's driver"));
});

test("page: an open schedule sheet keeps its edits through the tick and the driver's pushes", () => {
  const { c4, page, body, window, advance } = openPage(KGDemo.state(NOW));
  page.button("Change schedule").click();
  const sheet = body.byClass("sheet")[0];
  const [frequency, , , minutes] = sheet.all((e) => e.tagName === "SELECT");
  frequency.value = "Monthly";
  frequency.dispatch("change");
  minutes.value = "45";
  minutes.dispatch("change");
  advance(30000);
  window.onDataToUi(envelope({ device: 42, boot: "b", rev: 2, state: KGDemo.state(NOW) }));
  assert.equal(body.byClass("sheet")[0], sheet, "the same sheet, not rebuilt");
  assert.equal(frequency.value, "Monthly");
  sheet.button("Save").click();
  assert.equal(body.byClass("sheet").length, 0);
  const sent = commands(c4)[0];
  assert.deepEqual(
    [sent.action, sent.frequency, sent.day, sent.time, sent.mode, sent.minutes],
    ["schedule", "Monthly", "Tuesday", "10:00", "Unloaded", "45"]
  );
});

test("page: the sheet closes when the generator goes offline", () => {
  const { page, body, window } = openPage(KGDemo.state(NOW));
  page.button("Change schedule").click();
  const offline = KGDemo.state(NOW);
  offline.connected = false;
  offline.reason = "offline";
  window.onDataToUi(envelope({ device: 42, boot: "b", rev: 2, state: offline }));
  assert.equal(body.byClass("sheet").length, 0);
});

test("page: a load switch sends its new state", () => {
  const { c4, page } = openPage(KGDemo.state(NOW));
  const loadA = page.all((e) => e.type === "checkbox" && e.getAttribute("aria-label") === "Load A")[0];
  loadA.click();
  assert.deepEqual(commands(c4).map(({ action, load, on }) => ({ action, load, on })), [
    { action: "load", load: "Load A", on: true },
  ]);
});

test("page: no Loads card without loads", () => {
  const state = KGDemo.state(NOW);
  delete state.loads;
  const { page } = openPage(state);
  assert.ok(!page.textContent.includes("Loads"));
});

test("page: not connected shows Try again, which asks for a refresh", () => {
  const { c4, page } = openPage({ connected: false, reason: "waiting", scale: "F" });
  assert.ok(page.textContent.includes("Waiting for the generator's first reading."));
  page.button("Try again").click();
  assert.deepEqual(commands(c4), [{ action: "refresh" }]);
  const account = openPage({ connected: false, reason: "account", scale: "F" });
  assert.equal(account.page.button("Try again"), undefined);
});

test("page: cloud text is set as text, never parsed", () => {
  const state = KGDemo.state(NOW);
  state.name = "<img src=x onerror=alert(1)>";
  const { page } = openPage(state);
  assert.ok(page.all((e) => e.tagName === "IMG").length === 0);
  assert.ok(page.textContent.includes("<img src=x onerror=alert(1)>"));
});

test("demo: a refused command is answered", () => {
  const pushes = [];
  const c4 = KGDemo.c4((v) => pushes.push(KGBridge.unwrap(v).data), { later: (fn) => fn() });
  c4.sendCommand("KG_PAGE_COMMAND", JSON.stringify({ action: "stop", request: "r1" }));
  assert.equal(pushes.length, 1);
  assert.deepEqual(pushes[0].state.lastCommand, {
    request: "r1",
    action: "stop",
    ok: false,
    message: "No exercise is running",
  });
});

test("demo: runs without a C4 object", () => {
  const { page, advance, body } = loadPage();
  advance(10);
  assert.equal(body.getAttribute("data-mode"), "demo");
  assert.ok(page.textContent.includes("Sample Generator"));
  page.button("Start exercise").click();
  body.byClass("sheet")[0].button("Start exercise").click();
  advance(3000);
  assert.ok(page.textContent.includes("Exercising"));
  page.button("Stop exercise").click();
  advance(3000);
  assert.ok(page.textContent.includes("Exercise stop sent to the generator."));
});
