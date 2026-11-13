// Tests for browser/extension/background.js, run with `node --test browser/test`.
// The service worker is loaded into a sandbox with a fake `chrome` API and a
// fake `fetch`, then driven through the listeners it registers, the same way
// a browser drives it.
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const SOURCE = fs.readFileSync(path.join(__dirname, "..", "extension", "background.js"), "utf8");
const SELF = "self-extension-id";

// load starts a fresh copy of the worker. `ping` is the JSON body port 8760
// answers /ping with (null: nothing listens); `addStatus` is the app's reply
// to POST /add; `rejectReferer` makes downloads.download refuse a Referer
// header the way Chromium does.
function load({ store = {}, ping = { app: "spate" }, addStatus = 200, rejectReferer = false } = {}) {
  const calls = { fetch: [], cancel: [], erase: [], download: [] };
  const listeners = {};
  const event = (name) => ({ addListener: (f) => { listeners[name] = f; } });
  const local = { token: "tok", mode: "always", ...store };
  const noopApi = new Proxy({}, { get: () => async () => {} });

  const chrome = {
    runtime: {
      id: SELF,
      lastError: null,
      onInstalled: event("installed"),
      onStartup: event("startup"),
      onMessage: event("message"),
      sendNativeMessage: async () => { throw new Error("no native host"); },
      getURL: (p) => "ext://" + p,
    },
    storage: {
      local: {
        get: async (q) => {
          if (q && typeof q === "object" && !Array.isArray(q)) {
            const out = {};
            for (const k of Object.keys(q)) out[k] = k in local ? local[k] : q[k];
            return out;
          }
          if (typeof q === "string") return { [q]: local[q] };
          return { ...local };
        },
        set: async (o) => { Object.assign(local, o); },
        remove: async (k) => { delete local[k]; },
      },
      session: noopApi,
    },
    alarms: { create: () => {}, onAlarm: event("alarm") },
    cookies: { getAll: async () => [], getAllCookieStores: async () => [] },
    contextMenus: { create: () => {}, onClicked: event("menu") },
    action: noopApi,
    windows: noopApi,
    downloads: {
      onCreated: event("created"),
      search: async () => [{ state: "in_progress" }],
      cancel: async (id) => { calls.cancel.push(id); },
      erase: async (q) => { calls.erase.push(q); },
      download: async (opts) => {
        calls.download.push(opts);
        if (rejectReferer && opts.headers) throw new Error("Unsafe request header name");
        return 99;
      },
    },
  };

  const fetch = async (url, init = {}) => {
    calls.fetch.push({ url, init });
    if (url.includes("/ping")) {
      if (!ping || !url.includes(":8760/")) throw new Error("connection refused");
      return { ok: true, status: 200, json: async () => ping };
    }
    if (url.endsWith("/add")) {
      return { ok: addStatus === 200, status: addStatus, json: async () => ({ id: "job-1", error: "not fetchable" }) };
    }
    throw new Error("unexpected fetch " + url);
  };

  vm.runInNewContext(SOURCE, {
    chrome,
    fetch,
    console: { log: () => {} },
    navigator: { userAgent: "test", language: "en-US" },
    URL,
    AbortController,
    clearTimeout,
    setTimeout: (f) => setTimeout(f, 0), // skip the real waits
  });
  return { listeners, calls, local };
}

const adds = (calls) => calls.fetch.filter((c) => c.url.endsWith("/add"));

test("a download is handed to the app and the browser copy removed", async () => {
  const { listeners, calls, local } = load();
  await listeners.created({ id: 1, url: "https://example.com/a.zip", referrer: "https://example.com/" });
  assert.strictEqual(adds(calls).length, 1);
  assert.deepStrictEqual(calls.cancel, [1]);
  assert.strictEqual(calls.download.length, 0);
  assert.strictEqual(local.lastEvent.result, "handed off to app");
});

test("cookies and the token are not sent to a port that is not Spate", async () => {
  const { listeners, calls } = load({ ping: { app: "something-else" } });
  await listeners.created({ id: 1, url: "https://example.com/a.zip" });
  assert.strictEqual(adds(calls).length, 0);
  assert.deepStrictEqual(calls.cancel, [], "the browser download must be left running");
});

test("a download the extension started itself is left to the browser", async () => {
  const { listeners, calls, local } = load();
  await listeners.created({ id: 2, url: "https://example.com/a.zip", byExtensionId: SELF });
  assert.strictEqual(adds(calls).length, 0);
  assert.deepStrictEqual(calls.cancel, []);
  assert.match(local.lastEvent.result, /^skipped: restarted by Spate/);
});

test("a refused download is given back to the browser, without Referer if the browser rejects it", async () => {
  const { listeners, calls, local } = load({ addStatus: 422, rejectReferer: true });
  const url = "https://example.com/a.zip";
  await listeners.created({ id: 3, url, referrer: "https://example.com/page" });
  assert.deepStrictEqual(calls.cancel, [3]);
  assert.strictEqual(calls.download.length, 2, "first with Referer, then without");
  assert.ok(calls.download[0].headers);
  assert.strictEqual(calls.download[1].headers, undefined);
  assert.strictEqual(calls.download[1].url, url);
  assert.strictEqual(local.lastEvent.result, "app refused; restarted in browser");

  // The restarted download shows up as a new one. Even if the browser does
  // not mark it as started by the extension, it must not be captured again.
  await listeners.created({ id: 4, url });
  assert.deepStrictEqual(calls.cancel, [3], "no second cancel: no restart loop");
  assert.strictEqual(adds(calls).length, 1);
});

test("a declined pairing prompt is not raised again by the heartbeat", async () => {
  const { listeners, calls, local } = load({ store: { token: "", pairDeclined: true } });
  await listeners.alarm({ name: "spate-heartbeat" });
  await new Promise((r) => setImmediate(r));
  assert.strictEqual(calls.fetch.filter((c) => c.url.endsWith("/pair")).length, 0);
  assert.strictEqual(local.pairDeclined, true);
});

test("pairing is requested with POST so the browser always sends the extension's Origin", async () => {
  const { listeners, calls } = load({ store: { token: "" } });
  await listeners.alarm({ name: "spate-heartbeat" });
  await new Promise((r) => setTimeout(r, 20));
  const pairs = calls.fetch.filter((c) => c.url.endsWith("/pair"));
  assert.strictEqual(pairs.length, 1);
  assert.strictEqual(pairs[0].init.method, "POST");
});
