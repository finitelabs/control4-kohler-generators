// The generator page. Opened outside the Control4 app, where there is no C4 object, it runs on KGDemo's
// sample generator. Nothing runs on the generator when the page opens or refreshes: only a button the
// homeowner presses sends a command, and Start asks first.
(function () {
  "use strict";

  var ANSWER_MS = 20000;
  var TICK_MS = 30000;

  var current = null;
  var pending = null;
  var note = null;
  var sheet = null;
  var sheetNode = null;
  var draft = null;
  var startGuard = null;
  var startMode = "Unloaded";
  var requests = 0;
  var historyOpen = false;
  var retrying = false;

  var page = document.querySelector(".page");

  function now() {
    return Math.floor(Date.now() / 1000);
  }

  // An element with a class and text; text is never parsed as HTML.
  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }

  function button(label, cls, onClick, enabled) {
    var b = el("button", cls, label);
    b.type = "button";
    if (enabled === false) b.disabled = true;
    b.addEventListener("click", onClick);
    return b;
  }

  function card(title) {
    var section = el("section", "card");
    if (title) section.appendChild(el("h2", "card-title", title));
    page.appendChild(section);
    return section;
  }

  function row(parent, label, value, tone) {
    var r = el("div", "row");
    r.appendChild(el("span", "row-label", label));
    r.appendChild(el("span", "row-value" + (tone ? " tone-" + tone : ""), value));
    parent.appendChild(r);
    return r;
  }

  function badge(item) {
    return el("span", "badge tone-" + item.tone, item.text);
  }

  // Sends a command, with a request id the driver's answer carries back: this page's own id first, so
  // an answer to another page, or to one before a reload, never matches.
  function send(fields) {
    requests += 1;
    fields.request = bridge.pageId() + "-" + requests;
    if (pending && pending.timer) clearTimeout(pending.timer);
    pending = {
      id: fields.request,
      action: fields.action,
      load: fields.load,
      timer: setTimeout(function () {
        if (pending && pending.id === fields.request) {
          pending = null;
          note = { text: "No answer from the generator's driver. Try again.", tone: "bad" };
          render();
        }
      }, ANSWER_MS),
    };
    note = null;
    bridge.command(fields);
    render();
  }

  function sending(action) {
    return pending !== null && pending.action === action;
  }

  function renderNotConnected(v) {
    var c = card();
    c.classList.add("notice");
    c.appendChild(el("h2", "notice-title", v.notConnected.title));
    c.appendChild(el("p", "notice-text", v.notConnected.text));
    if (v.notConnected.retry) {
      c.appendChild(
        button(retrying ? "Trying..." : "Try again", "btn", function () {
          retrying = true;
          bridge.command({ action: "refresh" });
          render();
          setTimeout(function () {
            retrying = false;
            render();
          }, 5000);
        }, !retrying)
      );
    }
  }

  function renderTop(v) {
    var head = el("header", "top");
    head.appendChild(el("h1", "top-name", v.top.name));
    if (v.top.reported) head.appendChild(el("p", "top-reported", v.top.reported));
    page.appendChild(head);
    var c = card();
    c.classList.add("power");
    var line = el("div", "power-line tone-" + v.top.power.tone);
    line.appendChild(el("span", "dot"));
    line.appendChild(el("span", "power-text", v.top.power.text));
    c.appendChild(line);
    var chips = el("div", "chips");
    chips.appendChild(badge(v.top.engine));
    chips.appendChild(badge(v.top.switchPosition));
    c.appendChild(chips);
    if (v.top.engineState && v.top.engineState !== v.top.engine.text) {
      c.appendChild(el("p", "muted", "Engine: " + v.top.engineState));
    }
  }

  function renderNote(parent) {
    if (pending) parent.appendChild(el("p", "note tone-quiet", "Sending to the generator..."));
    else if (note) parent.appendChild(el("p", "note tone-" + note.tone, note.text));
  }

  function renderExercise(v) {
    var e = v.exercise;
    var c = card("Exercise");
    row(c, "Schedule", e.schedule);
    if (e.next) row(c, "Next", e.next);
    if (e.last) row(c, "Last ran", e.last);
    var actions = el("div", "actions");
    if (e.running) {
      actions.appendChild(
        button(sending("stop") ? "Stopping..." : "Stop exercise", "btn", function () {
          send({ action: "stop" });
        }, e.stop.enabled && !pending)
      );
    } else {
      actions.appendChild(
        button(sending("start") ? "Starting..." : "Start exercise", "btn primary", function () {
          startMode = (e.sheet && e.sheet.mode) || "Unloaded";
          openSheet("start");
        }, e.start.enabled && !pending)
      );
    }
    actions.appendChild(
      button("Change schedule", "btn", function () {
        draft = {};
        Object.keys(e.sheet).forEach(function (k) {
          draft[k] = String(e.sheet[k]);
        });
        openSheet("schedule");
      }, !pending)
    );
    c.appendChild(actions);
    var reason = e.running ? e.stop.reason : e.start.reason;
    if (reason) c.appendChild(el("p", "muted", reason));
    renderNote(c);
  }

  function renderReadings(v) {
    if (!v.readings.length) return;
    var c = card("Now");
    var grid = el("div", "grid");
    v.readings.forEach(function (r) {
      var cell = el("div", "cell");
      cell.appendChild(el("span", "cell-value" + (r.tone ? " tone-" + r.tone : ""), r.value));
      cell.appendChild(el("span", "cell-label", r.label));
      grid.appendChild(cell);
    });
    c.appendChild(grid);
  }

  function renderLoads(v) {
    if (!v.loads) return;
    var c = card("Loads");
    v.loads.forEach(function (l) {
      var r = el("label", "row switch-row");
      r.appendChild(el("span", "row-label", l.name));
      var input = el("input", "switch");
      input.type = "checkbox";
      input.setAttribute("role", "switch");
      input.checked = l.on;
      input.disabled = !!pending;
      input.setAttribute("aria-label", l.name);
      input.addEventListener("change", function () {
        send({ action: "load", load: l.name, state: input.checked ? "On" : "Off" });
      });
      r.appendChild(input);
      c.appendChild(r);
    });
  }

  function renderList(c, items, empty) {
    if (!items.length) {
      c.appendChild(el("p", "muted", empty));
      return;
    }
    items.forEach(function (item) {
      var r = el("div", "row");
      var name = el("span", "row-label");
      name.appendChild(el("span", "dot tone-" + item.tone));
      name.appendChild(document.createTextNode(item.name));
      r.appendChild(name);
      r.appendChild(el("span", "row-value", item.time));
      c.appendChild(r);
    });
  }

  function renderAlerts(v) {
    var c = card("Alerts");
    renderList(c, v.alerts, "No active alerts.");
    var details = el("details", "history");
    details.open = historyOpen;
    details.addEventListener("toggle", function () {
      historyOpen = details.open;
    });
    details.appendChild(el("summary", null, "History"));
    renderList(details, v.history, "Nothing logged yet.");
    c.appendChild(details);
  }

  function renderService(v) {
    var c = card("Service");
    v.service.rows.forEach(function (r) {
      row(c, r.label, r.value, r.tone);
    });
    if (v.service.due) c.appendChild(el("p", "note tone-warn", "Maintenance is due. Contact your dealer."));
  }

  // Takes the open sheet off the screen.
  function dismiss() {
    if (sheetNode && sheetNode.parentNode) sheetNode.parentNode.removeChild(sheetNode);
    sheet = sheetNode = draft = startGuard = null;
  }

  function cancel() {
    dismiss();
    render();
  }

  // Puts a sheet on the screen. A sheet is built once when it opens, not on each render, so the 30 s
  // tick and the driver's pushes leave its fields and an open picker alone.
  function openSheet(kind) {
    if (sheetNode && sheetNode.parentNode) sheetNode.parentNode.removeChild(sheetNode);
    sheet = kind;
    if (kind === "start") renderStartSheet();
    else renderScheduleSheet();
  }

  function scrim(content) {
    var s = el("div", "scrim");
    s.addEventListener("click", function (event) {
      if (event.target === s) cancel();
    });
    var dialog = el("div", "sheet");
    dialog.setAttribute("role", "dialog");
    dialog.setAttribute("aria-modal", "true");
    dialog.appendChild(content);
    s.appendChild(dialog);
    document.body.appendChild(s);
    sheetNode = s;
  }

  function renderStartSheet() {
    var body = el("div");
    var copy = KGView.confirmStart(startMode);
    body.appendChild(el("h2", "sheet-title", copy.title));
    var modes = el("div", "choices");
    KGView.MODES.forEach(function (mode) {
      var label = el("label", "choice");
      var input = el("input");
      input.type = "radio";
      input.name = "mode";
      input.checked = mode === startMode;
      input.addEventListener("change", function () {
        startMode = mode;
        openSheet("start");
      });
      label.appendChild(input);
      label.appendChild(el("span", null, mode));
      modes.appendChild(label);
    });
    body.appendChild(modes);
    body.appendChild(el("p", "sheet-text", copy.text));
    var actions = el("div", "actions");
    actions.appendChild(button(copy.cancel, "btn", cancel));
    var ok = button(copy.ok, "btn primary", function () {
      dismiss();
      send({ action: "start", mode: startMode });
    });
    actions.appendChild(ok);
    body.appendChild(actions);
    var reason = el("p", "muted");
    body.appendChild(reason);
    scrim(body);
    startGuard = { ok: ok, reason: reason };
    guardStart(KGView.view(current, now()));
  }

  // The open Start sheet follows the generator: a refusal or a running engine that arrives while it
  // is open greys Start with the reason.
  function guardStart(v) {
    if (!startGuard) return;
    var e = v.exercise;
    var why = e.running ? "The generator is already running" : e.start.reason;
    startGuard.ok.disabled = e.running || !e.start.enabled;
    startGuard.reason.textContent = startGuard.ok.disabled ? why : "";
  }

  // A schedule field, kept in draft as the homeowner changes it.
  function field(label, key, input) {
    var wrap = el("label", "field");
    wrap.appendChild(el("span", "field-label", label));
    input.addEventListener("change", function () {
      draft[key] = input.value;
    });
    wrap.appendChild(input);
    return wrap;
  }

  function select(label, key, options) {
    var s = el("select");
    options.forEach(function (o) {
      var opt = el("option", null, typeof o === "number" ? o + " minutes" : o);
      opt.value = String(o);
      if (String(o) === draft[key]) opt.selected = true;
      s.appendChild(opt);
    });
    s.value = draft[key];
    return field(label, key, s);
  }

  function renderScheduleSheet() {
    var body = el("div");
    body.appendChild(el("h2", "sheet-title", "Exercise schedule"));
    var time = el("input");
    time.type = "time";
    time.value = draft.time || "10:00";
    [
      select("How often", "frequency", KGView.FREQUENCIES),
      select("Day", "day", KGView.WEEKDAYS),
      field("Time", "time", time),
      select("Mode", "mode", KGView.MODES),
      select("Length", "minutes", KGView.MINUTES),
    ].forEach(function (w) {
      body.appendChild(w);
    });
    var actions = el("div", "actions");
    actions.appendChild(button("Cancel", "btn", cancel));
    actions.appendChild(
      button("Save", "btn primary", function () {
        var values = draft;
        dismiss();
        send({
          action: "schedule",
          frequency: values.frequency,
          day: values.day,
          time: values.time,
          mode: values.mode,
          minutes: values.minutes,
        });
      })
    );
    body.appendChild(actions);
    scrim(body);
  }

  function render() {
    page.textContent = "";
    if (!current) {
      page.appendChild(el("p", "loading", "Loading..."));
      return;
    }
    var v = KGView.view(current, now());
    if (sheet && !v.connected) dismiss();
    if (v.notConnected) renderNotConnected(v);
    if (!v.top) return;
    renderTop(v);
    if (v.connected) {
      renderExercise(v);
      renderReadings(v);
      renderLoads(v);
      renderAlerts(v);
    }
    renderService(v);
    guardStart(v);
  }

  function onState(state) {
    current = state;
    var last = state.lastCommand;
    if (pending && last && last.request === pending.id) {
      clearTimeout(pending.timer);
      pending = null;
      note = KGView.answer(last);
    }
    render();
  }

  setInterval(render, TICK_MS);

  var hasC4 = typeof window.C4 === "object" && window.C4 !== null && typeof window.C4.sendCommand === "function";
  var c4 = hasC4
    ? window.C4
    : KGDemo.c4(function (value) {
        window.onDataToUi(value);
      });
  var bridge = KGBridge.create({
    c4: c4,
    onState: onState,
    onError: function (message) {
      console.warn("Kohler Generator:", message);
    },
  });

  window.onDataToUi = bridge.receive;
  window.onSubscribeToDataToUiError = function (message) {
    console.warn("Kohler Generator: subscribe failed:", message);
  };
  window.onSendCommandError = function (message) {
    console.warn("Kohler Generator: command failed:", message);
  };
  document.body.setAttribute("data-mode", hasC4 ? "app" : "demo");
  render();
  bridge.start();
})();
