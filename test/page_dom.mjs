// A small stand-in DOM and loader for the generator page's scripts, enough for app.js: elements with
// classes, text, attributes and click/change events, and timers the test runs by hand.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import vm from "node:vm";

const DIST = path.join(path.dirname(fileURLToPath(import.meta.url)), "../drivers/kohler_generator/www/dist");

class Element {
  constructor(tag) {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.parentNode = null;
    this.attributes = {};
    this.listeners = {};
    this.className = "";
    this.ownText = "";
    this.disabled = false;
    this.checked = false;
    this.value = "";
    this.selected = false;
    this.open = false;
    const el = this;
    this.classList = {
      add(c) {
        el.className = (el.className + " " + c).trim();
      },
      contains(c) {
        return el.className.split(/\s+/).includes(c);
      },
    };
  }

  set textContent(text) {
    this.children.forEach((c) => (c.parentNode = null));
    this.children = [];
    this.ownText = String(text);
  }

  get textContent() {
    return this.ownText + this.children.map((c) => c.textContent).join("");
  }

  appendChild(child) {
    child.parentNode = this;
    this.children.push(child);
    return child;
  }

  removeChild(child) {
    this.children = this.children.filter((c) => c !== child);
    child.parentNode = null;
  }

  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }

  getAttribute(name) {
    return this.attributes[name];
  }

  addEventListener(type, fn) {
    (this.listeners[type] = this.listeners[type] || []).push(fn);
  }

  dispatch(type) {
    (this.listeners[type] || []).forEach((fn) => fn({ target: this }));
  }

  click() {
    if (this.disabled) return;
    if (this.type === "checkbox") this.checked = !this.checked;
    if (this.type === "radio") this.checked = true;
    this.dispatch(this.type === "checkbox" || this.type === "radio" ? "change" : "click");
  }

  all(test) {
    const out = [];
    const walk = (e) => {
      if (test(e)) out.push(e);
      e.children.forEach(walk);
    };
    this.children.forEach(walk);
    return out;
  }

  byClass(c) {
    return this.all((e) => e.classList.contains(c));
  }

  buttons() {
    return this.all((e) => e.tagName === "BUTTON");
  }

  button(text) {
    return this.buttons().find((b) => b.textContent === text);
  }
}

class Text {
  constructor(text) {
    this.text = String(text);
    this.children = [];
    this.classList = { contains: () => false };
    this.tagName = "#text";
  }

  get textContent() {
    return this.text;
  }
}

// Loads the page into a fresh context. c4: the C4 object the app would provide, or null for the demo.
export function loadPage({ c4 = null, now = Date.UTC(2026, 8, 26, 14, 0, 0) } = {}) {
  const body = new Element("body");
  const page = body.appendChild(new Element("main"));
  page.className = "page";
  const document = {
    body,
    createElement: (tag) => new Element(tag),
    createTextNode: (text) => new Text(text),
    querySelector(selector) {
      const c = selector.replace(/^\./, "");
      return body.byClass(c)[0] || null;
    },
  };
  const timers = [];
  let clock = now;
  const later = (fn, ms, repeat) => {
    const t = { fn, at: clock + ms, ms, repeat, live: true };
    timers.push(t);
    return t;
  };
  class FakeDate extends Date {
    constructor(...args) {
      super(...(args.length ? args : [clock]));
    }
    static now() {
      return clock;
    }
  }
  const context = {
    document,
    console: { warn() {}, log() {} },
    JSON,
    Math,
    Date: FakeDate,
    setTimeout: (fn, ms) => later(fn, ms, false),
    clearTimeout: (t) => t && (t.live = false),
    setInterval: (fn, ms) => later(fn, ms, true),
    clearInterval: (t) => t && (t.live = false),
  };
  context.window = context;
  context.self = context;
  if (c4) context.C4 = c4;
  vm.createContext(context);
  for (const file of ["bridge.js", "view.js", "demo.js", "app.js"]) {
    vm.runInContext(readFileSync(path.join(DIST, file), "utf8"), context, { filename: file });
  }
  // Runs every timer due within ms, in time order.
  function advance(ms) {
    const end = clock + ms;
    for (;;) {
      const due = timers.filter((t) => t.live && t.at <= end).sort((a, b) => a.at - b.at)[0];
      if (!due) break;
      clock = due.at;
      if (due.repeat) due.at += due.ms;
      else due.live = false;
      due.fn();
    }
    clock = end;
  }
  return { window: context, document, body, page, advance };
}

// A C4 that records what the page sends.
export function recordingC4() {
  const sent = [];
  return {
    sent,
    subscribeToDataToUi() {},
    sendCommand(name, json) {
      sent.push({ name, params: JSON.parse(json) });
    },
  };
}

// The envelope the app hands onDataToUi for a driver push.
export function envelope(data) {
  return {
    devicecommand: {
      command: "KG_PAGE_STATE",
      params: { param: [{ name: "json", value: { type: "STRING", static: JSON.stringify(data) } }] },
    },
  };
}
