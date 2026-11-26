// Shared workers (HTML Standard 10.2.6). new SharedWorker(url, name)
// connects to the one worker of the URL, name and origin in this process
// (Web.Workers.SharedWorkers), starting it in a worker agent of its own
// when there is none: the page keeps worker.port, the worker's scope
// gets a connect event whose ports[0] (and source) is the other end - a
// MessagePort pair over a message link, since the worker's scope is in
// another heap. A script that cannot be fetched or parsed fires error at
// every SharedWorker object waiting for it. The worker lives while a
// document that made a SharedWorker for it does, or until it calls
// close().
//
// In a worker agent's window, natives.onSharedWorkerStart and
// natives.onSharedWorkerConnect run the worker's side.
(function (natives, global, internal) {
  "use strict";
  const workerData = new WeakMap();
  const connections = new Map();

  function workerState(worker) {
    const state = workerData.get(worker);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  natives.onSharedWorkerError = function (connection, message) {
    const worker = connections.get(connection);
    if (worker === undefined) return;
    connections.delete(connection);
    const event = new Event("error", { cancelable: true });
    Object.defineProperty(event, "message", { value: message });
    internal.fire(worker, event);
  };

  class SharedWorker extends EventTarget {
    constructor(scriptURL, options) {
      if (arguments.length < 1)
        throw new TypeError("Failed to construct 'SharedWorker': 1 argument required, but only 0 present.");
      super();
      let url;
      try {
        url = new URL(String(scriptURL), global.document.baseURI);
      } catch (error) {
        throw internal.domException("Failed to construct 'SharedWorker': The URL '" + scriptURL + "' is invalid.",
          "SyntaxError");
      }
      let name = "";
      if (typeof options === "string") name = options;
      else if (options !== null && typeof options === "object" && options.name !== undefined) name = String(options.name);
      else if (options !== undefined && options !== null && typeof options !== "object") name = String(options);
      // A blob: URL is this window's: its script goes along as text.
      let source = null;
      if (url.protocol === "blob:") {
        const object = internal.blobUrls.get(url.href.split("#")[0]);
        if (object === undefined)
          throw internal.domException("Failed to construct 'SharedWorker': The URL '" + url.href +
            "' does not name a blob.", "SyntaxError");
        source = internal.decodeText(internal.blobBytes(object));
      } else if (url.protocol !== "data:" && url.origin !== global.origin) {
        throw internal.domException("Failed to construct 'SharedWorker': Script at '" + url.href +
          "' cannot be accessed from origin '" + global.origin + "'.", "SecurityError");
      }
      const pair = natives.linkOpen();
      const port = internal.portFromLink(pair[0]);
      workerData.set(this, { port: port });
      const connection = natives.sharedWorkerConnect(url.href, name, pair[1], source);
      if (connection > 0) connections.set(connection, this);
      else {
        const worker = this;
        internal.queueTask(function () {
          internal.fire(worker, new Event("error", { cancelable: true }));
        });
      }
    }
    get port() { return workerState(this).port; }
  }
  internal.defineHandler(SharedWorker.prototype, "error");
  internal.finishInterface(SharedWorker, "SharedWorker");

  // ---- the worker's side, in its agent's window ----

  let runner = null;
  let ready = false;
  const waitingConnections = [];

  function connect(linkId) {
    const port = internal.portFromLink(linkId);
    runner.deliver(new MessageEvent("connect", { data: "", ports: [port], source: port }));
  }

  natives.onSharedWorkerStart = function (url, name, source) {
    runner = internal.createWorkerRunner({
      url: url,
      name: name,
      kind: "SharedWorkerGlobalScope",
      handlers: ["connect"],
      setup: function (scope) {
        scope.name = name;
        scope.close = function close() {
          natives.sharedWorkerClose();
        };
      }
    });
    function begin(text) {
      runner.run(text, function (error) {
        if (error !== undefined) {
          console.error(error);
          if (/^SyntaxError/.test(error)) {
            natives.sharedWorkerFailed(error);
            return;
          }
        }
        ready = true;
        for (const linkId of waitingConnections.splice(0)) connect(linkId);
      });
    }
    if (source !== null && source !== undefined) {
      begin(source);
      return;
    }
    global.fetch(url, { mode: "same-origin", credentials: "same-origin" }).then(function (response) {
      if (!response.ok) throw new Error("HTTP " + response.status + " for " + url);
      return response.text();
    }).then(begin, function (failure) {
      natives.sharedWorkerFailed(String(failure && failure.message || failure));
    });
  };

  natives.onSharedWorkerConnect = function (linkId) {
    if (runner !== null && ready) connect(linkId);
    else waitingConnections.push(linkId);
  };
})
