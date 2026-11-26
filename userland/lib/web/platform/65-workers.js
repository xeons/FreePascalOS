// Dedicated workers (HTML Standard 10.2): new Worker(url) fetches the
// script (CORS rules of fetch, blob: URLs too) and runs it in a global
// scope of its own - a bare realm with its own built-ins and no DOM
// (Web.Script.NativeWorkers), on the window's thread: its scripts run in
// tasks between the window's. The scope has self, location, navigator,
// name, postMessage, close, the event listener methods and onmessage,
// and shares the window's timers, fetch, crypto, performance, console,
// encoders, URLs, blobs, streams and messaging classes. Messages are
// structured clones delivered in tasks; an uncaught error in the
// worker's script fires error at the Worker. importScripts fetches
// through fetch() (CORS) before the script runs again (see below).
(function (natives, global, internal) {
  "use strict";
  const workerData = new WeakMap();

  // Run in the worker's realm: its WorkerGlobalScope interfaces and
  // event target, the hook the window delivers messages through.
  const bootstrap = `(function () {
    "use strict";
    const host = globalThis.__workerHost;
    delete globalThis.__workerHost;
    const listeners = new Map();
    function WorkerGlobalScope() { throw new TypeError("Illegal constructor"); }
    function DedicatedWorkerGlobalScope() { throw new TypeError("Illegal constructor"); }
    Object.setPrototypeOf(DedicatedWorkerGlobalScope.prototype, WorkerGlobalScope.prototype);
    const proto = WorkerGlobalScope.prototype;
    Object.defineProperty(proto, "addEventListener", { configurable: true, writable: true, value: function (type, callback) {
      if (callback === null || callback === undefined) return;
      const key = String(type);
      let list = listeners.get(key);
      if (list === undefined) { list = []; listeners.set(key, list); }
      if (list.indexOf(callback) < 0) list.push(callback);
    } });
    Object.defineProperty(proto, "removeEventListener", { configurable: true, writable: true, value: function (type, callback) {
      const list = listeners.get(String(type));
      if (list === undefined) return;
      const index = list.indexOf(callback);
      if (index >= 0) list.splice(index, 1);
    } });
    function deliver(event) {
      const handler = globalThis["on" + event.type];
      if (typeof handler === "function") handler.call(globalThis, event);
      const list = listeners.get(event.type);
      if (list === undefined) return;
      for (const callback of list.slice()) {
        if (typeof callback === "function") callback.call(globalThis, event);
        else if (callback && typeof callback.handleEvent === "function") callback.handleEvent(event);
      }
    }
    Object.defineProperty(proto, "dispatchEvent", { configurable: true, writable: true, value: function (event) {
      deliver(event);
      return !event.defaultPrevented;
    } });
    Object.defineProperty(DedicatedWorkerGlobalScope.prototype, Symbol.toStringTag,
      { configurable: true, value: "DedicatedWorkerGlobalScope" });
    Object.setPrototypeOf(globalThis, DedicatedWorkerGlobalScope.prototype);
    Object.defineProperty(globalThis, "WorkerGlobalScope", { configurable: true, writable: true, value: WorkerGlobalScope });
    Object.defineProperty(globalThis, "DedicatedWorkerGlobalScope", { configurable: true, writable: true,
      value: DedicatedWorkerGlobalScope });
    globalThis.onmessage = null;
    globalThis.onmessageerror = null;
    globalThis.onerror = null;
    host.deliver = deliver;
  })();`;

  // What a worker's scope has of the window: functions called on the
  // window, and interfaces (classes) as they are.
  const sharedFunctions = ["setTimeout", "clearTimeout", "setInterval", "clearInterval", "queueMicrotask", "fetch",
    "atob", "btoa", "structuredClone", "reportError"];
  const sharedObjects = ["crypto", "performance", "console", "navigator", "TextEncoder", "TextDecoder", "URL",
    "URLSearchParams", "Blob", "File", "FileReader", "FormData", "Headers", "Request", "Response", "AbortController",
    "AbortSignal", "ReadableStream", "WritableStream", "TransformStream", "TextEncoderStream", "TextDecoderStream",
    "MessageChannel", "MessagePort", "MessageEvent", "BroadcastChannel", "Event", "EventTarget", "CustomEvent",
    "ErrorEvent", "ProgressEvent", "DOMException", "XMLHttpRequest", "EventSource", "WebAssembly", "isSecureContext",
    "origin",
    // IndexedDB and the Cache API (the window's origin is the worker's).
    "indexedDB", "IDBFactory", "IDBDatabase", "IDBTransaction", "IDBRequest", "IDBOpenDBRequest", "IDBObjectStore",
    "IDBIndex", "IDBCursor", "IDBCursorWithValue", "IDBKeyRange", "IDBVersionChangeEvent", "DOMStringList", "caches",
    "CacheStorage", "Cache", "StorageManager"];

  function workerState(worker) {
    const state = workerData.get(worker);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  function fireError(worker, message, url) {
    const event = new Event("error", { cancelable: true });
    Object.defineProperty(event, "message", { value: message });
    Object.defineProperty(event, "filename", { value: url });
    worker.dispatchEvent(event);
  }

  function locationOf(url) {
    const parsed = new URL(url);
    const location = {};
    for (const key of ["href", "origin", "protocol", "host", "hostname", "port", "pathname", "search", "hash"])
      location[key] = parsed[key];
    location.toString = function () { return parsed.href; };
    return location;
  }

  function flushToWorker(state) {
    if (state.scheduled || !state.ready) return;
    state.scheduled = true;
    internal.queueTask(function () {
      state.scheduled = false;
      while (state.pending.length > 0 && !state.terminated) {
        const message = state.pending.shift();
        state.host.deliver(new MessageEvent("message", { data: message.data, ports: message.ports }));
      }
    });
  }

  function fetchSource(url) {
    return global.fetch(url).then(function (response) {
      if (!response.ok) throw new Error("HTTP " + response.status + " for " + url);
      return response.text();
    });
  }

  // A scope of the window's thread cannot wait for a fetch: importScripts
  // runs a script it has already fetched; one it has not stops the
  // worker's script, the scripts are fetched, and the script runs again
  // from the start in a new scope (importScripts comes first in worker
  // scripts). Later calls with scripts not fetched then fail.
  function importScriptsOf(state, scope) {
    return function importScripts() {
      const missing = [];
      const urls = [];
      for (const item of arguments) {
        let url;
        try {
          url = new URL(String(item), state.url).href;
        } catch (error) {
          throw internal.domException("Failed to execute 'importScripts': The URL '" + item + "' is invalid.",
            "SyntaxError");
        }
        urls.push(url);
        if (!state.imports.has(url)) missing.push(url);
      }
      if (missing.length > 0) {
        if (state.starting) {
          for (const url of missing) state.missing.push(url);
          throw new Error("importScripts: fetching " + missing.join(", "));
        }
        throw internal.domException("Failed to execute 'importScripts': " + missing[0] + " failed to load.",
          "NetworkError");
      }
      for (const url of urls) {
        const error = natives.workerEvaluate(scope, state.imports.get(url), url);
        if (error !== undefined) throw new Error(error);
      }
    };
  }

  function makeScope(worker, state) {
    const scope = natives.workerRealm();
    state.scope = scope;
    state.host = { deliver: null };
    for (const name of sharedFunctions)
      if (typeof global[name] === "function") scope[name] = global[name].bind(global);
    for (const name of sharedObjects)
      if (name in global) scope[name] = global[name];
    scope.self = scope;
    scope.name = state.name;
    scope.location = locationOf(state.url);
    scope.postMessage = function postMessage(message, transfer) {
      const ports = internal.transferredPorts(transfer).map(internal.movePort);
      const data = structuredClone(message);
      internal.queueTask(function () {
        if (!state.terminated) worker.dispatchEvent(new MessageEvent("message", { data: data, ports: ports }));
      });
    };
    scope.close = function close() {
      state.terminated = true;
    };
    scope.importScripts = importScriptsOf(state, scope);
    scope.__workerHost = state.host;
    natives.workerEvaluate(scope, bootstrap, "worker-scope");
    return scope;
  }

  function start(worker, state, source) {
    if (state.terminated) return;
    if (state.scope !== null) natives.workerClose(state.scope);
    const scope = makeScope(worker, state);
    state.missing = [];
    state.starting = true;
    const error = natives.workerEvaluate(scope, source, state.url);
    state.starting = false;
    if (state.missing.length > 0 && state.restarts < 4) {
      state.restarts++;
      Promise.all(state.missing.map(function (url) {
        return fetchSource(url).then(function (text) { state.imports.set(url, text); });
      })).then(function () {
        start(worker, state, source);
      }).catch(function (failure) {
        if (!state.terminated) fireError(worker, String(failure && failure.message || failure), state.url);
      });
      return;
    }
    if (error !== undefined) fireError(worker, error, state.url);
    state.ready = true;
    flushToWorker(state);
  }

  class Worker extends EventTarget {
    constructor(scriptURL, options) {
      if (arguments.length < 1)
        throw new TypeError("Failed to construct 'Worker': 1 argument required, but only 0 present.");
      super();
      let url;
      try {
        url = new URL(String(scriptURL), global.document.baseURI).href;
      } catch (error) {
        throw internal.domException("Failed to construct 'Worker': The URL '" + scriptURL + "' is invalid.",
          "SyntaxError");
      }
      const name = options !== null && typeof options === "object" && options.name !== undefined ?
        String(options.name) : "";
      const state = { url: url, name: name, scope: null, host: null, ready: false, terminated: false, pending: [],
        scheduled: false, imports: new Map(), missing: [], starting: false, restarts: 0 };
      workerData.set(this, state);
      const worker = this;
      fetchSource(url).then(function (source) {
        start(worker, state, source);
      }).catch(function (error) {
        if (!state.terminated) fireError(worker, String(error && error.message || error), url);
      });
    }
    postMessage(message, transfer) {
      const state = workerState(this);
      const ports = internal.transferredPorts(transfer).map(internal.movePort);
      const data = structuredClone(message);
      if (state.terminated) return;
      state.pending.push({ data: data, ports: ports });
      flushToWorker(state);
    }
    terminate() {
      const state = workerState(this);
      if (state.terminated) return;
      state.terminated = true;
      state.pending = [];
      if (state.scope !== null) natives.workerClose(state.scope);
    }
  }
  internal.defineHandler(Worker.prototype, "message");
  internal.defineHandler(Worker.prototype, "messageerror");
  internal.defineHandler(Worker.prototype, "error");
  internal.finishInterface(Worker, "Worker");
})
